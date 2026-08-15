import Foundation
import MacEaseSession
import NeteaseKit
import Observation

/// Discovery and listening-ranking reads. Every section loads only from an
/// explicit one-request user action; none of these endpoints has verified
/// credential-invalidation semantics, so service 301 classifies and stops.
@MainActor
@Observable
final class DiscoveryCoordinator {
  @ObservationIgnored private let session: NeteaseSession
  @ObservationIgnored private let vault = CredentialVault()
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var loadTask: Task<Void, Never>?

  var dailySongs: [PlaylistTrack] = []
  var dailyPlaylists: [DiscoveredPlaylist] = []
  var personalized: [DiscoveredPlaylist] = []
  var toplists: [DiscoveredPlaylist] = []
  var records: [PlayRecordEntry] = []
  var recordScope: PlayRecordScope = .allTime
  var isLoading = false
  var status = "Validate the session, then load each section explicitly"

  init(session: NeteaseSession) {
    self.session = session
  }

  func loadDailySongs(loginCoordinator: LoginCoordinator) {
    load(
      loadingStatus: "Loading daily recommended songs (1 request)",
      operation: "Daily songs",
      loginCoordinator: loginCoordinator,
      fetch: { credential, _ in
        try await self.session.dailyRecommendedSongs(credential: credential)
      },
      apply: { songs in
        self.dailySongs = songs
        return "Loaded \(songs.count) daily recommended songs"
      }
    )
  }

  func loadDailyPlaylists(loginCoordinator: LoginCoordinator) {
    load(
      loadingStatus: "Loading daily recommended playlists (1 request)",
      operation: "Daily playlists",
      loginCoordinator: loginCoordinator,
      fetch: { credential, _ in
        try await self.session.dailyRecommendedPlaylists(credential: credential)
      },
      apply: { playlists in
        self.dailyPlaylists = playlists
        return "Loaded \(playlists.count) daily recommended playlists"
      }
    )
  }

  func loadPersonalized(loginCoordinator: LoginCoordinator) {
    load(
      loadingStatus: "Loading recommended playlists (1 request)",
      operation: "Recommended playlists",
      loginCoordinator: loginCoordinator,
      fetch: { credential, _ in
        try await self.session.personalizedPlaylists(credential: credential)
      },
      apply: { playlists in
        self.personalized = playlists
        return "Loaded \(playlists.count) recommended playlists"
      }
    )
  }

  func loadToplists(loginCoordinator: LoginCoordinator) {
    load(
      loadingStatus: "Loading toplists (1 request)",
      operation: "Toplists",
      loginCoordinator: loginCoordinator,
      fetch: { credential, _ in
        try await self.session.toplists(credential: credential)
      },
      apply: { toplists in
        self.toplists = toplists
        return "Loaded \(toplists.count) toplists"
      }
    )
  }

  func loadRecords(loginCoordinator: LoginCoordinator) {
    let scope = recordScope
    load(
      loadingStatus: "Loading listening rankings (1 request)",
      operation: "Listening rankings",
      loginCoordinator: loginCoordinator,
      fetch: { credential, account in
        try await self.session.playRecords(
          userID: account.userID,
          scope: scope,
          credential: credential
        )
      },
      apply: { records in
        self.records = records
        return "Loaded \(records.count) ranking entries"
      }
    )
  }

  func reset() {
    generation += 1
    loadTask?.cancel()
    loadTask = nil
    clearAll()
    isLoading = false
    status = "Validate the session, then load each section explicitly"
  }

  private func load<Value: Sendable>(
    loadingStatus: String,
    operation: String,
    loginCoordinator: LoginCoordinator,
    fetch: @escaping @MainActor (NeteaseCredential, NeteaseAccount) async throws -> Value,
    apply: @escaping @MainActor (Value) -> String
  ) {
    guard !loginCoordinator.isBusy, !isLoading else { return }
    guard let account = loginCoordinator.account else {
      status = "Validate the session before loading"
      return
    }

    let currentGeneration = generation
    isLoading = true
    status = loadingStatus
    loadTask = Task {
      defer { finish(generation: currentGeneration) }

      var credential: NeteaseCredential?
      do {
        credential = try await currentCredential(
          account: account,
          generation: currentGeneration,
          loginCoordinator: loginCoordinator
        )
        guard let credential else { return }
        let value = try await fetch(credential, account)
        guard
          try await sessionRemainsCurrent(
            account: account,
            credential: credential,
            generation: currentGeneration,
            loginCoordinator: loginCoordinator
          )
        else { return }
        status = apply(value)
      } catch {
        handle(error, generation: currentGeneration, operation: operation)
      }
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
      clearAll()
      status = "No stored session to load Discover"
      return nil
    }
    guard self.generation == generation else { return nil }
    guard loginCoordinator.matchesValidatedSession(credential, account: account) else {
      loginCoordinator.hasStoredSession = true
      loginCoordinator.account = nil
      loginCoordinator.status = "Stored session changed; validate again"
      clearAll()
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
      clearAll()
      status = "Session changed; validate again"
      return false
    }
    return true
  }

  private func handle(_ error: Error, generation: Int, operation: String) {
    guard self.generation == generation else { return }

    if let serviceError = error as? NeteaseServiceError {
      status = "\(operation) \(serviceError.source.rawValue) error \(serviceError.statusCode)"
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

  private func clearAll() {
    dailySongs = []
    dailyPlaylists = []
    personalized = []
    toplists = []
    records = []
  }
}
