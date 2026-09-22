import Foundation
import NeteaseKit
import Observation

/// A membership value the server has actually proved. Unknown is deliberately
/// distinct from confirmed absence, so a button never toggles a guess.
package enum ConfirmedMembershipState: Equatable, Sendable {
  case unknown
  case confirmed(Bool)
}

private struct ConfirmedMembership {
  private var completeIDs: Set<Int64>?
  private var individuallyKnown: [Int64: Bool] = [:]

  func state(of id: Int64) -> ConfirmedMembershipState {
    if let completeIDs {
      return .confirmed(completeIDs.contains(id))
    }
    return individuallyKnown[id].map(ConfirmedMembershipState.confirmed)
      ?? .unknown
  }

  mutating func confirm(_ included: Bool, id: Int64) {
    if completeIDs != nil {
      if included {
        completeIDs?.insert(id)
      } else {
        completeIDs?.remove(id)
      }
    } else {
      individuallyKnown[id] = included
    }
  }

  /// A successful reset page with more rows invalidates only the old implicit
  /// negatives. Rows the old complete list actually contained remain known.
  mutating func beginPartialReplacement() {
    guard let completeIDs else { return }
    individuallyKnown = Dictionary(
      uniqueKeysWithValues: completeIDs.map { ($0, true) }
    )
    self.completeIDs = nil
  }

  mutating func loadComplete(_ ids: [Int64]) {
    completeIDs = Set(ids)
    individuallyKnown = [:]
  }
}

/// The account's own collections: albums it has saved, artists it follows and
/// the cloud drive.
///
/// Navigation loads each section once per account; refresh and paging reuse
/// that section's state independently of other sections. Cloud capacity
/// arrives with its first page and needs no separate request.
@MainActor
@Observable
package final class CollectionsCoordinator: SessionGuardedCoordinator {
  package enum Section: String, Hashable { case albums, artists, cloud }
  @ObservationIgnored private var reads: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var readTokens: [String: OperationToken] = [:]
  @ObservationIgnored private var readIDs: [String: UUID] = [:]
  @ObservationIgnored private var readSections: [String: Section] = [:]
  package private(set) var loadingReads: Set<String> = []
  package private(set) var loadedSections: Set<Section> = []
  package func isLoading(_ section: Section) -> Bool {
    loadingReads.contains { readSections[$0] == section }
  }

  private static let pageSize = 25
  private static let cloudPageSize = 30

  @ObservationIgnored private let transport: any NeteaseTransporting
  @ObservationIgnored package let vault: any CredentialStoring
  @ObservationIgnored private let arbiter: OperationArbiter
  @ObservationIgnored package private(set) var generation = 0
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var operationToken: OperationToken?
  private var albumMembership = ConfirmedMembership()
  private var artistMembership = ConfirmedMembership()
  private var albumOffset = 0
  private var artistOffset = 0
  private var cloudOffset = 0
  private var albumsNeedReload = false
  private var artistsNeedReload = false

  package var noStoredSessionStatus: String { "No stored session to load collections" }

  package private(set) var albums: [Album] = []
  package private(set) var artists: [Artist] = []
  package private(set) var cloudSongs: [CloudSong] = []
  package private(set) var cloudCapacity: CloudCapacity?
  package private(set) var selectedCloudSong: CloudSong?
  package private(set) var uploadProgress: CloudUploadProgress?
  @ObservationIgnored private var uploadID: UUID?
  package private(set) var albumsHaveMore = false
  package private(set) var artistsHaveMore = false
  package private(set) var cloudHasMore = false
  package private(set) var writingSection: Section?
  package private(set) var isWriting = false
  package var isLoading: Bool { isWriting || !loadingReads.isEmpty }
  package var status = "Validate the session, then load each collection"

  package func albumCollectionState(for albumID: Int64) -> ConfirmedMembershipState {
    albumMembership.state(of: albumID)
  }

  package func artistFollowState(for artistID: Int64) -> ConfirmedMembershipState {
    artistMembership.state(of: artistID)
  }

  /// Album detail is another authoritative source for this one id. It feeds
  /// the same state the collection list and writes use; Catalog keeps no copy.
  package func confirmAlbumCollected(_ collected: Bool, albumID: Int64) {
    albumMembership.confirm(collected, id: albumID)
  }

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
    clearAll()
  }

  // MARK: - Reads

  package func loadAlbums(reset: Bool, session: any SessionProviding) {
    let reset = reset || albumsNeedReload
    guard reset || albumsHaveMore else { return }
    let offset = reset ? 0 : albumOffset
    read(
      loadingStatus: "Loading collected albums (1 request)",
      operation: "Collected albums", section: .albums,
      session: session
    ) { credential, _ in
      let page = try await self.transport.collectedAlbums(
        limit: Self.pageSize,
        offset: offset,
        credential: credential
      )
      return {
        var seen = Set(reset ? [] : self.albums.map(\.id))
        self.albums = (reset ? [] : self.albums) + page.items.filter { seen.insert($0.id).inserted }
        self.albumOffset = offset + page.items.count
        self.albumsNeedReload = false
        self.albumsHaveMore = page.more && !page.items.isEmpty
        if reset && page.more { self.albumMembership.beginPartialReplacement() }
        if page.more {
          for album in page.items {
            self.albumMembership.confirm(true, id: album.id)
          }
        } else {
          self.albumMembership.loadComplete(self.albums.map(\.id))
        }
        return "Loaded \(self.albums.count) collected albums"
      }
    }
  }

  package func loadArtists(reset: Bool, session: any SessionProviding) {
    let reset = reset || artistsNeedReload
    guard reset || artistsHaveMore else { return }
    let offset = reset ? 0 : artistOffset
    read(
      loadingStatus: "Loading followed artists (1 request)",
      operation: "Followed artists", section: .artists,
      session: session
    ) { credential, _ in
      let page = try await self.transport.followedArtists(
        limit: Self.pageSize,
        offset: offset,
        credential: credential
      )
      return {
        var seen = Set(reset ? [] : self.artists.map(\.id))
        self.artists =
          (reset ? [] : self.artists) + page.items.filter { seen.insert($0.id).inserted }
        self.artistOffset = offset + page.items.count
        self.artistsNeedReload = false
        self.artistsHaveMore = page.more && !page.items.isEmpty
        if reset && page.more { self.artistMembership.beginPartialReplacement() }
        if page.more {
          for artist in page.items {
            self.artistMembership.confirm(true, id: artist.id)
          }
        } else {
          self.artistMembership.loadComplete(self.artists.map(\.id))
        }
        return "Loaded \(self.artists.count) followed artists"
      }
    }
  }

  package func loadCloud(reset: Bool, session: any SessionProviding) {
    guard reset || cloudHasMore else { return }
    let offset = reset ? 0 : cloudOffset
    read(
      loadingStatus: "Loading the cloud drive (1 request)",
      operation: "Cloud drive", section: .cloud,
      session: session
    ) { credential, _ in
      let page = try await self.transport.cloudSongs(
        limit: Self.cloudPageSize,
        offset: offset,
        credential: credential
      )
      return {
        var seen = Set(reset ? [] : self.cloudSongs.map(\.id))
        self.cloudSongs =
          (reset ? [] : self.cloudSongs) + page.songs.filter { seen.insert($0.id).inserted }
        self.cloudOffset = offset + page.songs.count
        self.cloudHasMore = page.more && !page.songs.isEmpty
        self.cloudCapacity = page.capacity
        return "Loaded \(self.cloudSongs.count) cloud songs"
      }
    }
  }

  package func openCloudSong(_ song: CloudSong, session: any SessionProviding) {
    read(
      loadingStatus: "Loading cloud file", operation: "Cloud file", section: .cloud,
      session: session
    ) {
      credential, _ in
      let detail = try await self.transport.cloudSongDetail(songID: song.id, credential: credential)
      return {
        self.selectedCloudSong = detail
        return "Cloud file loaded"
      }
    }
  }

  package func matchCloudSong(_ song: CloudSong, to songID: Int64, session: any SessionProviding) {
    guard songID >= 0, let account = session.account,
      cloudSongs.contains(where: { $0.id == song.id }) || selectedCloudSong?.id == song.id
    else { return }
    write(
      loadingStatus: "Updating song match", operation: "Match cloud song", session: session,
      syncCloud: true
    ) { credential in
      try await self.transport.matchCloudSong(
        songID: song.id, matchedSongID: songID, userID: account.userID, credential: credential)
      return { return "Song match updated" }
    }
  }

  package func uploadCloudFile(
    at url: URL, importOnly: Bool, matchedSongID: Int64? = nil, session: any SessionProviding
  ) async {
    let id = UUID()
    let started = write(
      loadingStatus: "Preparing cloud file",
      operation: importOnly ? "Import cloud file" : "Upload cloud file", session: session,
      effect: .upload, syncCloud: true
    ) { credential in
      self.uploadID = id
      self.uploadProgress = .preparing
      if importOnly {
        try await self.transport.importCloudFile(
          at: url, matchedSongID: matchedSongID, credential: credential)
      } else {
        _ = try await self.transport.uploadCloudFile(at: url, credential: credential) {
          [weak self] progress in
          await MainActor.run {
            guard let self, self.uploadID == id, self.isLoading else { return }
            if self.uploadProgress == .publishing { return }
            self.uploadProgress = progress
          }
        }
      }
      return { "Cloud file saved" }
    }
    if started { await loadTask?.value }
    if uploadID == id {
      uploadID = nil
      uploadProgress = nil
    }
  }

  package func cancelCloudUpload() {
    guard uploadProgress != nil else { return }
    loadTask?.cancel()
    status =
      "Cloud upload cancelled; check the cloud drive before retrying if publication had started"
  }

  // MARK: - Writes

  package func setAlbumCollected(
    _ collected: Bool,
    album: Album,
    session: any SessionProviding
  ) {
    write(
      loadingStatus: collected
        ? "Collecting the album (1 request)"
        : "Removing the album (1 request)",
      operation: collected ? "Collect album" : "Remove album", section: .albums,
      session: session
    ) { credential in
      try await self.transport.setAlbumCollected(
        collected,
        albumID: album.id,
        credential: credential
      )
      return {
        // The write proves this album's state and nothing else, so only this
        // row changes; the list is not refetched.
        if collected {
          if !self.albums.contains(where: { $0.id == album.id }) {
            self.albums.insert(album, at: 0)
          }
        } else {
          self.albums.removeAll { $0.id == album.id }
        }
        self.albumMembership.confirm(collected, id: album.id)
        self.albumsNeedReload = true
        return
          (collected ? "Collected " : "Removed ") + album.name
          + "; reload to see the server's order"
      }
    }
  }

  package func setArtistFollowed(
    _ followed: Bool,
    artist: Artist,
    session: any SessionProviding
  ) {
    write(
      loadingStatus: followed
        ? "Following the artist (1 request)"
        : "Unfollowing the artist (1 request)",
      operation: followed ? "Follow artist" : "Unfollow artist", section: .artists,
      session: session
    ) { credential in
      try await self.transport.setArtistFollowed(
        followed,
        artistID: artist.id,
        credential: credential
      )
      return {
        if followed {
          if !self.artists.contains(where: { $0.id == artist.id }) {
            self.artists.insert(artist, at: 0)
          }
        } else {
          self.artists.removeAll { $0.id == artist.id }
        }
        self.artistMembership.confirm(followed, id: artist.id)
        self.artistsNeedReload = true
        return
          (followed ? "Followed " : "Unfollowed ") + artist.name
          + "; reload to see the server's order"
      }
    }
  }

  /// Deletes one upload from the cloud drive (1 request).
  ///
  /// The freed space is applied locally from the file's own size, which the
  /// listing already reported, rather than by refetching the page. A follow-up
  /// request would be a second request the button did not promise.
  package func deleteCloudSong(
    _ song: CloudSong,
    session: any SessionProviding
  ) {
    write(
      loadingStatus: "Deleting from the cloud drive (1 request)",
      operation: "Delete cloud song",
      session: session,
      syncCloud: true
    ) { credential in
      try await self.transport.deleteCloudSong(
        songID: song.id,
        credential: credential
      )
      return {
        guard self.cloudSongs.contains(where: { $0.id == song.id }) else {
          return "Deleted \(song.track.name) from the cloud drive"
        }
        self.cloudSongs.removeAll { $0.id == song.id }
        if self.selectedCloudSong?.id == song.id { self.selectedCloudSong = nil }
        self.cloudCapacity = self.cloudCapacity.map {
          CloudCapacity(
            usedBytes: max(0, $0.usedBytes - song.fileSize),
            totalBytes: $0.totalBytes
          )
        }
        return "Deleted \(song.track.name) from the cloud drive"
      }
    }
  }

  package func settleForTesting() async {
    await loadTask?.value
    for task in reads.values { await task.value }
  }

  package func reset() {
    generation += 1
    for section in [Section.albums, .artists, .cloud] { cancelReads(section) }
    if case .transferring(_)? = uploadProgress { loadTask?.cancel() }
    if !arbiter.activeWriteIsInFlight {
      loadTask?.cancel()
      loadTask = nil
      if let operationToken {
        self.operationToken = nil
        arbiter.end(operationToken, outcome: .cancelled)
      }
    }
    clearAll()
    writingSection = nil
    isWriting = false
    status = "Validate the session, then load each collection"
  }

  // MARK: - Shared execution

  private func claim(
    _ name: String,
    effect: OperationEffect,
    session: any SessionProviding
  ) -> SessionOperationClaim? {
    claimSessionOperation(
      name,
      effect: effect,
      session: session,
      arbiter: arbiter,
      isLoading: isWriting,
      noAccountStatus: "Validate the session before loading collections",
      status: &status,
      operationToken: &operationToken
    )
  }

  package func loadIfNeeded(_ section: Section, session: any SessionProviding) {
    guard !loadedSections.contains(section), !isLoading(section) else { return }
    switch section {
    case .albums: loadAlbums(reset: true, session: session)
    case .artists: loadArtists(reset: true, session: session)
    case .cloud: loadCloud(reset: true, session: session)
    }
  }

  private func cancelReads(_ section: Section) {
    for operation in Array(readSections.keys) where readSections[operation] == section {
      reads.removeValue(forKey: operation)?.cancel()
      if let token = readTokens.removeValue(forKey: operation) {
        arbiter.end(token, outcome: .cancelled)
      }
      readIDs[operation] = nil
      readSections[operation] = nil
      loadingReads.remove(operation)
    }
  }

  private func read(
    loadingStatus: String,
    operation: String,
    section: Section,
    session: any SessionProviding,
    body: @escaping @MainActor (NeteaseCredential, NeteaseAccount) async throws -> @MainActor () ->
      String
  ) {
    guard reads[operation] == nil, writingSection != section else { return }
    guard session.isOnline, let account = session.account else {
      status = "Connect to load your collections"
      return
    }
    let currentGeneration = generation
    let id = UUID()
    readIDs[operation] = id
    readSections[operation] = section
    loadingReads.insert(operation)
    status = loadingStatus
    reads[operation] = Task {
      let token = await arbiter.beginWhenAvailable(name: operation, effect: .read)
      var outcome = OperationOutcome.failed
      defer {
        if let token { arbiter.end(token, outcome: outcome) }
        if self.readIDs[operation] == id {
          self.reads[operation] = nil
          self.readTokens[operation] = nil
          self.readIDs[operation] = nil
          self.readSections[operation] = nil
          self.loadingReads.remove(operation)
        }
      }
      guard let token, self.generation == currentGeneration, !Task.isCancelled else { return }
      self.readTokens[operation] = token
      do {
        guard
          let credential = try await currentCredential(
            account: account, generation: currentGeneration, session: session)
        else { return }
        try Task.checkCancellation()
        let apply = try await body(credential, account)
        guard !Task.isCancelled, self.readIDs[operation] == id,
          try await sessionRemainsCurrent(
            account: account, credential: credential,
            generation: currentGeneration, session: session),
          !Task.isCancelled
        else {
          outcome = .cancelled
          return
        }
        status = apply()
        if operation != "Cloud file" { loadedSections.insert(section) }
        outcome = .applied
      } catch {
        outcome = Task.isCancelled ? .cancelled : .failed
        report(error, operation: operation, generation: currentGeneration)
      }
    }
  }

  @discardableResult
  private func write(
    loadingStatus: String,
    operation: String,
    section: Section = .cloud,
    session: any SessionProviding,
    effect: OperationEffect = .write,
    syncCloud: Bool = false,
    body: @escaping @MainActor (NeteaseCredential) async throws -> @MainActor () -> String
  ) -> Bool {
    guard let claim = claim(operation, effect: effect, session: session) else {
      return false
    }
    cancelReads(section)
    let currentGeneration = generation
    let account = claim.account
    writingSection = section
    isWriting = true
    status = loadingStatus
    loadTask = Task {
      var outcome = OperationOutcome.failed
      defer {
        releaseSessionOperation(
          claim.token,
          currentToken: &self.operationToken,
          arbiter: self.arbiter,
          outcome: outcome
        )
        finishSessionOperation(
          generation: currentGeneration,
          currentGeneration: self.generation,
          isLoading: &self.isWriting,
          task: &self.loadTask
        )
        if self.generation == currentGeneration { self.writingSection = nil }
      }
      do {
        guard
          let credential = try await currentCredential(
            account: account,
            generation: currentGeneration,
            session: session
          )
        else { return }
        arbiter.markRequestSent(claim.token)
        let apply = try await body(credential)
        arbiter.markSettling(claim.token)
        // The response is in hand, so the server's answer is known even if the
        // local apply never runs.
        outcome = .appliedRemotelyOnly
        guard
          try await sessionRemainsCurrent(
            account: account,
            credential: credential,
            generation: currentGeneration,
            session: session
          )
        else { return }
        status = apply()
        outcome = .applied
        if syncCloud {
          do {
            let page = try await self.transport.cloudSongs(
              limit: Self.cloudPageSize, offset: 0, credential: credential)
            guard
              try await self.sessionRemainsCurrent(
                account: account, credential: credential, generation: currentGeneration,
                session: session)
            else { return }
            self.cloudSongs = page.songs
            self.cloudOffset = page.songs.count
            self.cloudHasMore = page.more
            self.cloudCapacity = page.capacity
            if let selected = self.selectedCloudSong {
              let detail = try await self.transport.cloudSongDetail(
                songID: selected.id, credential: credential)
              guard
                try await self.sessionRemainsCurrent(
                  account: account, credential: credential, generation: currentGeneration,
                  session: session)
              else { return }
              self.selectedCloudSong = detail
            }
          } catch {
            if self.generation == currentGeneration {
              self.status += "; saved, but the cloud drive could not be refreshed"
            }
          }
        }
      } catch is CancellationError {
        outcome = .cancelled
      } catch {
        if error.provesWriteDidNotRun {
          outcome = .failed
        } else if Task.isCancelled {
          outcome = .cancelled
        } else if arbiter.abandoningLosesTheOutcome(claim.token) {
          // Sent, and nothing came back that says what the server did with it.
          outcome = .outcomeUnknown
        }
        report(error, operation: operation, generation: currentGeneration)
      }
    }
    return true
  }

  private func report(_ error: any Error, operation: String, generation: Int) {
    guard self.generation == generation else { return }
    let failure = OperationFailure.classify(error, cancelled: Task.isCancelled)
    guard failure.isReportable else { return }
    status = failure.statusText(operation: operation)
  }

  private func clearAll() {
    loadedSections.removeAll()
    albums = []
    artists = []
    cloudSongs = []
    cloudCapacity = nil
    selectedCloudSong = nil
    uploadProgress = nil
    uploadID = nil
    albumsHaveMore = false
    artistsHaveMore = false
    cloudHasMore = false
    albumOffset = 0
    artistOffset = 0
    cloudOffset = 0
    albumsNeedReload = false
    artistsNeedReload = false
    albumMembership = ConfirmedMembership()
    artistMembership = ConfirmedMembership()
  }
}
