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
/// Reopening the panel reuses its current document.
@MainActor
@Observable
package final class LyricsCoordinator: SessionGuardedCoordinator {
  package enum Content: Equatable {
    case idle
    case loading
    /// The catalogue answered, and the answer was that this song has none.
    case unavailable
    case notSaved
    case failed
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
  @ObservationIgnored private var store: LibraryStore?
  package private(set) var offsetSeconds: Double = 0

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

  package func attach(store: LibraryStore?) { self.store = store }

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
      cancelInFlightLoad()
      return
    }
    load(track: track, session: session)
  }

  /// Called when the panel is open and the playing track changed.
  package func load(track: Track?, session: any SessionProviding, forceReload: Bool = false) {
    guard isPanelVisible else { return }
    guard let track else {
      cancelInFlightLoad()
      clearDocument()
      status = "Nothing is playing"
      return
    }
    guard forceReload || track.id != loadedTrackID else { return }
    cancelInFlightLoad()
    clearDocument()
    guard let account = session.account else {
      status = "Sign in before loading lyrics"
      return
    }
    generation += 1
    let currentGeneration = generation
    // Cleared before the request so the panel never shows the previous song's
    // words under the new song's title.
    content = .loading
    status = "Loading lyrics for \(track.name)"
    loadedTrackID = nil
    loadTask = Task {
      do {
        guard let credential = try await vault.load(),
          session.matchesLocalSession(credential, account: account),
          self.generation == currentGeneration
        else { return }
        let saved = try await store?.savedLyrics(accountID: account.userID, songID: track.id)
        guard self.generation == currentGeneration, !Task.isCancelled else { return }
        offsetSeconds = saved?.offset ?? 0
        if !forceReload, let document = saved?.document {
          loadedTrackID = track.id
          content = document.isEmpty ? .unavailable : .document(document)
          status = document.isEmpty ? "This song has no lyrics" : "Saved lyrics"
          loadTask = nil
          return
        }
        guard session.isOnline else {
          content = .notSaved
          status = "Lyrics have not been saved for this song"
          loadTask = nil
          return
        }
      } catch {
        guard self.generation == currentGeneration else { return }
        if !session.isOnline {
          content = .failed
          status = "Saved lyrics could not be read"
          loadTask = nil
          return
        }
      }
      guard let token = await arbiter.beginWhenAvailable(name: "Lyrics", effect: .read)
      else {
        if self.generation == currentGeneration {
          self.content = .failed
          self.status = "Lyrics are busy; reload to try again"
          self.loadTask = nil
        }
        return
      }
      guard self.generation == currentGeneration, !Task.isCancelled else {
        arbiter.end(token, outcome: .cancelled)
        return
      }
      operationToken = token
      var outcome = OperationOutcome.failed
      defer {
        releaseSessionOperation(
          token,
          currentToken: &self.operationToken,
          arbiter: self.arbiter,
          outcome: outcome
        )
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
        let lyrics = try await fetchLyrics(
          track: track, account: account, credential: credential, session: session)
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
        } else if lyrics.isInstrumental {
          content = .document(lyrics)
          status = "\(track.name) is instrumental"
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
        content = .failed
        status = failure.statusText(operation: "Lyrics")
      }
    }
  }

  package func reload(track: Track?, session: any SessionProviding) {
    load(track: track, session: session, forceReload: true)
  }

  package func setOffset(_ seconds: Double, session: any SessionProviding) {
    guard seconds.isFinite, (-30...30).contains(seconds),
      let account = session.account, let songID = loadedTrackID
    else { return }
    offsetSeconds = seconds
    let expectedGeneration = generation
    Task {
      do {
        try await store?.saveLyricOffset(seconds, accountID: account.userID, songID: songID)
      } catch {
        if generation == expectedGeneration { status = "Lyric offset could not be saved" }
      }
    }
  }

  /// Saving lyrics is part of an explicit download or Save Lyrics action.
  /// Failure here never changes an already completed audio download.
  package func saveForOffline(track: Track, session: any SessionProviding) async -> String? {
    guard let store, let account = session.account else { return "Lyric storage is unavailable" }
    do {
      if loadedTrackID == track.id {
        if case .document(let document) = content {
          try await store.saveLyrics(document, accountID: account.userID, songID: track.id)
          return nil
        }
        if content == .unavailable {
          try await store.saveLyrics(.none, accountID: account.userID, songID: track.id)
          return nil
        }
      }
      guard session.isOnline else { return "Connect to save lyrics" }
      guard let token = await arbiter.beginWhenAvailable(name: "Save lyrics", effect: .read)
      else { return "Lyrics were not saved; try again" }
      defer { arbiter.end(token, outcome: .applied) }
      guard let credential = try await vault.load(),
        session.matchesValidatedSession(credential, account: account), !Task.isCancelled
      else { return "Session changed before lyrics could be saved" }
      let document = try await fetchLyrics(
        track: track, account: account, credential: credential, session: session)
      guard try await vault.load() == credential,
        session.matchesValidatedSession(credential, account: account), !Task.isCancelled
      else { return "Session changed before lyrics could be saved" }
      try await store.saveLyrics(document, accountID: account.userID, songID: track.id)
      return nil
    } catch {
      return "Lyrics could not be saved; reload them when connected"
    }
  }

  /// Test seam: awaits the task the last explicit action started.
  private func fetchLyrics(
    track: Track, account: NeteaseAccount, credential: NeteaseCredential,
    session: any SessionProviding
  ) async throws -> Lyrics {
    if let cloudID = track.cloudFileID {
      let embedded = try await transport.cloudLyrics(
        userID: account.userID, songID: cloudID, credential: credential)
      if !embedded.isEmpty || track.catalogSongID == nil { return embedded }
      try Task.checkCancellation()
      guard session.matchesValidatedSession(credential, account: account) else {
        throw CancellationError()
      }
    }
    return try await transport.lyrics(
      songID: track.catalogSongID ?? track.id, credential: credential)
  }

  package func settleForTesting() async {
    await loadTask?.value
  }

  package func reset() {
    cancelInFlightLoad()
    clearDocument()
    status = "Open a track to see its lyrics"
  }

  private func cancelInFlightLoad() {
    generation += 1
    loadTask?.cancel()
    loadTask = nil
    if let operationToken {
      self.operationToken = nil
      arbiter.end(operationToken, outcome: .cancelled)
    }
  }

  private func clearDocument() {
    loadedTrackID = nil
    offsetSeconds = 0
    content = .idle
  }

}
