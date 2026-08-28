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
  @ObservationIgnored private var operationToken: OperationToken?

  package var noStoredSessionStatus: String { "No stored session to load library" }

  package func clearSessionScopedData() {
    clearLibrary()
  }

  package private(set) var collection = PlaylistCollection()
  package private(set) var detail = PlaylistTrackCollection()
  package var selectedPlaylist: UserPlaylist?
  package private(set) var liked = LikedSongs()
  /// The last create result, so the form clears only its own successful input.
  package private(set) var lastCreateReceipt: CreateReceipt?
  package var isLoading = false
  package var status = "Validate the session before loading playlists"

  package var playlists: [UserPlaylist] { collection.playlists }
  package var tracks: [PlaylistTrack] { detail.tracks }
  /// Only true when the cursor still names the same server position.
  package var canLoadMore: Bool { collection.canLoadMore }
  package var canLoadMoreTracks: Bool { detail.canLoadMore }
  /// A write moved the server-side collection under the local cursor, so
  /// paging cannot continue and the user is asked to reload explicitly.
  package var playlistsNeedReload: Bool { collection.needsExplicitReload }
  package var tracksNeedReload: Bool { detail.needsExplicitReload }

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
    guard reset || collection.canLoadMore else { return }
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
    let offset = reset ? 0 : collection.nextOffset
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

        self.collection.apply(page: page, replacingAll: reset)
        self.status = "Loaded \(self.collection.playlists.count) playlists"
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
        let opened = UserPlaylist(
          id: playlist.id,
          name: detail.name,
          trackCount: detail.trackIDs.count,
          owned: playlist.owned
        )
        self.selectedPlaylist = opened
        // The detail is authoritative for the name and count, so the row in
        // the list cannot be left saying something different.
        self.collection.replace(opened)
        guard !detail.trackIDs.isEmpty else {
          self.detail.begin(trackIDs: [])
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

        self.detail.begin(trackIDs: detail.trackIDs)
        self.detail.appendBatch(batch, requestedCount: batchIDs.count)
        self.status =
          "Loaded \(batch.count) tracks from \(batchIDs.count) "
          + "of \(detail.trackIDs.count) IDs"
        return true
      }
    }
  }

  package func loadMoreTracks(session: any SessionProviding) {
    guard detail.canLoadMore else { return }
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
        let batchIDs = self.detail.nextBatch(
          limit: NeteaseSession.songDetailRequestLimit
        )
        guard !batchIDs.isEmpty else { return true }
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

        self.detail.appendBatch(batch, requestedCount: batchIDs.count)
        self.status =
          "Loaded \(self.detail.tracks.count) tracks from "
          + "\(self.detail.loadedIDCount) of \(self.detail.trackIDs.count) IDs"
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

        self.liked.load(ids)
        self.status = "Loaded \(ids.count) liked song IDs"
        return true
      }
    }
  }

  /// Toggles the server-side liked state for one track (1 request). On
  /// success only `likedIDs` is updated locally; the liked list is never
  /// auto-refreshed. Any failure is reported and stops.
  /// Returns whether the request was started, so a system control can report
  /// what actually happened instead of assuming it worked.
  @discardableResult
  package func setLiked(
    _ liked: Bool,
    for track: PlaylistTrack,
    session: any SessionProviding
  ) -> Bool {
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
        // The write proves this track's state, and only this track's.
        self.liked.setLiked(liked, trackID: track.id)
        return
          (liked ? "Liked " : "Unliked ") + track.name
          + (self.liked.isLoaded ? "" : "; load liked IDs to see every heart")
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
      session: session,
      recordsCreateReceipt: true
    ) { credential in
      try await self.transport.createPlaylist(name: trimmed, credential: credential)
      return {
        // The new playlist changes the server-side set and its ordering, so
        // the page cursor no longer names the same position.
        self.collection.markStaleAfterMutation()
        return "Created \(trimmed); Load Playlists to see it"
      }
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
        self.collection.remove(id: playlist.id)
        self.collection.markStaleAfterMutation()
        if self.selectedPlaylist?.id == playlist.id {
          self.clearDetail()
        }
        return "Deleted \(playlist.name); Load Playlists before paging again"
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
        // A rename changes neither membership nor the page cursor, so the
        // row is updated in place and paging stays usable.
        self.collection.replace(renamed)
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
      return {
        self.collection.adjustTrackCount(playlistID: playlist.id, by: 1)
        guard self.selectedPlaylist?.id == playlist.id else {
          return "Added \(track.name) to \(playlist.name)"
        }
        // The server chooses where the track lands, so the id order held
        // here is no longer authoritative for the open playlist.
        self.detail.markStaleAfterMutation()
        self.selectedPlaylist = self.selectedPlaylist.map {
          UserPlaylist(
            id: $0.id,
            name: $0.name,
            trackCount: $0.trackCount + 1,
            owned: $0.owned
          )
        }
        return
          "Added \(track.name) to \(playlist.name); "
          + "reload the playlist to see it in order"
      }
    }
  }

  /// Removes one track from the open playlist and applies the removal to
  /// every piece of local state at once. The track is named by id, never by
  /// row position, so a list that changed in the meantime cannot make the
  /// write land on a different row.
  package func removeSelectedPlaylistTrack(
    id trackID: Int64,
    session: any SessionProviding
  ) {
    guard let playlist = selectedPlaylist,
      let track = detail.tracks.first(where: { $0.id == trackID })
    else { return }
    write(
      loadingStatus: "Removing the track (1 request)",
      operation: "Remove track",
      session: session
    ) { credential in
      try await self.transport.editPlaylistTracks(
        .del,
        playlistID: playlist.id,
        trackIDs: [trackID],
        credential: credential
      )
      return {
        guard self.selectedPlaylist?.id == playlist.id,
          self.detail.removeTrack(id: trackID)
        else {
          // The open playlist changed while the write was in flight; the
          // server did remove the track, so say so without editing a list it
          // no longer belongs to.
          return "Removed \(track.name) from \(playlist.name); reload to refresh"
        }
        self.collection.adjustTrackCount(playlistID: playlist.id, by: -1)
        self.selectedPlaylist = self.selectedPlaylist.map {
          UserPlaylist(
            id: $0.id,
            name: $0.name,
            trackCount: max(0, $0.trackCount - 1),
            owned: $0.owned
          )
        }
        return "Removed \(track.name) from \(playlist.name)"
      }
    }
  }

  /// Subscribes to a playlist discovered elsewhere.
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
        if !subscribed {
          self.collection.remove(id: playlistID)
          if self.selectedPlaylist?.id == playlistID {
            self.clearDetail()
          }
        }
        // Either direction changes which playlists the account has.
        self.collection.markStaleAfterMutation()
        return
          (subscribed ? "Subscribed to " : "Unsubscribed from ") + playlistName
          + "; Load Playlists to refresh"
      }
    }
  }

  /// The write body performs the request and returns the local-state update,
  /// which runs only after the postflight session check passes.
  /// Returns whether the write was started. It says nothing about the
  /// server's answer, which arrives later; a caller that reports acceptance
  /// synchronously — the system media surface does — needs exactly this.
  @discardableResult
  private func write(
    loadingStatus: String,
    operation: String,
    session: any SessionProviding,
    noAccountStatus: String = "Validate the session before changing playlists",
    recordsCreateReceipt: Bool = false,
    body: @escaping @MainActor (NeteaseCredential) async throws -> @MainActor () -> String
  ) -> Bool {
    guard
      let claim = claim(
        operation,
        effect: .write,
        session: session,
        noAccountStatus: noAccountStatus
      )
    else { return false }

    let currentGeneration = generation
    let account = claim.account
    isLoading = true
    status = loadingStatus
    loadTask = Task {
      var outcome = OperationOutcome.failed
      defer {
        let resolved = release(claim.token, outcome: outcome)
        if recordsCreateReceipt, let resolved {
          self.lastCreateReceipt = CreateReceipt(outcome: resolved)
        }
        finish(generation: currentGeneration)
      }

      var credential: NeteaseCredential?
      do {
        credential = try await currentCredential(
          account: claim.account,
          generation: currentGeneration,
          session: session
        )
        guard let credential else { return }
        arbiter.markRequestSent(claim.token)
        let apply = try await body(credential)
        // The response is in hand: whatever happens next is a local-display
        // problem, not an unknown server state. The outcome therefore stays
        // `appliedRemotelyOnly` unless the local apply actually runs.
        arbiter.markSettling(claim.token)
        outcome = .appliedRemotelyOnly
        guard
          try await self.sessionRemainsCurrent(
            account: account,
            credential: credential,
            generation: currentGeneration,
            session: session
          )
        else {
          // The server did execute it; the session it belonged to is gone, so
          // the local change must not be applied.
          return
        }
        self.status = apply()
        outcome = .applied
      } catch is CancellationError {
        outcome = .cancelled
      } catch {
        if Task.isCancelled {
          outcome = .cancelled
        } else if let service = error as? NeteaseServiceError,
          Self.provesTheWriteDidNotRun(service)
        {
          outcome = .failed
        } else if arbiter.abandoningLosesTheOutcome(claim.token) {
          // The request left the client and nothing came back that proves what
          // the server did with it. Reporting a failure here would invite the
          // user to repeat a mutation that may already have been applied.
          outcome = .outcomeUnknown
        }
        await handle(
          error,
          credential: credential,
          readToken: claim.token,
          generation: currentGeneration,
          session: session,
          invalidateOnService301: false,
          operation: operation
        )
      }
    }
    return true
  }

  /// Whether a classified error is evidence that a write which had already
  /// been sent did not take effect.
  ///
  /// A `service` error is an application-layer answer: the request reached the
  /// endpoint, the endpoint decided, and it said no. A `http` 5xx is not an
  /// answer — the server failed while handling the request, and nothing in the
  /// response says whether it failed before or after applying the mutation. So
  /// only the first is a proven failure; the second must stay unknown.
  private static func provesTheWriteDidNotRun(_ error: NeteaseServiceError) -> Bool {
    guard error.source == .http else { return true }
    return !(500...599).contains(error.statusCode)
  }

  /// module's work, and it never cancels a write whose request is already in
  /// flight: that request is left to finish so the arbiter can classify what
  /// the server did, instead of the client guessing.
  package func reset() {
    generation += 1
    if !arbiter.activeWriteIsInFlight {
      loadTask?.cancel()
      loadTask = nil
      if let operationToken {
        release(operationToken, outcome: .cancelled)
      }
    }
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
    guard !isLoading else { return nil }
    guard let token = arbiter.begin(name: name, effect: effect) else { return nil }
    guard let account = session.account else {
      arbiter.end(token, outcome: .failed)
      status = noAccountStatus
      return nil
    }
    operationToken = token
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
      release(claim.token, outcome: outcome)
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
      // A read that could not be published changed nothing on the server.
      outcome = published ? .applied : .cancelled
    } catch is CancellationError {
      outcome = .cancelled
    } catch {
      outcome = Task.isCancelled ? .cancelled : .failed
      await handle(
        error,
        credential: credential,
        readToken: claim.token,
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
    readToken: OperationToken,
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
        detachTokenForInvalidation(readToken)
        let invalidation = await session.invalidateStoredSession(
          matching: credential,
          message: "Stored session expired; sign in again",
          readToken: readToken
        )
        guard self.generation == generation else { return }
        switch invalidation {
        case .deleted:
          clearLibrary()
          status = "Stored session expired; sign in again"
        case .notCurrent:
          status = "Session changed; validate again"
        case .busy:
          status = "Session busy; validate again"
        case .failed:
          // The credential has stopped being validated even if the Keychain
          // item could not be deleted, so its data must go too.
          clearLibrary()
          status = "Stored session expired; sign in again"
        }
      } else {
        report(error, operation: operation)
      }
    } else {
      report(error, operation: operation)
    }
  }

  /// One classification for every failure this coordinator surfaces, so the
  /// same error does not read differently depending on where it was caught.
  private func report(_ error: any Error, operation: String) {
    let failure = OperationFailure.classify(error, cancelled: Task.isCancelled)
    guard failure.isReportable else { return }
    status = failure.statusText(operation: operation)
  }

  private func finish(generation: Int) {
    guard self.generation == generation else { return }
    isLoading = false
    loadTask = nil
  }

  @discardableResult
  private func release(
    _ token: OperationToken,
    outcome: OperationOutcome
  ) -> OperationOutcome? {
    if operationToken == token { operationToken = nil }
    return arbiter.end(token, outcome: outcome)
  }

  private func detachTokenForInvalidation(_ token: OperationToken) {
    guard operationToken == token else { return }
    operationToken = nil
  }

  private func clearLibrary() {
    collection.reset()
    liked.reset()
    lastCreateReceipt = nil
    clearDetail()
  }

  private func clearDetail() {
    selectedPlaylist = nil
    detail.reset()
  }
}
