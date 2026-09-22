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
  @ObservationIgnored private var lastPlaylistPageSucceeded = false
  /// Emits only server-confirmed list state. Reset and disk restore never call
  /// it, so transient account changes cannot be mistaken for authoritative
  /// empty libraries.
  @ObservationIgnored package var onPersistablePlaylistsChanged:
    (@MainActor (Int64, [UserPlaylist]) async -> Void)?

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
  package var tracks: [Track] { detail.tracks }
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

  /// Shows what was stored for this account at the last launch, so the window
  /// is not empty while the user decides whether to reload. It issues no
  /// request and never overwrites rows the server has already confirmed this
  /// run.
  package func restore(playlists: [UserPlaylist]) {
    guard !playlists.isEmpty, collection.playlists.isEmpty, collection.freshness == .empty else {
      return
    }
    collection.restore(playlists)
    status = "Showing \(playlists.count) playlists from your last session; reload to refresh"
  }

  package func load(reset: Bool, session: any SessionProviding) {
    let reset = reset || collection.needsExplicitReload
    guard reset || collection.canLoadMore else { return }
    guard !isLoading, session.isOnline, let account = session.account else { return }
    let currentGeneration = generation
    let offset = reset ? 0 : collection.nextOffset
    isLoading = true
    lastPlaylistPageSucceeded = false
    status = "Loading playlists (1 request)"
    loadTask = Task {
      guard let token = await arbiter.beginWhenAvailable(name: "Playlist", effect: .read) else {
        if self.generation == currentGeneration {
          self.isLoading = false
          self.loadTask = nil
        }
        return
      }
      guard self.generation == currentGeneration, session.account?.userID == account.userID,
        !Task.isCancelled
      else {
        arbiter.end(token, outcome: .cancelled)
        return
      }
      self.operationToken = token
      let claim = SessionOperationClaim(token: token, account: account)
      await perform(
        claim: claim,
        generation: currentGeneration,
        session: session,
        invalidateOnService301: true,
        operation: "Playlist"
      ) { credential in
        async let initialLikes = self.initialLikedIDs(
          userID: account.userID, credential: credential)
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
        self.lastPlaylistPageSucceeded = true
        self.status = "Loaded \(self.collection.playlists.count) playlists"
        do {
          if let ids = try await initialLikes,
            try await self.sessionRemainsCurrent(
              account: account, credential: credential, generation: currentGeneration,
              session: session)
          {
            self.liked.load(ids)
          }
        } catch {
          guard self.generation == currentGeneration, !Task.isCancelled else { return false }
          self.status = "Playlists loaded; likes could not be refreshed"
        }
        // Persistence is the terminal await. Keeping it after every state
        // transition prevents an identity reset from entering halfway through
        // this apply and leaving the old task to publish more state afterwards.
        await self.persistPlaylists(for: account)
        return true
      }
    }
  }

  private func initialLikedIDs(userID: Int64, credential: NeteaseCredential) async throws
    -> [Int64]?
  {
    guard !liked.isLoaded else { return nil }
    return try await transport.likedSongIDs(userID: userID, credential: credential)
  }

  package func loadTracks(
    for playlist: UserPlaylist,
    session: any SessionProviding
  ) {
    guard operationToken?.kind != .exclusive else {
      status = "Wait for the playlist change to finish"
      return
    }
    cancelTrackLoading()
    guard session.isOnline, let account = session.account else {
      status = "Connect to open a playlist"
      return
    }

    generation += 1
    let currentGeneration = generation
    clearDetail()
    selectedPlaylist = playlist
    isLoading = true
    status = "Loading playlist"
    loadTask = Task {
      guard
        let claim = await claimRead(
          "Playlist/song detail", account: account, generation: currentGeneration, session: session)
      else { return }
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
        var opened = detail.metadata ?? playlist
        opened.name = detail.name
        opened.trackCount = detail.trackIDs.count
        opened.owned = detail.creatorID.map { $0 == account.userID } ?? playlist.owned
        self.selectedPlaylist = opened
        // The detail is authoritative for the name and count, so the row in
        // the list cannot be left saying something different.
        let previousPlaylists = self.collection.playlists
        self.collection.replace(opened)
        let playlistsChanged = self.collection.playlists != previousPlaylists
        self.detail.begin(detail)
        guard !detail.trackIDs.isEmpty else {
          self.status = "Loaded an empty playlist (1 request)"
          if playlistsChanged { await self.persistPlaylists(for: account) }
          return true
        }

        let batchIDs = self.detail.nextBatch(limit: NeteaseSession.songDetailRequestLimit)
        guard !batchIDs.isEmpty else {
          self.status = "Loaded \(self.tracks.count) tracks"
          if playlistsChanged { await self.persistPlaylists(for: account) }
          return true
        }
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

        self.detail.appendBatch(batch, requestedCount: batchIDs.count)
        self.status =
          "Loaded \(batch.count) tracks from \(batchIDs.count) "
          + "of \(detail.trackIDs.count) IDs"
        // Do not await local storage between the two server requests. A
        // concurrent read may invalidate the session while this task yields;
        // persistence therefore runs only after the complete local apply.
        if playlistsChanged { await self.persistPlaylists(for: account) }
        return true
      }
    }
  }

  package func cancelTrackLoading() {
    lastPlaylistPageSucceeded = false
    guard operationToken?.kind == .read || (operationToken == nil && isLoading) else { return }
    generation += 1
    loadTask?.cancel()
    loadTask = nil
    if let token = operationToken {
      operationToken = nil
      arbiter.end(token, outcome: .cancelled)
    }
    isLoading = false
  }

  package func loadAllPlaylists(session: any SessionProviding, untilLiked: Bool = false) async {
    let expected = generation
    await loadTask?.value
    guard generation == expected, !Task.isCancelled else { return }
    if collection.freshness != .current {
      load(reset: true, session: session)
      await loadTask?.value
      guard lastPlaylistPageSucceeded else { return }
    }
    for _ in 0..<1000 {
      guard generation == expected, !Task.isCancelled else { return }
      if untilLiked, playlists.contains(where: { $0.owned && $0.isLikedSongs }) { return }
      guard collection.canLoadMore else { return }
      let offset = collection.nextOffset
      load(reset: false, session: session)
      await loadTask?.value
      guard lastPlaylistPageSucceeded, collection.nextOffset > offset else { return }
    }
    status = "The playlist list is unusually large; load more to continue"
  }

  package func openLikedSongs(session: any SessionProviding) async {
    let expected = generation
    if !playlists.contains(where: { $0.owned && $0.isLikedSongs }) {
      await loadAllPlaylists(session: session, untilLiked: true)
    }
    guard generation == expected, !Task.isCancelled else { return }
    guard let playlist = playlists.first(where: { $0.owned && $0.isLikedSongs }) else {
      status = "This account has not returned a liked-songs playlist"
      return
    }
    loadTracks(for: playlist, session: session)
  }

  /// An explicit playback intent resolves the complete ID collection before
  /// replacing the sole playback queue. Missing songs retain their neighbours' order.
  package func playEntirePlaylist(
    startingAt songID: Int64? = nil,
    playback: PlaybackController,
    session: any SessionProviding
  ) {
    guard operationToken?.kind != .exclusive else {
      status = "Wait for the playlist change to finish"
      return
    }
    guard let playlist = selectedPlaylist else { return }
    cancelTrackLoading()
    guard session.isOnline, let account = session.account else {
      status = "Connect to load this playlist"
      return
    }
    let currentGeneration = generation
    let revision = playback.queueRevision
    let playbackIntent = playback.intentRevision
    isLoading = true
    status = "Preparing the complete playlist"
    loadTask = Task {
      guard
        let claim = await claimRead(
          "Play playlist", account: account, generation: currentGeneration, session: session)
      else { return }
      await perform(
        claim: claim, generation: currentGeneration, session: session,
        invalidateOnService301: true, operation: "Play playlist"
      ) { credential in
        if self.detail.freshness != .current {
          let metadata = try await self.transport.playlistDetail(
            playlistID: playlist.id, credential: credential
          )
          guard
            try await self.sessionRemainsCurrent(
              account: claim.account, credential: credential,
              generation: currentGeneration, session: session
            )
          else { return false }
          self.detail.begin(metadata)
        }
        while self.detail.canLoadMore {
          try Task.checkCancellation()
          guard playback.queueRevision == revision, playback.intentRevision == playbackIntent else {
            return false
          }
          let ids = self.detail.nextBatch(limit: NeteaseSession.songDetailRequestLimit * 4)
          let batch = try await self.fetchTrackBatches(ids, credential: credential)
          guard
            try await self.sessionRemainsCurrent(
              account: claim.account, credential: credential,
              generation: currentGeneration, session: session
            )
          else { return false }
          self.detail.appendBatch(batch, requestedCount: ids.count)
          self.status =
            "Preparing playlist: \(self.detail.loadedIDCount) / \(self.detail.trackIDs.count)"
        }
        guard self.selectedPlaylist?.id == playlist.id,
          playback.queueRevision == revision, playback.intentRevision == playbackIntent,
          !Task.isCancelled
        else { return false }
        let index: Int
        if let songID {
          guard let selected = self.tracks.firstIndex(where: { $0.id == songID }) else {
            self.status = "This song is no longer available"
            return false
          }
          index = selected
        } else {
          index = 0
        }
        guard let resolution = self.arbiter.transferRead(claim.token) else { return false }
        self.operationToken = nil
        let accepted = playback.play(
          tracks: self.tracks, startIndex: index,
          context: .playlist(id: playlist.id, name: playlist.name), session: session,
          reservedResolution: resolution
        )
        self.status = accepted ? "Prepared \(self.tracks.count) tracks" : playback.status
        return accepted
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
    status = "Loading more tracks"
    loadTask = Task {
      await perform(
        claim: claim,
        generation: currentGeneration,
        session: session,
        invalidateOnService301: false,
        operation: "Song detail"
      ) { credential in
        let batchIDs = self.detail.nextBatch(
          limit: NeteaseSession.songDetailRequestLimit * 4
        )
        guard !batchIDs.isEmpty else { return true }
        let batch = try await self.fetchTrackBatches(batchIDs, credential: credential)
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

  /// A large playlist resolves at most four metadata batches together. IDs
  /// and playback order remain owned by PlaylistTrackCollection.
  private func fetchTrackBatches(_ ids: [Int64], credential: NeteaseCredential) async throws
    -> [Track]
  {
    let transport = transport
    return try await withThrowingTaskGroup(of: [Track].self) { group in
      for offset in stride(from: 0, to: ids.count, by: NeteaseSession.songDetailRequestLimit) {
        let batch = Array(ids.dropFirst(offset).prefix(NeteaseSession.songDetailRequestLimit))
        group.addTask { try await transport.songDetails(songIDs: batch, credential: credential) }
      }
      var tracks: [Track] = []
      for try await batch in group { tracks += batch }
      return tracks
    }
  }

  /// Opening a playlist fills its remaining rows in the background. Each
  /// batch publishes immediately; failure stops at the last completed cursor.
  package func loadRemainingTracks(session: any SessionProviding) async {
    let expected = generation
    await withTaskCancellationHandler {
      await loadTask?.value
      for _ in 0..<1000 {
        guard generation == expected, !Task.isCancelled, detail.canLoadMore else { return }
        let cursor = detail.loadedIDCount
        loadMoreTracks(session: session)
        await loadTask?.value
        guard detail.loadedIDCount > cursor else { return }
      }
    } onCancel: {
      Task { @MainActor in
        if self.generation == expected { self.cancelTrackLoading() }
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

  /// Returns whether the request was started, so a system control can report
  /// what actually happened instead of assuming it worked.
  package func canWrite(session: any SessionProviding) -> Bool {
    session.account != nil && session.isOnline && !isLoading && arbiter.canBegin(effect: .write)
  }

  package func likedState(for track: Track) -> LikedState {
    track.catalogIdentity.map { liked.state(of: $0) } ?? .unknown
  }

  package func canLike(_ track: Track, session: any SessionProviding) -> Bool {
    track.catalogIdentity != nil && canWrite(session: session)
  }

  @discardableResult
  package func setLiked(
    _ liked: Bool,
    for track: Track,
    session: any SessionProviding
  ) -> Bool {
    guard let songID = track.catalogIdentity else {
      status = "Match this cloud file to a catalog song before liking it"
      return false
    }
    let likedPlaylist =
      collection.playlists.first { $0.owned && $0.isLikedSongs }
      ?? selectedPlaylist.flatMap { $0.owned && $0.isLikedSongs ? $0 : nil }
    let isOpen = likedPlaylist != nil && selectedPlaylist?.id == likedPlaylist?.id
    let hasCurrentDetail = isOpen && detail.freshness == .current
    let previousState =
      hasCurrentDetail
      ? (detail.trackIDs.contains(songID) ? LikedState.liked : .notLiked)
      : self.liked.state(of: songID)
    let changed = previousState != (liked ? .liked : .notLiked)
    // A removal preserves the known ID order, including unresolved pages.
    // An insertion needs the server's order; unknown membership needs its count.
    let needsReadback =
      previousState == .unknown || (liked && changed && isOpen)
      || (isOpen && !hasCurrentDetail)
    return write(
      loadingStatus: liked
        ? "Liking the track (1 request)" : "Unliking the track (1 request)",
      operation: liked ? "Like" : "Unlike",
      session: session,
      noAccountStatus: "Validate the session before changing liked songs",
      syncPlaylistID: needsReadback ? likedPlaylist?.id : nil
    ) { credential in
      try await self.transport.setSongLiked(
        songID: songID,
        liked: liked,
        credential: credential
      )
      return {
        // The write proves this track's state, and only this track's.
        self.liked.setLiked(liked, trackID: songID)
        if var playlist = likedPlaylist {
          if hasCurrentDetail && !liked {
            self.detail.removeTrack(id: songID)
            playlist.trackCount = self.detail.trackIDs.count
          } else if changed && previousState != .unknown {
            playlist.trackCount = max(0, playlist.trackCount + (liked ? 1 : -1))
          }
          self.collection.replace(playlist)
          if isOpen {
            self.selectedPlaylist = playlist
            if needsReadback { self.detail.markStaleAfterMutation() }
          }
        }
        return
          (liked ? "Liked " : "Unliked ") + track.name
          + (self.liked.isLoaded ? "" : "; load liked IDs to see every heart")
      }
    }
  }

  /// Playlist write actions (1 request each). None of them triggers an
  /// automatic reload: the user reloads explicitly, so the request count stays
  /// exactly what the button promises.
  package func createPlaylist(
    named name: String,
    isPrivate: Bool,
    session: any SessionProviding
  ) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    write(
      loadingStatus: isPrivate
        ? "Creating the private playlist (1 request)"
        : "Creating the playlist (1 request)",
      operation: "Create playlist",
      session: session,
      recordsCreateReceipt: true
    ) { credential in
      let created = try await self.transport.createPlaylist(
        name: trimmed,
        isPrivate: isPrivate,
        credential: credential
      )
      return {
        self.collection.insertCreated(created)
        self.selectedPlaylist = created
        self.detail.begin(trackIDs: [])
        return "Created \(created.name)"
      }
    }
  }

  /// Publishes a private playlist (1 request).
  ///
  /// Only an owned row confirmed private by `/user/playlist` is eligible.
  /// Success changes that row and the open detail to public without a read.
  /// Whether the server reorders the account's playlists afterwards is not
  /// verified, so the cursor is retired rather than trusted.
  package func publishPlaylist(
    _ playlist: UserPlaylist,
    session: any SessionProviding
  ) {
    guard
      let current = collection.playlists.first(where: { $0.id == playlist.id }),
      current.canEdit,
      current.isPrivate == true
    else { return }
    write(
      loadingStatus: "Publishing the playlist (1 request)",
      operation: "Publish playlist",
      session: session,
      syncCollection: true
    ) { credential in
      try await self.transport.publishPrivatePlaylist(
        playlistID: current.id,
        credential: credential
      )
      return {
        var published = current
        published.isPrivate = false
        self.collection.replace(published)
        if self.selectedPlaylist?.id == current.id {
          self.selectedPlaylist?.isPrivate = false
        }
        self.collection.markStaleAfterMutation()
        return "Published \(current.name)"
      }
    }
  }

  package func deletePlaylist(
    _ playlist: UserPlaylist,
    session: any SessionProviding
  ) {
    guard playlist.canEdit,
      collection.playlists.contains(where: { $0.id == playlist.id && $0.canEdit })
    else {
      status = "This playlist cannot be deleted"
      return
    }
    write(
      loadingStatus: "Deleting the playlist (1 request)",
      operation: "Delete playlist",
      session: session,
      syncCollection: true
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
        return "Deleted \(playlist.name)"
      }
    }
  }

  package func renameSelectedPlaylist(
    to name: String,
    session: any SessionProviding
  ) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let playlist = selectedPlaylist, playlist.canEdit, !trimmed.isEmpty,
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
        var renamed = playlist
        renamed.name = trimmed
        self.selectedPlaylist = renamed
        // A rename changes neither membership nor the page cursor, so the
        // row is updated in place and paging stays usable.
        self.collection.replace(renamed)
        return "Renamed to \(trimmed)"
      }
    }
  }

  package func addTrack(_ track: Track, to playlist: UserPlaylist, session: any SessionProviding) {
    editTracks(.add, tracks: [track], in: playlist, session: session)
  }

  package func removeSelectedPlaylistTrack(id trackID: Int64, session: any SessionProviding) {
    guard let playlist = selectedPlaylist, let track = tracks.first(where: { $0.id == trackID })
    else { return }
    editTracks(.del, tracks: [track], in: playlist, session: session)
  }

  package func editTracks(
    _ edit: PlaylistTrackEdit, tracks: [Track], in playlist: UserPlaylist,
    session: any SessionProviding
  ) {
    let target =
      collection.playlists.first(where: { $0.id == playlist.id })
      ?? (selectedPlaylist?.id == playlist.id ? selectedPlaylist : nil)
    guard let target, target.canEdit else {
      status = "This playlist cannot be edited"
      return
    }
    var seen = Set<Int64>()
    let candidates = tracks.compactMap { edit == .add ? $0.catalogIdentity : $0.id }
    guard candidates.count == tracks.count else {
      status = "Match each cloud file to a catalog song before adding it to a playlist"
      return
    }
    let ids = candidates.filter { seen.insert($0).inserted }
    guard !ids.isEmpty else { return }
    write(
      loadingStatus: edit == .add ? "Adding songs" : "Removing songs",
      operation: edit == .add ? "Add tracks" : "Remove tracks", session: session,
      syncPlaylistID: target.id
    ) { credential in
      try await self.transport.editPlaylistTracks(
        edit, playlistID: target.id, trackIDs: ids, credential: credential)
      return {
        if self.selectedPlaylist?.id == target.id { self.detail.markStaleAfterMutation() }
        return edit == .add ? "Songs added to \(target.name)" : "Songs removed from \(target.name)"
      }
    }
  }

  package func updateSelectedMetadata(_ edit: PlaylistMetadataEdit, session: any SessionProviding) {
    guard let playlist = selectedPlaylist, playlist.canEdit else { return }
    write(loadingStatus: "Saving playlist", operation: "Edit playlist", session: session) {
      credential in
      try await self.transport.updatePlaylistMetadata(
        playlistID: playlist.id, edit: edit, credential: credential)
      return {
        var updated = playlist
        switch edit {
        case .description(let value): updated.description = value
        case .tags(let value): updated.tags = value
        }
        self.collection.replace(updated)
        if self.selectedPlaylist?.id == updated.id { self.selectedPlaylist = updated }
        return "Playlist saved"
      }
    }
  }

  package func updateSelectedCover(from fileURL: URL, session: any SessionProviding) async {
    guard let playlist = selectedPlaylist, playlist.canEdit else { return }
    let started = write(
      loadingStatus: "Updating playlist cover", operation: "Update cover", session: session,
      effect: .upload, syncPlaylistID: playlist.id
    ) { credential in
      try await self.transport.updatePlaylistCover(
        playlistID: playlist.id, fileURL: fileURL, credential: credential)
      return { "Playlist cover updated" }
    }
    if started { await loadTask?.value }
  }

  package func movePlaylists(
    ids: [Int64], before destination: Int64?, session: any SessionProviding
  ) {
    guard collection.freshness == .current, !collection.serverHasMore else {
      status = "Load the complete playlist list before reordering it"
      return
    }
    let held = collection.playlists
    guard ids.allSatisfy({ id in held.contains { $0.id == id && !$0.isLikedSongs } }) else {
      return
    }
    let moving = Set(ids)
    if let destination, moving.contains(destination) { return }
    var reordered = held.filter { !moving.contains($0.id) }
    let index =
      destination.flatMap { id in reordered.firstIndex { $0.id == id } } ?? reordered.count
    reordered.insert(contentsOf: held.filter { moving.contains($0.id) }, at: index)
    let result = reordered
    write(loadingStatus: "Saving playlist order", operation: "Reorder playlists", session: session)
    { credential in
      try await self.transport.reorderPlaylists(ids: result.map(\.id), credential: credential)
      return {
        self.collection.apply(
          page: UserPlaylistPage(playlists: result, more: false), replacingAll: true)
        return "Playlist order saved"
      }
    }
  }

  package func moveTracks(ids: [Int64], before destination: Int64?, session: any SessionProviding) {
    guard let playlist = selectedPlaylist, playlist.canEdit, detail.freshness == .current,
      !ids.isEmpty, Set(ids).isSubset(of: Set(detail.trackIDs))
    else { return }
    let moving = Set(ids)
    if let destination, moving.contains(destination) { return }
    var reordered = detail.trackIDs.filter { !moving.contains($0) }
    let index = destination.flatMap { reordered.firstIndex(of: $0) } ?? reordered.count
    reordered.insert(contentsOf: detail.trackIDs.filter { moving.contains($0) }, at: index)
    let result = reordered
    write(
      loadingStatus: "Saving song order", operation: "Reorder tracks", session: session,
      syncPlaylistID: playlist.id
    ) { credential in
      try await self.transport.reorderPlaylistTracks(
        playlistID: playlist.id, ids: result, credential: credential)
      return {
        self.detail.markStaleAfterMutation()
        return "Song order saved"
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
    guard collection.playlists.first(where: { $0.id == playlistID })?.owned != true else {
      status = "This playlist is already in your own library"
      return
    }
    write(
      loadingStatus: subscribed
        ? "Subscribing to the playlist (1 request)"
        : "Unsubscribing from the playlist (1 request)",
      operation: subscribed ? "Subscribe" : "Unsubscribe",
      session: session,
      syncCollection: true
    ) { credential in
      try await self.transport.setPlaylistSubscribed(
        subscribed,
        playlistID: playlistID,
        credential: credential
      )
      return {
        if self.selectedPlaylist?.id == playlistID {
          self.selectedPlaylist?.isSubscribed = subscribed
        }
        if !subscribed {
          self.collection.remove(id: playlistID)
          if self.selectedPlaylist?.id == playlistID {
            self.clearDetail()
          }
        }
        // Either direction changes which playlists the account has.
        self.collection.markStaleAfterMutation()
        return (subscribed ? "Subscribed to " : "Unsubscribed from ") + playlistName
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
    effect: OperationEffect = .write,
    noAccountStatus: String = "Validate the session before changing playlists",
    recordsCreateReceipt: Bool = false,
    syncCollection: Bool = false,
    syncPlaylistID: Int64? = nil,
    body: @escaping @MainActor (NeteaseCredential) async throws -> @MainActor () -> String
  ) -> Bool {
    guard
      let claim = claim(
        operation,
        effect: effect,
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
        let resolved = releaseSessionOperation(
          claim.token,
          currentToken: &self.operationToken,
          arbiter: self.arbiter,
          outcome: outcome
        )
        if recordsCreateReceipt, let resolved {
          self.lastCreateReceipt = CreateReceipt(outcome: resolved)
        }
        finishSessionOperation(
          generation: currentGeneration,
          currentGeneration: self.generation,
          isLoading: &self.isLoading,
          task: &self.loadTask
        )
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
        let previousPlaylists = self.collection.playlists
        self.status = apply()
        outcome = .applied
        do {
          if let syncPlaylistID {
            let metadata = try await self.transport.playlistDetail(
              playlistID: syncPlaylistID, credential: credential
            )
            guard
              try await self.sessionRemainsCurrent(
                account: account, credential: credential, generation: currentGeneration,
                session: session
              )
            else { return }
            var updated =
              metadata.metadata
              ?? self.collection.playlists.first(where: { $0.id == syncPlaylistID })
            if updated == nil, self.selectedPlaylist?.id == syncPlaylistID {
              updated = self.selectedPlaylist
            }
            if var updated {
              updated.name = metadata.name
              updated.trackCount = metadata.trackIDs.count
              updated.owned = metadata.creatorID.map { $0 == account.userID } ?? updated.owned
              self.collection.replace(updated)
              if self.selectedPlaylist?.id == syncPlaylistID {
                self.selectedPlaylist = updated
                self.detail.begin(metadata)
                let ids = self.detail.nextBatch(limit: NeteaseSession.songDetailRequestLimit)
                let tracks =
                  ids.isEmpty
                  ? [] : try await self.transport.songDetails(songIDs: ids, credential: credential)
                guard
                  try await self.sessionRemainsCurrent(
                    account: account, credential: credential, generation: currentGeneration,
                    session: session
                  )
                else { return }
                self.detail.appendBatch(tracks, requestedCount: ids.count)
              }
            }
          }
          if syncCollection {
            let page = try await self.transport.userPlaylists(
              userID: account.userID, limit: Self.playlistPageSize, offset: 0,
              credential: credential
            )
            guard
              try await self.sessionRemainsCurrent(
                account: account, credential: credential, generation: currentGeneration,
                session: session
              )
            else { return }
            self.collection.apply(page: page, replacingAll: true)
          }
        } catch {
          guard self.generation == currentGeneration else { return }
          self.status += "; saved, but the updated list could not be loaded"
        }
        if self.collection.playlists != previousPlaylists {
          await self.persistPlaylists(for: account)
        }
      } catch is CancellationError {
        outcome = .cancelled
      } catch {
        if error.provesWriteDidNotRun {
          outcome = .failed
        } else if Task.isCancelled {
          outcome = .cancelled
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

  /// module's work, and it never cancels a write whose request is already in
  /// flight: that request is left to finish so the arbiter can classify what
  /// the server did, instead of the client guessing.
  package func reset() {
    generation += 1
    if !arbiter.activeWriteIsInFlight {
      loadTask?.cancel()
      loadTask = nil
      if let operationToken {
        self.operationToken = nil
        arbiter.end(operationToken, outcome: .cancelled)
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

  private func claimRead(
    _ name: String, account: NeteaseAccount, generation: Int, session: any SessionProviding
  ) async -> SessionOperationClaim? {
    guard let token = await arbiter.beginWhenAvailable(name: name, effect: .read) else {
      if self.generation == generation {
        isLoading = false
        loadTask = nil
        status = "Loading timed out; try again"
      }
      return nil
    }
    guard self.generation == generation, session.account?.userID == account.userID,
      !Task.isCancelled
    else {
      arbiter.end(token, outcome: .cancelled)
      return nil
    }
    operationToken = token
    return SessionOperationClaim(token: token, account: account)
  }

  /// Claims the arbiter and the validated account together, so no entry point
  /// can start a request without holding both.
  private func claim(
    _ name: String,
    effect: OperationEffect,
    session: any SessionProviding,
    noAccountStatus: String
  ) -> SessionOperationClaim? {
    claimSessionOperation(
      name,
      effect: effect,
      session: session,
      arbiter: arbiter,
      isLoading: isLoading,
      noAccountStatus: noAccountStatus,
      status: &status,
      operationToken: &operationToken
    )
  }

  /// Runs the body under the claimed operation. The body returns whether its
  /// result was published; a write that was sent but not published leaves the
  /// server outcome unknown, which the arbiter records.
  private func perform(
    claim: SessionOperationClaim,
    generation: Int,
    session: any SessionProviding,
    invalidateOnService301: Bool,
    operation: String,
    body: @MainActor (NeteaseCredential) async throws -> Bool
  ) async {
    var outcome = OperationOutcome.failed
    defer {
      releaseSessionOperation(
        claim.token,
        currentToken: &self.operationToken,
        arbiter: self.arbiter,
        outcome: outcome
      )
      finishSessionOperation(
        generation: generation,
        currentGeneration: self.generation,
        isLoading: &self.isLoading,
        task: &self.loadTask
      )
    }

    var credential: NeteaseCredential?
    do {
      credential = try await currentCredential(
        account: claim.account,
        generation: generation,
        session: session
      )
      guard let credential else { return }
      let published = try await body(credential)
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

  private func persistPlaylists(for account: NeteaseAccount) async {
    let snapshot = collection.playlists
    await onPersistablePlaylistsChanged?(account.userID, snapshot)
  }
}
