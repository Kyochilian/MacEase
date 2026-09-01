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
/// Each section loads and pages from an explicit action, exactly like the
/// playlist library, and nothing here refreshes itself. The cloud drive's
/// capacity arrives with its first page, so showing how full the drive is
/// costs no extra request.
@MainActor
@Observable
package final class CollectionsCoordinator: SessionGuardedCoordinator {
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

  package var noStoredSessionStatus: String { "No stored session to load collections" }

  package private(set) var albums: [Album] = []
  package private(set) var artists: [Artist] = []
  package private(set) var cloudSongs: [CloudSong] = []
  package private(set) var cloudCapacity: CloudCapacity?
  package private(set) var albumsHaveMore = false
  package private(set) var artistsHaveMore = false
  package private(set) var cloudHasMore = false
  package var isLoading = false
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
    guard reset || albumsHaveMore else { return }
    let offset = reset ? 0 : albums.count
    read(
      loadingStatus: "Loading collected albums (1 request)",
      operation: "Collected albums",
      session: session
    ) { credential, _ in
      let page = try await self.transport.collectedAlbums(
        limit: Self.pageSize,
        offset: offset,
        credential: credential
      )
      return {
        self.albums = reset ? page.items : self.albums + page.items
        self.albumsHaveMore = page.more
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
    guard reset || artistsHaveMore else { return }
    let offset = reset ? 0 : artists.count
    read(
      loadingStatus: "Loading followed artists (1 request)",
      operation: "Followed artists",
      session: session
    ) { credential, _ in
      let page = try await self.transport.followedArtists(
        limit: Self.pageSize,
        offset: offset,
        credential: credential
      )
      return {
        self.artists = reset ? page.items : self.artists + page.items
        self.artistsHaveMore = page.more
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
    let offset = reset ? 0 : cloudSongs.count
    read(
      loadingStatus: "Loading the cloud drive (1 request)",
      operation: "Cloud drive",
      session: session
    ) { credential, _ in
      let page = try await self.transport.cloudSongs(
        limit: Self.cloudPageSize,
        offset: offset,
        credential: credential
      )
      return {
        self.cloudSongs = reset ? page.songs : self.cloudSongs + page.songs
        self.cloudHasMore = page.more
        self.cloudCapacity = page.capacity
        return "Loaded \(self.cloudSongs.count) cloud songs"
      }
    }
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
      operation: collected ? "Collect album" : "Remove album",
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
      operation: followed ? "Follow artist" : "Unfollow artist",
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
      session: session
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
  }

  package func reset() {
    generation += 1
    if !arbiter.activeWriteIsInFlight {
      loadTask?.cancel()
      loadTask = nil
      if let operationToken {
        release(operationToken, outcome: .cancelled)
      }
    }
    clearAll()
    isLoading = false
    status = "Validate the session, then load each collection"
  }

  // MARK: - Shared execution

  private struct Claim {
    let token: OperationToken
    let account: NeteaseAccount
  }

  private func claim(
    _ name: String,
    effect: OperationEffect,
    session: any SessionProviding
  ) -> Claim? {
    guard !isLoading else { return nil }
    guard let token = arbiter.begin(name: name, effect: effect) else { return nil }
    guard let account = session.account else {
      arbiter.end(token, outcome: .failed)
      status = "Validate the session before loading collections"
      return nil
    }
    operationToken = token
    return Claim(token: token, account: account)
  }

  private func read(
    loadingStatus: String,
    operation: String,
    session: any SessionProviding,
    body: @escaping @MainActor (NeteaseCredential, NeteaseAccount) async throws ->
      @MainActor () -> String
  ) {
    guard let claim = claim(operation, effect: .read, session: session) else {
      return
    }
    let currentGeneration = generation
    let account = claim.account
    isLoading = true
    status = loadingStatus
    loadTask = Task {
      var outcome = OperationOutcome.failed
      defer {
        release(claim.token, outcome: outcome)
        finish(generation: currentGeneration)
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
        let apply = try await body(credential, account)
        arbiter.markSettling(claim.token)
        guard
          try await sessionRemainsCurrent(
            account: account,
            credential: credential,
            generation: currentGeneration,
            session: session
          )
        else {
          // A read that could not be published changed nothing on the server.
          outcome = .cancelled
          return
        }
        status = apply()
        outcome = .applied
      } catch {
        outcome = Task.isCancelled ? .cancelled : .failed
        report(error, operation: operation, generation: currentGeneration)
      }
    }
  }

  private func write(
    loadingStatus: String,
    operation: String,
    session: any SessionProviding,
    body: @escaping @MainActor (NeteaseCredential) async throws -> @MainActor () -> String
  ) {
    guard let claim = claim(operation, effect: .write, session: session) else {
      return
    }
    let currentGeneration = generation
    let account = claim.account
    isLoading = true
    status = loadingStatus
    loadTask = Task {
      var outcome = OperationOutcome.failed
      defer {
        release(claim.token, outcome: outcome)
        finish(generation: currentGeneration)
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
          // Sent, and nothing came back that says what the server did with it.
          outcome = .outcomeUnknown
        }
        report(error, operation: operation, generation: currentGeneration)
      }
    }
  }

  /// A `service` error is the endpoint's own answer, so it proves the write did
  /// not run. An HTTP 5xx says the server broke while handling it, which says
  /// nothing about whether the mutation landed first.
  private static func provesTheWriteDidNotRun(_ error: NeteaseServiceError) -> Bool {
    guard error.source == .http else { return true }
    return !(500...599).contains(error.statusCode)
  }

  private func report(_ error: any Error, operation: String, generation: Int) {
    guard self.generation == generation else { return }
    let failure = OperationFailure.classify(error, cancelled: Task.isCancelled)
    guard failure.isReportable else { return }
    status = failure.statusText(operation: operation)
  }

  private func finish(generation: Int) {
    guard self.generation == generation else { return }
    isLoading = false
    loadTask = nil
  }

  private func release(_ token: OperationToken, outcome: OperationOutcome) {
    if operationToken == token { operationToken = nil }
    arbiter.end(token, outcome: outcome)
  }

  private func clearAll() {
    albums = []
    artists = []
    cloudSongs = []
    cloudCapacity = nil
    albumsHaveMore = false
    artistsHaveMore = false
    cloudHasMore = false
    albumMembership = ConfirmedMembership()
    artistMembership = ConfirmedMembership()
  }
}
