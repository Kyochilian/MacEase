import Foundation
import MacEaseSession
import NeteaseKit
import Observation

@MainActor
@Observable
final class PlaylistLibraryCoordinator {
  private static let playlistPageSize = 30

  @ObservationIgnored private let session = NeteaseSession()
  @ObservationIgnored private let vault = CredentialVault()
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var trackIDs: [Int64] = []
  @ObservationIgnored private var loadedTrackIDCount = 0

  var playlists: [UserPlaylist] = []
  var selectedPlaylist: UserPlaylist?
  var tracks: [PlaylistTrack] = []
  var hasMore = false
  var hasMoreTracks = false
  var isLoading = false
  var status = "Validate the session before loading playlists"

  func load(reset: Bool, loginCoordinator: LoginCoordinator) {
    guard !loginCoordinator.isBusy, !isLoading else { return }
    guard reset || hasMore else { return }
    guard let account = loginCoordinator.account else {
      status = "Validate the session before loading playlists"
      return
    }

    if reset { clearDetail() }
    let currentGeneration = generation
    let offset = reset ? 0 : playlists.count
    isLoading = true
    status = "Loading playlists (1 request)"
    loadTask = Task {
      await perform(
        account: account,
        generation: currentGeneration,
        loginCoordinator: loginCoordinator,
        invalidateOnService301: true,
        operation: "Playlist"
      ) { credential in
        let page = try await self.session.userPlaylists(
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
            loginCoordinator: loginCoordinator
          )
        else { return }

        if reset {
          self.playlists = page.playlists
        } else {
          self.playlists.append(contentsOf: page.playlists)
        }
        self.hasMore = page.more
        self.status = "Loaded \(self.playlists.count) playlists"
      }
    }
  }

  func loadTracks(
    for playlist: UserPlaylist,
    loginCoordinator: LoginCoordinator
  ) {
    guard !loginCoordinator.isBusy, !isLoading else { return }
    guard let account = loginCoordinator.account else {
      status = "Validate the session before loading tracks"
      return
    }

    generation += 1
    let currentGeneration = generation
    clearDetail()
    selectedPlaylist = playlist
    isLoading = true
    status = "Loading playlist metadata (request 1 of 2)"
    loadTask = Task {
      await perform(
        account: account,
        generation: currentGeneration,
        loginCoordinator: loginCoordinator,
        invalidateOnService301: false,
        operation: "Playlist/song detail"
      ) { credential in
        let detail = try await self.session.playlistDetail(
          playlistID: playlist.id,
          credential: credential
        )
        guard
          try await self.sessionRemainsCurrent(
            account: account,
            credential: credential,
            generation: currentGeneration,
            loginCoordinator: loginCoordinator
          )
        else { return }
        guard !detail.trackIDs.isEmpty else {
          self.status = "Loaded an empty playlist (1 request)"
          return
        }

        let batchIDs = Array(
          detail.trackIDs.prefix(NeteaseSession.songDetailRequestLimit)
        )
        self.status = "Loading song metadata (request 2 of 2)"
        let batch = try await self.session.songDetails(
          songIDs: batchIDs,
          credential: credential
        )
        guard
          try await self.sessionRemainsCurrent(
            account: account,
            credential: credential,
            generation: currentGeneration,
            loginCoordinator: loginCoordinator
          )
        else { return }

        self.trackIDs = detail.trackIDs
        self.loadedTrackIDCount = batchIDs.count
        self.tracks = batch
        self.hasMoreTracks = batchIDs.count < detail.trackIDs.count
        self.status =
          "Loaded \(batch.count) tracks from \(batchIDs.count) "
          + "of \(detail.trackIDs.count) IDs"
      }
    }
  }

  func loadMoreTracks(loginCoordinator: LoginCoordinator) {
    guard !loginCoordinator.isBusy, !isLoading, hasMoreTracks else { return }
    guard let account = loginCoordinator.account else {
      status = "Validate the session before loading tracks"
      return
    }

    let currentGeneration = generation
    isLoading = true
    status = "Loading the next track batch (1 request)"
    loadTask = Task {
      await perform(
        account: account,
        generation: currentGeneration,
        loginCoordinator: loginCoordinator,
        invalidateOnService301: false,
        operation: "Song detail"
      ) { credential in
        let end = min(
          self.loadedTrackIDCount + NeteaseSession.songDetailRequestLimit,
          self.trackIDs.count
        )
        let batchIDs = Array(self.trackIDs[self.loadedTrackIDCount..<end])
        let batch = try await self.session.songDetails(
          songIDs: batchIDs,
          credential: credential
        )
        guard
          try await self.sessionRemainsCurrent(
            account: account,
            credential: credential,
            generation: currentGeneration,
            loginCoordinator: loginCoordinator
          )
        else { return }

        self.tracks.append(contentsOf: batch)
        self.loadedTrackIDCount = end
        self.hasMoreTracks = end < self.trackIDs.count
        self.status =
          "Loaded \(self.tracks.count) tracks from \(end) "
          + "of \(self.trackIDs.count) IDs"
      }
    }
  }

  func reset() {
    generation += 1
    loadTask?.cancel()
    loadTask = nil
    clearLibrary()
    isLoading = false
    status = "Validate the session before loading playlists"
  }

  private func perform(
    account: NeteaseAccount,
    generation: Int,
    loginCoordinator: LoginCoordinator,
    invalidateOnService301: Bool,
    operation: String,
    body: @MainActor (NeteaseCredential) async throws -> Void
  ) async {
    defer { finish(generation: generation) }

    var credential: NeteaseCredential?
    do {
      credential = try await currentCredential(
        account: account,
        generation: generation,
        loginCoordinator: loginCoordinator
      )
      guard let credential else { return }
      try await body(credential)
    } catch {
      await handle(
        error,
        credential: credential,
        generation: generation,
        loginCoordinator: loginCoordinator,
        invalidateOnService301: invalidateOnService301,
        operation: operation
      )
    }
  }

  private func currentCredential(
    account: NeteaseAccount,
    generation: Int,
    loginCoordinator: LoginCoordinator
  ) async throws -> NeteaseCredential? {
    guard let credential = try await vault.load() else {
      guard self.generation == generation else { return nil }
      loginCoordinator.hasStoredSession = false
      loginCoordinator.account = nil
      loginCoordinator.status = "No stored session to validate"
      clearLibrary()
      status = "No stored session to load library"
      return nil
    }
    guard self.generation == generation else { return nil }
    guard loginCoordinator.matchesValidatedSession(credential, account: account) else {
      loginCoordinator.hasStoredSession = true
      loginCoordinator.account = nil
      loginCoordinator.status = "Stored session changed; validate again"
      clearLibrary()
      status = "Session changed; validate again"
      return nil
    }
    return credential
  }

  private func sessionRemainsCurrent(
    account: NeteaseAccount,
    credential: NeteaseCredential,
    generation: Int,
    loginCoordinator: LoginCoordinator
  ) async throws -> Bool {
    guard self.generation == generation else { return false }
    let storedCredential = try await vault.load()
    guard self.generation == generation else { return false }
    guard
      storedCredential == credential,
      loginCoordinator.matchesValidatedSession(credential, account: account)
    else {
      loginCoordinator.hasStoredSession = storedCredential != nil
      loginCoordinator.account = nil
      loginCoordinator.status = "Stored session changed; validate again"
      clearLibrary()
      status = "Session changed; validate again"
      return false
    }
    return true
  }

  private func handle(
    _ error: Error,
    credential: NeteaseCredential?,
    generation: Int,
    loginCoordinator: LoginCoordinator,
    invalidateOnService301: Bool,
    operation: String
  ) async {
    guard self.generation == generation else { return }

    if let serviceError = error as? NeteaseServiceError {
      if invalidateOnService301, serviceError.source == .service,
        serviceError.statusCode == 301,
        let credential
      {
        let invalidation = await loginCoordinator.invalidateStoredSession(
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
        case .failed:
          status = "Session invalidation failed"
        }
      } else {
        status = "\(operation) \(serviceError.source.rawValue) error \(serviceError.statusCode)"
      }
    } else if let vaultError = error as? CredentialVaultError {
      status = "Keychain error \(vaultError.status)"
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
