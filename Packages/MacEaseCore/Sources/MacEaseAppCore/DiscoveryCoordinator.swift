import Foundation
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
package final class DiscoveryCoordinator: SessionGuardedCoordinator {
  @ObservationIgnored private let transport: any NeteaseTransporting
  @ObservationIgnored package let vault: any CredentialStoring
  @ObservationIgnored private let arbiter: OperationArbiter
  @ObservationIgnored package private(set) var generation = 0
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var operationToken: OperationToken?
  @ObservationIgnored private var hasPrefetched = false

  package var noStoredSessionStatus: String { "No stored session to load Discover" }

  package func clearSessionScopedData() {
    clearAll()
  }

  package var dailySongs: [PlaylistTrack] = []
  package var dailyPlaylists: [DiscoveredPlaylist] = []
  package var personalized: [DiscoveredPlaylist] = []
  package var toplists: [DiscoveredPlaylist] = []
  package var records: [PlayRecordEntry] = []
  package var similarSongs: [PlaylistTrack] = []
  package var similarSeedName: String?
  package var searchResults: [PlaylistTrack] = []
  package var searchQuery = ""
  package var recordScope: PlayRecordScope = .allTime
  package var isLoading = false
  package var status = "Validate the session, then load each section explicitly"

  package init(
    transport: any NeteaseTransporting,
    vault: any CredentialStoring,
    arbiter: OperationArbiter
  ) {
    self.transport = transport
    self.vault = vault
    self.arbiter = arbiter
  }

  /// One-time prefetch of the four Discover sections after the first
  /// successful validation of this app run: one request per section in
  /// sequence, stopping at the first error, with no retry. Later refreshes
  /// remain explicit user actions.
  package func prefetch(session: any SessionProviding) {
    guard !hasPrefetched, session.account != nil else { return }
    guard let claim = claim("Discover prefetch", session: session) else { return }
    hasPrefetched = true
    let currentGeneration = generation
    let account = claim.account
    isLoading = true
    status = "Prefetching Discover once (up to 4 requests)"
    loadTask = Task {
      var outcome = OperationOutcome.applied
      defer {
        release(claim.token, outcome: outcome)
        finish(generation: currentGeneration)
      }
      arbiter.markRequestSent(claim.token)
      for step in [runDailySongs, runDailyPlaylists, runPersonalized, runToplists] {
        guard await step(account, currentGeneration, session) else {
          outcome = .failed
          return
        }
      }
    }
  }

  package func loadDailySongs(session: any SessionProviding) {
    load(
      loadingStatus: "Loading daily recommended songs (1 request)",
      operation: "Daily songs",
      session: session,
      run: runDailySongs
    )
  }

  package func loadDailyPlaylists(session: any SessionProviding) {
    load(
      loadingStatus: "Loading daily recommended playlists (1 request)",
      operation: "Daily playlists",
      session: session,
      run: runDailyPlaylists
    )
  }

  package func loadPersonalized(session: any SessionProviding) {
    load(
      loadingStatus: "Loading recommended playlists (1 request)",
      operation: "Recommended playlists",
      session: session,
      run: runPersonalized
    )
  }

  package func loadToplists(session: any SessionProviding) {
    load(
      loadingStatus: "Loading toplists (1 request)",
      operation: "Toplists",
      session: session,
      run: runToplists
    )
  }

  package func loadRecords(session: any SessionProviding) {
    let scope = recordScope
    load(
      loadingStatus: "Loading listening rankings (1 request)",
      operation: "Listening rankings",
      session: session,
      run: { account, generation, session in
        await self.run(
          operation: "Listening rankings",
          account: account,
          generation: generation,
          session: session,
          fetch: { credential, account in
            try await self.transport.playRecords(
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
  package func loadSimilarSongs(
    seed: PlaylistTrack,
    session: any SessionProviding
  ) {
    load(
      loadingStatus: "Loading similar songs (1 request)",
      operation: "Similar songs",
      session: session,
      run: { account, generation, session in
        await self.run(
          operation: "Similar songs",
          account: account,
          generation: generation,
          session: session,
          fetch: { credential, _ in
            try await self.transport.similarSongs(
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
  package func search(session: any SessionProviding) {
    let keywords = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !keywords.isEmpty else { return }
    load(
      loadingStatus: "Searching (1 request)",
      operation: "Search",
      session: session,
      run: { account, generation, session in
        await self.run(
          operation: "Search",
          account: account,
          generation: generation,
          session: session,
          fetch: { credential, _ in
            try await self.transport.searchSongs(
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

  /// Test seam: awaits the task the last explicit action started, so a test
  /// can assert on settled state without polling.
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
    hasPrefetched = false
    clearAll()
    isLoading = false
    status = "Validate the session, then load each section explicitly"
  }

  private struct Claim {
    let token: OperationToken
    let account: NeteaseAccount
  }

  /// Claims the validated account while no write/session mutation is active;
  /// `isLoading` prevents duplicate work inside this coordinator.
  private func claim(_ name: String, session: any SessionProviding) -> Claim? {
    guard !isLoading else { return nil }
    guard let token = arbiter.begin(name: name, effect: .read) else { return nil }
    guard let account = session.account else {
      arbiter.end(token, outcome: .failed)
      status = "Validate the session before loading"
      return nil
    }
    operationToken = token
    return Claim(token: token, account: account)
  }

  private func load(
    loadingStatus: String,
    operation: String,
    session: any SessionProviding,
    run: @escaping @MainActor (NeteaseAccount, Int, any SessionProviding) async -> Bool
  ) {
    guard let claim = claim(operation, session: session) else { return }

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
      arbiter.markRequestSent(claim.token)
      outcome = await run(account, currentGeneration, session) ? .applied : .failed
    }
  }

  private func runDailySongs(
    account: NeteaseAccount,
    generation: Int,
    session: any SessionProviding
  ) async -> Bool {
    await run(
      operation: "Daily songs",
      account: account,
      generation: generation,
      session: session,
      fetch: { credential, _ in
        try await self.transport.dailyRecommendedSongs(credential: credential)
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
    session: any SessionProviding
  ) async -> Bool {
    await run(
      operation: "Daily playlists",
      account: account,
      generation: generation,
      session: session,
      fetch: { credential, _ in
        try await self.transport.dailyRecommendedPlaylists(credential: credential)
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
    session: any SessionProviding
  ) async -> Bool {
    await run(
      operation: "Recommended playlists",
      account: account,
      generation: generation,
      session: session,
      fetch: { credential, _ in
        try await self.transport.personalizedPlaylists(credential: credential)
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
    session: any SessionProviding
  ) async -> Bool {
    await run(
      operation: "Toplists",
      account: account,
      generation: generation,
      session: session,
      fetch: { credential, _ in
        try await self.transport.toplists(credential: credential)
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
    session: any SessionProviding,
    fetch: @MainActor (NeteaseCredential, NeteaseAccount) async throws -> Value,
    apply: @MainActor (Value) -> String
  ) async -> Bool {
    do {
      guard
        let credential = try await currentCredential(
          account: account,
          generation: generation,
          session: session
        )
      else { return false }
      let value = try await fetch(credential, account)
      guard
        try await sessionRemainsCurrent(
          account: account,
          credential: credential,
          generation: generation,
          session: session
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

  private func release(_ token: OperationToken, outcome: OperationOutcome) {
    if operationToken == token { operationToken = nil }
    arbiter.end(token, outcome: outcome)
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
