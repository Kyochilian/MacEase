import Foundation
import NeteaseKit
import Observation

@MainActor
@Observable
package final class PlaylistLibraryCoordinator: SessionGuardedCoordinator {
  private static let playlistPageSize = 30

  @ObservationIgnored private let transport: any NeteaseTransporting
  @ObservationIgnored package let vault: any CredentialStoring
  @ObservationIgnored private let arbiter: OperationArbiter
  @ObservationIgnored package private(set) var generation = 0
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var trackIDs: [Int64] = []
  @ObservationIgnored private var loadedTrackIDCount = 0

  package var noStoredSessionStatus: String { "No stored session to load library" }

  package func clearSessionScopedData() {
    clearLibrary()
  }

  package var playlists: [UserPlaylist] = []
  package var selectedPlaylist: UserPlaylist?
  package var tracks: [PlaylistTrack] = []
  package var likedIDs: Set<Int64>?
  package var hasMore = false
  package var hasMoreTracks = false
  package var isLoading = false
  package var status = "Validate the session before loading playlists"

  package init(
    transport: any NeteaseTransporting,
    vault: any CredentialStoring,
    arbiter: OperationArbiter
  ) {
    self.transport = transport
    self.vault = vault
    self.arbiter = arbiter
  }

  package func load(reset: Bool, session: any SessionProviding) {
    guard reset || hasMore else { return }
    guard
      let claim = claim(
        "Playlist",
        effect: .read,
        session: session,
        noAccountStatus: "Validate the session before loading playlists"
      )
    else { return }

    if reset { clearDetail() }
    let currentGeneration = generation
    let offset = reset ? 0 : playlists.count
    let account = claim.account
    isLoading = true
    status = "Loading playlists (1 request)"
    loadTask = Task {
      await perform(
        claim: claim,
        generation: currentGeneration,
        session: session,
        invalidateOnService301: true,
        operation: "Playlist"
      ) { credential in
        let page = try await self.transport.userPlaylists(
          userID: account.userID,
          limit: Self.playlistPageSize,
          offset: offset,
          credential: credential
        )
        guard
          try await self.sessionRemainsCurrent(
            account: account,
            credential: credential,
            generation: currentGeneration,
            session: session
          )
        else { return false }

        if reset {
          self.playlists = page.playlists
        } else {
          self.playlists.append(contentsOf: page.playlists)
        }
        self.hasMore = page.more
        self.status = "Loaded \(self.playlists.count) playlists"
        return true
      }
    }
  }

  package func loadTracks(
    for playlist: UserPlaylist,
    session: any SessionProviding
  ) {
    guard
      let claim = claim(
        "Playlist/song detail",
        effect: .read,
        session: session,
        noAccountStatus: "Validate the session before loading tracks"
      )
    else { return }

    generation += 1
    let currentGeneration = generation
    let account = claim.account
    clearDetail()
    selectedPlaylist = playlist
    isLoading = true
    status = "Loading playlist metadata (request 1 of 2)"
    loadTask = Task {
      await perform(
        claim: claim,
        generation: currentGeneration,
        session: session,
        invalidateOnService301: false,
        operation: "Playlist/song detail"
      ) { credential in
        let detail = try await self.transport.playlistDetail(
          playlistID: playlist.id,
          credential: credential
        )
        guard
          try await self.sessionRemainsCurrent(
            account: account,
            credential: credential,
            generation: currentGeneration,
            session: session
          )
        else { return false }
        self.selectedPlaylist = UserPlaylist(
          id: playlist.id,
          name: detail.name,
          trackCount: detail.trackIDs.count,
          owned: playlist.owned
        )
        guard !detail.trackIDs.isEmpty else {
          self.status = "Loaded an empty playlist (1 request)"
          return true
        }

        let batchIDs = Array(
          detail.trackIDs.prefix(NeteaseSession.songDetailRequestLimit)
        )
        self.status = "Loading song metadata (request 2 of 2)"
        let batch = try await self.transport.songDetails(
          songIDs: batchIDs,
          credential: credential
        )
        guard
          try await self.sessionRemainsCurrent(
            account: account,
            credential: credential,
            generation: currentGeneration,
            session: session
          )
        else { return false }

        self.trackIDs = detail.trackIDs
        self.loadedTrackIDCount = batchIDs.count
        self.tracks = batch
        self.hasMoreTracks = batchIDs.count < detail.trackIDs.count
        self.status =
          "Loaded \(batch.count) tracks from \(batchIDs.count) "
          + "of \(detail.trackIDs.count) IDs"
        return true
      }
    }
  }

  package func loadMoreTracks(session: any SessionProviding) {
    guard hasMoreTracks else { return }
    guard
      let claim = claim(
        "Song detail",
        effect: .read,
        session: session,
        noAccountStatus: "Validate the session before loading tracks"
      )
    else { return }

    let currentGeneration = generation
    let account = claim.account
    isLoading = true
    status = "Loading the next track batch (1 request)"
    loadTask = Task {
      await perform(
        claim: claim,
        generation: currentGeneration,
        session: session,
        invalidateOnService301: false,
        operation: "Song detail"
      ) { credential in
        let end = min(
          self.loadedTrackIDCount + NeteaseSession.songDetailRequestLimit,
          self.trackIDs.count
        )
        let batchIDs = Array(self.trackIDs[self.loadedTrackIDCount..<end])
        let batch = try await self.transport.songDetails(
          songIDs: batchIDs,
          credential: credential
        )
        guard
          try await self.sessionRemainsCurrent(
            account: account,
            credential: credential,
            generation: currentGeneration,
            session: session
          )
        else { return false }

        self.tracks.append(contentsOf: batch)
        self.loadedTrackIDCount = end
        self.hasMoreTracks = end < self.trackIDs.count
        self.status =
          "Loaded \(self.tracks.count) tracks from \(end) "
          + "of \(self.trackIDs.count) IDs"
        return true
      }
    }
  }

  package func loadLikedIDs(session: any SessionProviding) {
    guard
      let claim = claim(
        "Liked songs",
        effect: .read,
        session: session,
        noAccountStatus: "Validate the session before loading liked songs"
      )
    else { return }

    let currentGeneration = generation
    let account = claim.account
    isLoading = true
    status = "Loading liked song IDs (1 request)"
    loadTask = Task {
      await perform(
        claim: claim,
        generation: currentGeneration,
        session: session,
        invalidateOnService301: false,
        operation: "Liked songs"
      ) { credential in
        let ids = try await self.transport.likedSongIDs(
          userID: account.userID,
          credential: credential
        )
        guard
          try await self.sessionRemainsCurrent(
            account: account,
            credential: credential,
            generation: currentGeneration,
            session: session
          )
        else { return false }

        self.likedIDs = Set(ids)
        self.status = "Loaded \(ids.count) liked song IDs"
        return true
      }
    }
  }

  /// Toggles the server-side liked state for one track (1 request). On
  /// success only `likedIDs` is updated locally; the liked list is never
  /// auto-refreshed. Any failure is reported and stops.
  package func setLiked(
    _ liked: Bool,
    for track: PlaylistTrack,
    session: any SessionProviding
  ) {
    write(
      loadingStatus: liked
        ? "Liking the track (1 request)" : "Unliking the track (1 request)",
      operation: liked ? "Like" : "Unlike",
      session: session,
      noAccountStatus: "Validate the session before changing liked songs"
    ) { credential in
      try await self.transport.setSongLiked(
        songID: track.id,
        liked: liked,
        credential: credential
      )
      return {
        if self.likedIDs != nil {
          if liked {
            self.likedIDs?.insert(track.id)
          } else {
            self.likedIDs?.remove(track.id)
          }
        }
        return
          (liked ? "Liked " : "Unliked ") + track.name
          + (self.likedIDs == nil ? "; load liked IDs to see hearts" : "")
      }
    }
  }

  /// Playlist write actions (1 request each). None of them triggers an
  /// automatic reload: the user reloads explicitly, so the request count stays
  /// exactly what the button promises.
  package func createPlaylist(named name: String, session: any SessionProviding) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    write(
      loadingStatus: "Creating the playlist (1 request)",
      operation: "Create playlist",
      session: session
    ) { credential in
      try await self.transport.createPlaylist(name: trimmed, credential: credential)
      return { "Created \(trimmed); Load Playlists to see it" }
    }
  }

  package func deletePlaylist(
    _ playlist: UserPlaylist,
    session: any SessionProviding
  ) {
    write(
      loadingStatus: "Deleting the playlist (1 request)",
      operation: "Delete playlist",
      session: session
    ) { credential in
      try await self.transport.deletePlaylist(
        playlistID: playlist.id,
        credential: credential
      )
      return {
        self.playlists.removeAll { $0.id == playlist.id }
        if self.selectedPlaylist?.id == playlist.id {
          self.clearDetail()
        }
        return "Deleted \(playlist.name)"
      }
    }
  }

  package func renameSelectedPlaylist(
    to name: String,
    session: any SessionProviding
  ) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let playlist = selectedPlaylist, !trimmed.isEmpty,
      trimmed != playlist.name
    else { return }
    write(
      loadingStatus: "Renaming the playlist (1 request)",
      operation: "Rename playlist",
      session: session
    ) { credential in
      try await self.transport.renamePlaylist(
        playlistID: playlist.id,
        name: trimmed,
        credential: credential
      )
      return {
        let renamed = UserPlaylist(
          id: playlist.id,
          name: trimmed,
          trackCount: playlist.trackCount,
          owned: playlist.owned
        )
        self.selectedPlaylist = renamed
        if let index = self.playlists.firstIndex(where: { $0.id == playlist.id }) {
          self.playlists[index] = renamed
        }
        return "Renamed to \(trimmed)"
      }
    }
  }

  package func addTrack(
    _ track: PlaylistTrack,
    to playlist: UserPlaylist,
    session: any SessionProviding
  ) {
    write(
      loadingStatus: "Adding the track (1 request)",
      operation: "Add track",
      session: session
    ) { credential in
      try await self.transport.editPlaylistTracks(
        .add,
        playlistID: playlist.id,
        trackIDs: [track.id],
        credential: credential
      )
      return { "Added \(track.name) to \(playlist.name)" }
    }
  }

  /// Removes from the currently selected playlist and drops the row locally;
  /// the detail list is not refetched.
  package func removeSelectedPlaylistTrack(
    at index: Int,
    session: any SessionProviding
  ) {
    guard let playlist = selectedPlaylist, tracks.indices.contains(index) else {
      return
    }
    let track = tracks[index]
    write(
      loadingStatus: "Removing the track (1 request)",
      operation: "Remove track",
      session: session
    ) { credential in
      try await self.transport.editPlaylistTracks(
        .del,
        playlistID: playlist.id,
        trackIDs: [track.id],
        credential: credential
      )
      return {
        if self.tracks.indices.contains(index), self.tracks[index].id == track.id {
          self.tracks.remove(at: index)
        }
        return "Removed \(track.name) from \(playlist.name)"
      }
    }
  }

  /// Subscribes to a playlist discovered elsewhere (1 request). See
  /// `NeteaseSession.setPlaylistSubscribed` for the anti-cheat token note: a
  /// `-460` here means the endpoint demands one and the action simply stops.
  package func setSubscribed(
    _ subscribed: Bool,
    playlistID: Int64,
    playlistName: String,
    session: any SessionProviding
  ) {
    write(
      loadingStatus: subscribed
        ? "Subscribing to the playlist (1 request)"
        : "Unsubscribing from the playlist (1 request)",
      operation: subscribed ? "Subscribe" : "Unsubscribe",
      session: session
    ) { credential in
      try await self.transport.setPlaylistSubscribed(
        subscribed,
        playlistID: playlistID,
        credential: credential
      )
      return {
        (subscribed ? "Subscribed to " : "Unsubscribed from ") + playlistName
          + "; Load Playlists to refresh"
      }
    }
  }

  /// The write body performs the request and returns the local-state update,
  /// which runs only after the postflight session check passes.
  private func write(
    loadingStatus: String,
    operation: String,
    session: any SessionProviding,
    noAccountStatus: String = "Validate the session before changing playlists",
    body: @escaping @MainActor (NeteaseCredential) async throws -> @MainActor () -> String
  ) {
    guard
      let claim = claim(
        operation,
        effect: .write,
        session: session,
        noAccountStatus: noAccountStatus
      )
    else { return }

    let currentGeneration = generation
    let account = claim.account
    isLoading = true
    status = loadingStatus
    loadTask = Task {
      await perform(
        claim: claim,
        generation: currentGeneration,
        session: session,
        invalidateOnService301: false,
        operation: operation
      ) { credential in
        let apply = try await body(credential)
        guard
          try await self.sessionRemainsCurrent(
            account: account,
            credential: credential,
            generation: currentGeneration,
            session: session
          )
        else {
          // The request reached the server but the session it belonged to is
          // gone, so the local change must not be applied and the server
          // result cannot be reported either way.
          return false
        }
        self.status = apply()
        return true
      }
    }
  }

  /// Clears this coordinator's own state only. It never cancels another
  /// module's work, and it never cancels a write whose request has already
  /// been sent: that decision belongs to the arbiter.
  package func reset() {
    generation += 1
    loadTask?.cancel()
    loadTask = nil
    clearLibrary()
    isLoading = false
    status = "Validate the session before loading playlists"
  }

  /// Test seam: awaits the task the last explicit action started, so a test
  /// can assert on settled state without polling.
  package func settleForTesting() async {
    await loadTask?.value
  }

  private struct Claim {
    let token: OperationToken
    let account: NeteaseAccount
  }

  /// Claims the arbiter and the validated account together, so no entry point
  /// can start a request without holding both.
  private func claim(
    _ name: String,
    effect: OperationEffect,
    session: any SessionProviding,
    noAccountStatus: String
  ) -> Claim? {
    guard let token = arbiter.begin(name: name, effect: effect) else { return nil }
    guard let account = session.account else {
      arbiter.end(token, outcome: .failed)
      status = noAccountStatus
      return nil
    }
    return Claim(token: token, account: account)
  }

  /// Runs the body under the claimed operation. The body returns whether its
  /// result was published; a write that was sent but not published leaves the
  /// server outcome unknown, which the arbiter records.
  private func perform(
    claim: Claim,
    generation: Int,
    session: any SessionProviding,
    invalidateOnService301: Bool,
    operation: String,
    body: @MainActor (NeteaseCredential) async throws -> Bool
  ) async {
    var outcome = OperationOutcome.failed
    defer {
      arbiter.end(claim.token, outcome: outcome)
      finish(generation: generation)
    }

    var credential: NeteaseCredential?
    do {
      credential = try await currentCredential(
        account: claim.account,
        generation: generation,
        session: session
      )
      guard let credential else { return }
      arbiter.markRequestSent(claim.token)
      let published = try await body(credential)
      arbiter.markSettling(claim.token)
      outcome = published ? .applied : .outcomeUnknown
    } catch is CancellationError {
      outcome = .cancelled
    } catch {
      outcome = Task.isCancelled ? .cancelled : .failed
      await handle(
        error,
        credential: credential,
        generation: generation,
        session: session,
        invalidateOnService301: invalidateOnService301,
        operation: operation
      )
    }
  }

  private func handle(
    _ error: Error,
    credential: NeteaseCredential?,
    generation: Int,
    session: any SessionProviding,
    invalidateOnService301: Bool,
    operation: String
  ) async {
    guard self.generation == generation else { return }

    if let serviceError = error as? NeteaseServiceError {
      if invalidateOnService301, serviceError.source == .service,
        serviceError.statusCode == 301,
        let credential
      {
        let invalidation = await session.invalidateStoredSession(
          matching: credential,
          message: "Stored session expired; sign in again"
        )
        guard self.generation == generation else { return }
        clearLibrary()
        switch invalidation {
        case .deleted:
          status = "Stored session expired; sign in again"
        case .notCurrent:
          status = "Session changed; validate again"
        case .busy:
          status = "Session busy; validate again"
        case .failed:
          status = "Session invalidation failed"
        }
      } else {
        status = "\(operation) \(serviceError.source.rawValue) error \(serviceError.statusCode)"
      }
    } else if let vaultError = error as? CredentialVaultError {
      status = "Keychain error \(vaultError.diagnostic)"
    } else {
      status = "\(operation) network or response error"
    }
  }

  private func finish(generation: Int) {
    guard self.generation == generation else { return }
    isLoading = false
    loadTask = nil
  }

  private func clearLibrary() {
    playlists = []
    hasMore = false
    likedIDs = nil
    clearDetail()
  }

  private func clearDetail() {
    selectedPlaylist = nil
    trackIDs = []
    loadedTrackIDCount = 0
    tracks = []
    hasMoreTracks = false
  }
}
