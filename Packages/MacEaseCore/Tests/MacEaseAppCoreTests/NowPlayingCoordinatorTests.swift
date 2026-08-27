import Foundation
import NeteaseKit
import Testing

@testable import MacEaseAppCore

/// SYS-002: a system command is a request that is checked against the current
/// projection before it becomes a playback intent. These tests pin what is
/// refused, what the system is told, and that a refusal never reaches the
/// intent handler.

@MainActor
private final class FakeSystemMedia: SystemMediaControlling {
  var onCommand: (@MainActor (SystemMediaCommand) -> SystemMediaCommandResult)?
  private(set) var published: [PlaybackSnapshot] = []
  private(set) var clearCount = 0

  func publish(_ snapshot: PlaybackSnapshot) { published.append(snapshot) }
  func clear() { clearCount += 1 }

  func send(_ command: SystemMediaCommand) -> SystemMediaCommandResult {
    onCommand?(command) ?? .noActionableItem
  }
}

@MainActor
private final class Rig {
  let surface = FakeSystemMedia()
  var snapshot = PlaybackSnapshot.empty
  private(set) var dispatched: [SystemMediaCommand] = []
  var accepts = true
  var coordinator: NowPlayingCoordinator!

  init() {
    coordinator = NowPlayingCoordinator(
      surface: surface,
      snapshotProvider: { [unowned self] in self.snapshot },
      performIntent: { [unowned self] command in
        self.dispatched.append(command)
        return self.accepts
      }
    )
  }

  func send(_ command: SystemMediaCommand) -> SystemMediaCommandResult {
    surface.send(command)
  }
}

private func makeSnapshot(
  state: PlaybackSnapshot.State = .playing,
  trackID: Int64? = 101,
  durationSeconds: Double? = 200,
  elapsedSeconds: Double = 0,
  positionEpoch: Int = 0,
  canStepNext: Bool = true,
  canStepPrevious: Bool = true,
  liked: LikedState = .liked
) -> PlaybackSnapshot {
  PlaybackSnapshot(
    state: state,
    trackID: trackID,
    title: trackID.map { "track-\($0)" },
    artist: "artist",
    durationSeconds: durationSeconds,
    elapsedSeconds: elapsedSeconds,
    positionEpoch: positionEpoch,
    canStepNext: canStepNext,
    canStepPrevious: canStepPrevious,
    liked: liked
  )
}

// MARK: - Nothing loaded

@Test @MainActor func everyCommandIsRefusedWithNoActionableItem() {
  let rig = Rig()

  let commands: [SystemMediaCommand] = [
    .play, .pause, .toggle, .next, .previous, .seek(10), .setLiked(true),
  ]
  for command in commands {
    #expect(rig.send(command) == .noActionableItem)
  }
  #expect(rig.dispatched.isEmpty)
}

// MARK: - Transport commands

@Test @MainActor func pauseIsRefusedWhenAlreadyPaused() {
  let rig = Rig()
  rig.snapshot = makeSnapshot(state: .paused)

  #expect(rig.send(.pause) == .notPermitted)
  #expect(rig.dispatched.isEmpty)
  #expect(rig.send(.play) == .handled)
  #expect(rig.dispatched == [.play])
}

@Test @MainActor func playIsRefusedWhenAlreadyPlaying() {
  let rig = Rig()
  rig.snapshot = makeSnapshot(state: .playing)

  #expect(rig.send(.play) == .notPermitted)
  #expect(rig.dispatched.isEmpty)
  #expect(rig.send(.pause) == .handled)
  #expect(rig.dispatched == [.pause])
}

@Test @MainActor func toggleResolvesToTheConcreteCommand() {
  let rig = Rig()

  rig.snapshot = makeSnapshot(state: .playing)
  #expect(rig.send(.toggle) == .handled)
  rig.snapshot = makeSnapshot(state: .paused)
  #expect(rig.send(.toggle) == .handled)

  // The handler is never asked to work out what toggle meant.
  #expect(rig.dispatched == [.pause, .play])
}

@Test @MainActor func toggleIsRefusedWhenThereIsNoAudio() {
  let rig = Rig()
  // A track is chosen but the resolve failed, so there is nothing to toggle.
  rig.snapshot = makeSnapshot(state: .stopped)

  #expect(rig.send(.toggle) == .notPermitted)
  #expect(rig.dispatched.isEmpty)
}

// MARK: - Queue boundaries

@Test @MainActor func steppingIsRefusedAtTheQueueEdges() {
  let rig = Rig()
  rig.snapshot = makeSnapshot(canStepNext: false, canStepPrevious: false)

  #expect(rig.send(.next) == .notPermitted)
  #expect(rig.send(.previous) == .notPermitted)
  #expect(rig.dispatched.isEmpty)

  rig.snapshot = makeSnapshot(canStepNext: true, canStepPrevious: false)
  #expect(rig.send(.next) == .handled)
  #expect(rig.send(.previous) == .notPermitted)
  #expect(rig.dispatched == [.next])
}

// MARK: - Seek

@Test @MainActor func seekIsClampedToTheTrackLength() {
  let rig = Rig()
  rig.snapshot = makeSnapshot(durationSeconds: 200)

  #expect(rig.send(.seek(500)) == .handled)
  #expect(rig.send(.seek(-30)) == .handled)
  #expect(rig.dispatched == [.seek(200), .seek(0)])
}

@Test @MainActor func seekIsRefusedWithoutAKnownLength() {
  let rig = Rig()
  rig.snapshot = makeSnapshot(durationSeconds: nil)

  #expect(rig.send(.seek(10)) == .notPermitted)
  #expect(rig.dispatched.isEmpty)
}

// MARK: - Like

@Test @MainActor func likingIsRefusedWhileTheLikedStateIsUnknown() {
  let rig = Rig()
  rig.snapshot = makeSnapshot(liked: .unknown)

  // The toggle's starting position would be a guess, so the command centre
  // must not offer to flip it.
  #expect(rig.send(.setLiked(true)) == .notPermitted)
  #expect(rig.dispatched.isEmpty)

  rig.snapshot = makeSnapshot(liked: .notLiked)
  #expect(rig.send(.setLiked(true)) == .handled)
  #expect(rig.dispatched == [.setLiked(true)])
}

// MARK: - Result accuracy

@Test @MainActor func aRefusedIntentIsReportedAsFailed() {
  let rig = Rig()
  rig.snapshot = makeSnapshot(state: .playing)
  rig.accepts = false

  #expect(rig.send(.pause) == .failed)
  #expect(rig.dispatched == [.pause])
}

// MARK: - Publishing

@Test @MainActor func refreshPublishesOnlyWhatIsNew() {
  let rig = Rig()
  rig.snapshot = makeSnapshot(elapsedSeconds: 0)

  rig.coordinator.refresh()
  #expect(rig.surface.published.count == 1)

  // The clock advanced; the system extrapolates that itself.
  rig.snapshot = makeSnapshot(elapsedSeconds: 30)
  rig.coordinator.refresh()
  #expect(rig.surface.published.count == 1)

  // A seek is a discontinuity, so it must be published.
  rig.snapshot = makeSnapshot(elapsedSeconds: 90, positionEpoch: 1)
  rig.coordinator.refresh()
  #expect(rig.surface.published.count == 2)
  #expect(rig.surface.published.last?.elapsedSeconds == 90)
}

@Test @MainActor func anEmptyProjectionClearsTheSurfaceInsteadOfPublishing() {
  let rig = Rig()
  rig.snapshot = makeSnapshot()
  rig.coordinator.refresh()
  #expect(rig.surface.published.count == 1)

  rig.snapshot = .empty
  rig.coordinator.refresh()

  // Publishing an empty item would leave MacEase advertising a track it is no
  // longer playing.
  #expect(rig.surface.published.count == 1)
  #expect(rig.surface.clearCount == 1)
}

@Test @MainActor func clearingForgetsWhatWasPublished() {
  let rig = Rig()
  rig.snapshot = makeSnapshot()
  rig.coordinator.refresh()
  #expect(rig.surface.published.count == 1)

  rig.coordinator.clear()
  #expect(rig.surface.clearCount == 1)

  // The same snapshot must publish again after a clear, otherwise a sign-out
  // and sign-in with the same track would leave the surface empty.
  rig.coordinator.refresh()
  #expect(rig.surface.published.count == 2)
}

@Test @MainActor func aLateArtworkFreeSnapshotForAnOldTrackCannotSurvive() {
  let rig = Rig()
  rig.snapshot = makeSnapshot(trackID: 101)
  rig.coordinator.refresh()

  rig.snapshot = makeSnapshot(trackID: 202)
  rig.coordinator.refresh()

  // The projection is read at publish time, so there is no queued update for
  // 101 that could land after 202.
  #expect(rig.surface.published.map(\.trackID) == [101, 202])
}
