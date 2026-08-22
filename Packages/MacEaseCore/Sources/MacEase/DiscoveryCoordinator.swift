import Foundation
import MacEaseSession
import NeteaseKit
import Observation

/// Discovery and listening-ranking reads. Sections load from an explicit
/// one-request user action, plus one launch-scoped prefetch of the four
/// Discover sections after the first successful validation (roadmap
/// decision); refreshes stay user-triggered. None of these endpoints has
/// verified credential-invalidation semantics, so service 301 classifies
/// and stops.
@MainActor
@Observable
final class DiscoveryCoordinator: SessionGuardedCoordinator {
  @ObservationIgnored private let session: NeteaseSession
  @ObservationIgnored let vault = CredentialVault()
  @ObservationIgnored private(set) var generation = 0
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var hasPrefetched = false

  var noStoredSessionStatus: String { "No stored session to load Discover" }

  func clearSessionScopedData() {
    clearAll()
  }

  var dailySongs: [PlaylistTrack] = []
  var dailyPlaylists: [DiscoveredPlaylist] = []
  var personalized: [DiscoveredPlaylist] = []
  var toplists: [DiscoveredPlaylist] = []
  var records: [PlayRecordEntry] = []
  var similarSongs: [PlaylistTrack] = []
  var similarSeedName: String?
  var searchResults: [PlaylistTrack] = []
  var searchQuery = ""
  var recordScope: PlayRecordScope = .allTime
  var isLoading = false
  var status = "Validate the session, then load each section explicitly"

  init(session: NeteaseSession) {
    self.session = session
  }

  /// One-time prefetch of the four Discover sections after the first
  /// successful validation of this app run: one request per section in
  /// sequence, stopping at the first error, with no retry. Later refreshes
  /// remain explicit user actions.
  func prefetch(loginCoordinator: LoginCoordinator) {
    guard
      !hasPrefetched, !loginCoordinator.isBusy, !isLoading,
      let account = loginCoordinator.account
    else { return }
    hasPrefetched = true
    let currentGeneration = generation
    isLoading = true
    status = "Prefetching Discover once (up to 4 requests)"
    loadTask = Task {
      defer { finish(generation: currentGeneration) }
      for step in [runDailySongs, runDailyPlaylists, runPersonalized, runToplists] {
        guard await step(account, currentGeneration, loginCoordinator) else { return }
      }
    }
  }

  func loadDailySongs(loginCoordinator: LoginCoordinator) {
    load(
      loadingStatus: "Loading daily recommended songs (1 request)",
      loginCoordinator: loginCoordinator,
      run: runDailySongs
    )
  }

  func loadDailyPlaylists(loginCoordinator: LoginCoordinator) {
    load(
      loadingStatus: "Loading daily recommended playlists (1 request)",
      loginCoordinator: loginCoordinator,
      run: runDailyPlaylists
    )
  }

  func loadPersonalized(loginCoordinator: LoginCoordinator) {
    load(
      loadingStatus: "Loading recommended playlists (1 request)",
      loginCoordinator: loginCoordinator,
      run: runPersonalized
    )
  }

  func loadToplists(loginCoordinator: LoginCoordinator) {
    load(
      loadingStatus: "Loading toplists (1 request)",
      loginCoordinator: loginCoordinator,
      run: runToplists
    )
  }

  func loadRecords(loginCoordinator: LoginCoordinator) {
    let scope = recordScope
    load(
      loadingStatus: "Loading listening rankings (1 request)",
      loginCoordinator: loginCoordinator,
      run: { account, generation, loginCoordinator in
        await self.run(
          operation: "Listening rankings",
          account: account,
          generation: generation,
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
    )
  }

  /// Similar songs for one explicitly chosen seed track (1 request).
  func loadSimilarSongs(
    seed: PlaylistTrack,
    loginCoordinator: LoginCoordinator
  ) {
    load(
      loadingStatus: "Loading similar songs (1 request)",
      loginCoordinator: loginCoordinator,
      run: { account, generation, loginCoordinator in
        await self.run(
          operation: "Similar songs",
          account: account,
          generation: generation,
          loginCoordinator: loginCoordinator,
          fetch: { credential, _ in
            try await self.session.similarSongs(
              songID: seed.id,
              credential: credential
            )
          },
          apply: { songs in
            self.similarSongs = songs
            self.similarSeedName = seed.name
            return "Loaded \(songs.count) songs similar to \(seed.name)"
          }
        )
      }
    )
  }

  /// Song search (1 request). Runs only from an explicit Search action; there
  /// is no as-you-type querying.
  func search(loginCoordinator: LoginCoordinator) {
    let keywords = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !keywords.isEmpty else { return }
    load(
      loadingStatus: "Searching (1 request)",
      loginCoordinator: loginCoordinator,
      run: { account, generation, loginCoordinator in
        await self.run(
          operation: "Search",
          account: account,
          generation: generation,
          loginCoordinator: loginCoordinator,
          fetch: { credential, _ in
            try await self.session.searchSongs(
              keywords: keywords,
              credential: credential
            )
          },
          apply: { songs in
            self.searchResults = songs
            return "Found \(songs.count) songs for \(keywords)"
          }
        )
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

  private func load(
    loadingStatus: String,
    loginCoordinator: LoginCoordinator,
    run: @escaping @MainActor (NeteaseAccount, Int, LoginCoordinator) async -> Bool
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
      _ = await run(account, currentGeneration, loginCoordinator)
    }
  }

  private func runDailySongs(
    account: NeteaseAccount,
    generation: Int,
    loginCoordinator: LoginCoordinator
  ) async -> Bool {
    await run(
      operation: "Daily songs",
      account: account,
      generation: generation,
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

  private func runDailyPlaylists(
    account: NeteaseAccount,
    generation: Int,
    loginCoordinator: LoginCoordinator
  ) async -> Bool {
    await run(
      operation: "Daily playlists",
      account: account,
      generation: generation,
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

  private func runPersonalized(
    account: NeteaseAccount,
    generation: Int,
    loginCoordinator: LoginCoordinator
  ) async -> Bool {
    await run(
      operation: "Recommended playlists",
      account: account,
      generation: generation,
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

  private func runToplists(
    account: NeteaseAccount,
    generation: Int,
    loginCoordinator: LoginCoordinator
  ) async -> Bool {
    await run(
      operation: "Toplists",
      account: account,
      generation: generation,
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

  private func run<Value: Sendable>(
    operation: String,
    account: NeteaseAccount,
    generation: Int,
    loginCoordinator: LoginCoordinator,
    fetch: @MainActor (NeteaseCredential, NeteaseAccount) async throws -> Value,
    apply: @MainActor (Value) -> String
  ) async -> Bool {
    do {
      guard
        let credential = try await currentCredential(
          account: account,
          generation: generation,
          loginCoordinator: loginCoordinator
        )
      else { return false }
      let value = try await fetch(credential, account)
      guard
        try await sessionRemainsCurrent(
          account: account,
          credential: credential,
          generation: generation,
          loginCoordinator: loginCoordinator
        )
      else { return false }
      status = apply(value)
      return true
    } catch {
      handle(error, generation: generation, operation: operation)
      return false
    }
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
    similarSongs = []
    similarSeedName = nil
    searchResults = []
  }
}
