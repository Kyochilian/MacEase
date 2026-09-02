import Foundation
import NeteaseKit
import Testing

@testable import MacEaseAppCore

/// P0: the lyric backend reaching the product.
///
/// The rule the coordinator has to hold is a request budget: nothing is
/// fetched until the panel is open, an open panel costs one request per track
/// change, and a track already fetched costs none.

@MainActor
private struct LyricsRig {
  let transport = FakeTransport()
  let vault: FakeVault
  let arbiter = OperationArbiter()
  let session: FakeSession
  let lyrics: LyricsCoordinator

  init() {
    let credential = makeCredential()
    vault = FakeVault(stored: credential)
    session = FakeSession(credential: credential)
    lyrics = LyricsCoordinator(
      transport: transport,
      vault: vault,
      arbiter: arbiter
    )
  }

  func open(_ track: Track?) async {
    lyrics.setPanelVisible(true, track: track, session: session)
    await lyrics.settleForTesting()
  }

  func change(to track: Track?) async {
    lyrics.load(track: track, session: session)
    await lyrics.settleForTesting()
  }
}

private let document = Lyrics.lines([LyricLine(timeSeconds: 1, text: "One")])

@Test @MainActor func aClosedPanelNeverRequestsLyrics() async {
  let rig = LyricsRig()
  await rig.transport.setLyrics(.success(document))

  await rig.change(to: makeTracks([1])[0])

  #expect(await rig.transport.callCount() == 0)
  #expect(rig.lyrics.content == .idle)
}

@Test @MainActor func openingThePanelLoadsTheCurrentTrackOnce() async {
  let rig = LyricsRig()
  await rig.transport.setLyrics(.success(document))
  let track = makeTracks([1])[0]

  await rig.open(track)

  #expect(rig.lyrics.content == .document(document))
  #expect(await rig.transport.recordedCalls() == [.lyrics(1)])
}

/// The panel following the queue is the point of having it open, but a track
/// the user steps back to must not be paid for twice.
@Test @MainActor func anOpenPanelCostsOneRequestPerNewTrack() async {
  let rig = LyricsRig()
  await rig.transport.setLyrics(.success(document))
  let tracks = makeTracks([1, 2])

  await rig.open(tracks[0])
  await rig.change(to: tracks[1])
  await rig.change(to: tracks[1])

  #expect(await rig.transport.recordedCalls() == [.lyrics(1), .lyrics(2)])
}

/// The previous song's words must never appear under the new song's title,
/// not even for the moment the request is in flight.
@Test @MainActor func aTrackChangeClearsTheOldDocumentBeforeLoading() async {
  let rig = LyricsRig()
  await rig.transport.setLyrics(.success(document))
  let tracks = makeTracks([1, 2])
  await rig.open(tracks[0])

  await rig.transport.gate.close()
  rig.lyrics.load(track: tracks[1], session: rig.session)

  #expect(rig.lyrics.content == .loading)
  await rig.transport.gate.open()
  await rig.lyrics.settleForTesting()
}

@Test @MainActor func aLateLyricResponseCannotReplaceTheNewTracksDocument() async {
  let rig = LyricsRig()
  let old = Lyrics.lines([LyricLine(timeSeconds: 1, text: "Old")])
  let new = Lyrics.lines([LyricLine(timeSeconds: 2, text: "New")])
  await rig.transport.setLyrics([.success(old), .success(new)])
  await rig.transport.gate.close()
  let tracks = makeTracks([1, 2])

  rig.lyrics.setPanelVisible(true, track: tracks[0], session: rig.session)
  while await rig.transport.gate.arrivalCount() < 1 { await Task.yield() }
  rig.lyrics.load(track: tracks[1], session: rig.session)
  while await rig.transport.gate.arrivalCount() < 2 { await Task.yield() }
  await rig.transport.gate.releaseNewestArrival()
  await rig.lyrics.settleForTesting()

  #expect(rig.lyrics.content == .document(new))
  #expect(rig.lyrics.status.hasSuffix("for track-2"))

  await rig.transport.gate.open()
  for _ in 0..<5 { await Task.yield() }
  #expect(rig.lyrics.content == .document(new))
  #expect(rig.lyrics.status.hasSuffix("for track-2"))
}

@Test @MainActor func aSongWithoutLyricsIsAnAnswerRatherThanAFailure() async {
  let rig = LyricsRig()
  await rig.transport.setLyrics(.success(.none))

  await rig.open(makeTracks([1])[0])

  #expect(rig.lyrics.content == .unavailable)
  #expect(rig.lyrics.status.hasSuffix("has no lyrics"))
}

@Test @MainActor func aFailedLoadReportsWithoutRetrying() async {
  let rig = LyricsRig()
  await rig.transport.setLyrics(.failure(URLError(.timedOut)))

  await rig.open(makeTracks([1])[0])

  #expect(rig.lyrics.content == .idle)
  #expect(rig.lyrics.status == "Lyrics timed out; try again when the connection is better (timeout)")
  #expect(await rig.transport.callCount() == 1)
}

/// A failed load must not be remembered as loaded, or reopening the panel on
/// the same track would show nothing and never try again.
@Test @MainActor func aFailedTrackIsRequestedAgainOnTheNextAttempt() async {
  let rig = LyricsRig()
  await rig.transport.setLyrics(.failure(URLError(.timedOut)))
  let track = makeTracks([1])[0]
  await rig.open(track)

  await rig.transport.setLyrics(.success(document))
  await rig.change(to: track)

  #expect(rig.lyrics.content == .document(document))
  #expect(await rig.transport.callCount() == 2)
}

@Test @MainActor func closingThePanelStopsFollowingTheQueue() async {
  let rig = LyricsRig()
  await rig.transport.setLyrics(.success(document))
  let tracks = makeTracks([1, 2])
  await rig.open(tracks[0])

  rig.lyrics.setPanelVisible(false, track: tracks[0], session: rig.session)
  await rig.change(to: tracks[1])

  #expect(await rig.transport.recordedCalls() == [.lyrics(1)])
}

/// An identity change must take the previous account's lyrics with it, and
/// must not leave the coordinator thinking it still holds that track.
@Test @MainActor func resetDropsTheDocumentAndTheLoadedTrack() async {
  let rig = LyricsRig()
  await rig.transport.setLyrics(.success(document))
  let track = makeTracks([1])[0]
  await rig.open(track)

  rig.lyrics.reset()
  #expect(rig.lyrics.content == .idle)

  await rig.change(to: track)
  #expect(await rig.transport.callCount() == 2)
}

@Test @MainActor func loadingWithoutAValidatedAccountAsksForValidationFirst() async {
  let rig = LyricsRig()
  rig.session.account = nil

  await rig.open(makeTracks([1])[0])

  #expect(rig.lyrics.status == "Validate the session before loading lyrics")
  #expect(await rig.transport.callCount() == 0)
  #expect(rig.arbiter.isBusy == false)
  #expect(rig.arbiter.activeReadCount == 0)
}

@Test @MainActor func lyricDisplayPreferencesPersistInTheSingleSettingsSource() {
  let suite = UserDefaults(suiteName: "macease.tests.\(UUID().uuidString)") ?? .standard
  let settings = AppSettings(defaults: suite)
  #expect(settings.showsLyricTranslation)
  #expect(!settings.showsLyricRomanisation)
  #expect(settings.usesVerbatimLyrics)

  settings.showsLyricTranslation = false
  settings.showsLyricRomanisation = true
  settings.usesVerbatimLyrics = false
  let restored = AppSettings(defaults: suite)
  #expect(!restored.showsLyricTranslation)
  #expect(restored.showsLyricRomanisation)
  #expect(!restored.usesVerbatimLyrics)
}
