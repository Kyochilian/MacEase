import Foundation
import NeteaseKit
import Observation

/// The lyric document for whatever is playing.
///
/// Loading is bounded by what the user asked for: nothing is fetched until the
/// lyrics panel is open, and while it is open a track change costs exactly one
/// request. Opening the panel *is* the request for the current track's lyrics,
/// so making the user press a second button for every song would be a worse
/// answer to the same question, not a more honest one.
///
/// A document already fetched for a track is not fetched again, so reopening
/// the panel or stepping back to the previous track costs nothing.
@MainActor
@Observable
package final class LyricsCoordinator: SessionGuardedCoordinator {
  package enum Content: Equatable {
    case idle
    case loading
    /// The catalogue answered, and the answer was that this song has none.
    case unavailable
    case document(Lyrics)
  }

  @ObservationIgnored private let transport: any NeteaseTransporting
  @ObservationIgnored package let vault: any CredentialStoring
  @ObservationIgnored private let arbiter: OperationArbiter
  @ObservationIgnored package private(set) var generation = 0
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var operationToken: OperationToken?
  /// The track the current content describes. A repeat request for the same
  /// track is answered from what is already held.
  @ObservationIgnored private var loadedTrackID: Int64?

  package var noStoredSessionStatus: String { "No stored session to load lyrics" }

  package private(set) var content: Content = .idle
  package var status = "Open a track to see its lyrics"
  /// Whether the panel is on screen. Nothing loads while this is false.
  package private(set) var isPanelVisible = false

  package init(
    transport: any NeteaseTransporting,
    vault: any CredentialStoring,
    arbiter: OperationArbiter
  ) {
    self.transport = transport
    self.vault = vault
    self.arbiter = arbiter
  }

  package func clearSessionScopedData() {
    clearDocument()
  }

  /// Opens or closes the panel. Opening loads the current track; closing
  /// abandons an in-flight read rather than finishing work nobody will see.
  package func setPanelVisible(
    _ visible: Bool,
    track: Track?,
    session: any SessionProviding
  ) {
    guard visible != isPanelVisible else { return }
    isPanelVisible = visible
    guard visible else {
      generation += 1
      loadTask?.cancel()
      loadTask = nil
      if let operationToken {
        release(operationToken, outcome: .cancelled)
      }
      return
    }
    load(track: track, session: session)
  }

  /// Called when the panel is open and the playing track changed.
  package func load(track: Track?, session: any SessionProviding) {
    guard isPanelVisible else { return }
    guard let track else {
      clearDocument()
      status = "Nothing is playing"
      return
    }
    guard track.id != loadedTrackID else { return }
    guard let token = arbiter.begin(name: "Lyrics", effect: .read) else { return }
    guard let account = session.account else {
      arbiter.end(token, outcome: .failed)
      status = "Validate the session before loading lyrics"
      return
    }

    operationToken = token
    generation += 1
    let currentGeneration = generation
    // Cleared before the request so the panel never shows the previous song's
    // words under the new song's title.
    content = .loading
    status = "Loading lyrics for \(track.name) (1 request)"
    loadedTrackID = nil
    loadTask = Task {
      var outcome = OperationOutcome.failed
      defer {
        release(token, outcome: outcome)
        if self.generation == currentGeneration { self.loadTask = nil }
      }
      do {
        guard
          let credential = try await currentCredential(
            account: account,
            generation: currentGeneration,
            session: session
          )
        else { return }
        let lyrics = try await transport.lyrics(
          songID: track.id,
          credential: credential
        )
        guard
          try await sessionRemainsCurrent(
            account: account,
            credential: credential,
            generation: currentGeneration,
            session: session
          )
        else { return }
        guard self.generation == currentGeneration else { return }

        loadedTrackID = track.id
        if lyrics.isEmpty {
          content = .unavailable
          status = "\(track.name) has no lyrics"
        } else {
          content = .document(lyrics)
          status = "Loaded \(lyrics.lines.count) lyric lines for \(track.name)"
        }
        outcome = .applied
      } catch {
        guard self.generation == currentGeneration else {
          outcome = .cancelled
          return
        }
        let failure = OperationFailure.classify(error, cancelled: Task.isCancelled)
        outcome = failure == .cancelled ? .cancelled : .failed
        guard failure.isReportable else { return }
        content = .idle
        status = failure.statusText(operation: "Lyrics")
      }
    }
  }

  /// Test seam: awaits the task the last explicit action started.
  package func settleForTesting() async {
    await loadTask?.value
  }

  package func reset() {
    generation += 1
    loadTask?.cancel()
    loadTask = nil
    if let operationToken {
      release(operationToken, outcome: .cancelled)
    }
    clearDocument()
    status = "Open a track to see its lyrics"
  }

  private func clearDocument() {
    loadedTrackID = nil
    content = .idle
  }

  private func release(_ token: OperationToken, outcome: OperationOutcome) {
    if operationToken == token { operationToken = nil }
    arbiter.end(token, outcome: outcome)
  }
}
