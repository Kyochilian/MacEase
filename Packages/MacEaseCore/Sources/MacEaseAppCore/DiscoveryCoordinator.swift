import Foundation
import NeteaseKit
import Observation

/// Discovery reads: the recommendation sections, the browsable playlist
/// catalogue, the radar family, recommended new songs, similar songs and
/// similar artists, plus listening rankings.
///
/// Every section loads from an explicit one-request user action, apart from
/// one launch-scoped prefetch of the four recommendation sections after the
/// first successful validation. Browsing, radar, new songs and the similar
/// lists are never prefetched: they follow a choice the user made, so there is
/// nothing to guess at before they make it. Nothing here polls. None of these
/// endpoints has verified credential-invalidation semantics, so service 301
/// classifies and stops.
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

  package var dailySongs: [Track] = []
  package var dailyPlaylists: [DiscoveredPlaylist] = []
  package var personalized: [DiscoveredPlaylist] = []
  package var toplists: [DiscoveredPlaylist] = []
  package var records: [PlayRecordEntry] = []
  package var similarSongs: [Track] = []
  package var similarSeedName: String?
  package var recordScope: PlayRecordScope = .allTime
  package var isLoading = false
  package var status = "Validate the session, then load each section explicitly"

  // MARK: - Browsing

  /// The four global playlist ids whose title, cover and contents NetEase
  /// generates per signed-in account. There is no radar endpoint: the feature
  /// is these fixed ids read through the ordinary playlist paths, which is
  /// what `missuo/kumone@db1a5e6` does in `Features/Home/HomeView.swift`.
  package static let radarPlaylistIDs: [Int64] = [
    3_136_952_023,  // 私人雷达
    2_829_883_282,  // 华语私人雷达
    2_829_816_518,  // 欧美私人雷达
    2_829_896_389,  // 日系私人雷达
  ]

  package var selectedCategory = PlaylistCategory.default {
    didSet {
      guard selectedCategory != oldValue else { return }
      clearCategoryPaging()
    }
  }
  package var categoryOrder: PlaylistOrder = .hot {
    didSet {
      guard categoryOrder != oldValue else { return }
      clearCategoryPaging()
    }
  }
  package private(set) var categoryPlaylists: [DiscoveredPlaylist] = []
  package private(set) var categoryHasMore = false
  package var selectedHighQualityCategory = PlaylistCategory.default {
    didSet {
      guard selectedHighQualityCategory != oldValue else { return }
      clearHighQualityPaging()
    }
  }
  package private(set) var highQualityPlaylists: [DiscoveredPlaylist] = []
  package private(set) var highQualityHasMore = false
  package private(set) var radarPlaylists: [DiscoveredPlaylist] = []
  package private(set) var newSongs: [Track] = []
  package private(set) var similarArtists: [Artist] = []
  package private(set) var similarArtistSeedName: String?
  /// The service's own cursor for the highest-rated list, which pages by the
  /// last row's update time rather than by an offset the client counts.
  @ObservationIgnored private var highQualityBefore: Int64 = 0
  /// Category pages use an offset supplied by the client. It advances by the
  /// raw server page size, not the number left after ID deduplication.
  @ObservationIgnored private var categoryOffset = 0

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
    seed: Track,
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
  package func loadCategoryPlaylists(reset: Bool, session: any SessionProviding) {
    guard reset || categoryHasMore else { return }
    let category = selectedCategory
    let order = categoryOrder
    let offset = reset ? 0 : categoryOffset
    load(
      loadingStatus: "Loading \(category) playlists (1 request)",
      operation: "Category playlists",
      session: session,
      run: { account, generation, session in
        await self.run(
          operation: "Category playlists",
          account: account,
          generation: generation,
          session: session,
          fetch: { credential, _ in
            try await self.transport.categoryPlaylists(
              category: category,
              order: order,
              limit: NeteaseSession.browsePageSize,
              offset: offset,
              credential: credential
            )
          },
          apply: { page in
            // The picker may have moved while the request was out. A page for
            // the tag the user left must not be shown under the one they
            // chose, and the cursor it carries names the wrong list.
            guard self.selectedCategory == category, self.categoryOrder == order
            else {
              return "Discarded a \(category) page; the category changed"
            }
            let pageItems = Self.deduplicated(page.items)
            if reset {
              self.categoryPlaylists = pageItems
            } else {
              var seen = Set(self.categoryPlaylists.map(\.id))
              self.categoryPlaylists += pageItems.filter {
                seen.insert($0.id).inserted
              }
            }
            self.categoryOffset = offset + page.items.count
            // An empty raw page cannot advance an offset. Trusting `more`
            // alone would resend the same request forever; deduplicated count
            // is deliberately irrelevant here.
            self.categoryHasMore = page.more && !page.items.isEmpty
            return "Loaded \(self.categoryPlaylists.count) \(category) playlists"
          }
        )
      }
    )
  }

  package func loadHighQualityPlaylists(reset: Bool, session: any SessionProviding) {
    guard reset || highQualityHasMore else { return }
    let category = selectedHighQualityCategory
    let before: Int64 = reset ? 0 : highQualityBefore
    load(
      loadingStatus: "Loading the highest-rated \(category) playlists (1 request)",
      operation: "Highest-rated playlists",
      session: session,
      run: { account, generation, session in
        await self.run(
          operation: "Highest-rated playlists",
          account: account,
          generation: generation,
          session: session,
          fetch: { credential, _ in
            try await self.transport.highQualityPlaylists(
              category: category,
              limit: NeteaseSession.browsePageSize,
              before: before,
              credential: credential
            )
          },
          apply: { page in
            guard self.selectedHighQualityCategory == category else {
              return "Discarded a \(category) page; the category changed"
            }
            let pageItems = Self.deduplicated(page.playlists)
            if reset {
              self.highQualityPlaylists = pageItems
            } else {
              var seen = Set(self.highQualityPlaylists.map(\.id))
              self.highQualityPlaylists += pageItems.filter {
                seen.insert($0.id).inserted
              }
            }
            self.highQualityBefore = page.before
            // This endpoint owns its cursor. If it claims more while returning
            // the cursor we just sent, there is no distinct next request.
            self.highQualityHasMore = page.more && page.before != before
            return
              "Loaded \(self.highQualityPlaylists.count) highest-rated "
              + "\(category) playlists"
          }
        )
      }
    )
  }

  /// The radar family, one request per playlist (up to 4). They are separate
  /// playlists, so there is no single response that holds all four; the run
  /// stops at the first failure and keeps what it already read.
  package func loadRadarPlaylists(session: any SessionProviding) {
    load(
      loadingStatus:
        "Loading radar playlists (up to \(Self.radarPlaylistIDs.count) requests)",
      operation: "Radar playlists",
      session: session,
      run: { account, generation, session in
        var loaded: [DiscoveredPlaylist] = []
        for playlistID in Self.radarPlaylistIDs {
          let ok = await self.run(
            operation: "Radar playlists",
            account: account,
            generation: generation,
            session: session,
            fetch: { credential, _ in
              try await self.transport.playlistBrief(
                playlistID: playlistID,
                credential: credential
              )
            },
            apply: { playlist in
              loaded.append(playlist)
              self.radarPlaylists = loaded
              return "Loaded \(loaded.count) radar playlists"
            }
          )
          guard ok else { return false }
        }
        return true
      }
    )
  }

  package func loadNewSongs(session: any SessionProviding) {
    load(
      loadingStatus: "Loading recommended new songs (1 request)",
      operation: "Recommended new songs",
      session: session,
      run: { account, generation, session in
        await self.run(
          operation: "Recommended new songs",
          account: account,
          generation: generation,
          session: session,
          fetch: { credential, _ in
            try await self.transport.recommendedNewSongs(
              limit: 20,
              credential: credential
            )
          },
          apply: { songs in
            self.newSongs = songs
            return "Loaded \(songs.count) recommended new songs"
          }
        )
      }
    )
  }

  /// Artists similar to one explicitly chosen seed (1 request).
  package func loadSimilarArtists(seed: Artist, session: any SessionProviding) {
    load(
      loadingStatus: "Loading similar artists (1 request)",
      operation: "Similar artists",
      session: session,
      run: { account, generation, session in
        await self.run(
          operation: "Similar artists",
          account: account,
          generation: generation,
          session: session,
          fetch: { credential, _ in
            try await self.transport.similarArtists(
              artistID: seed.id,
              credential: credential
            )
          },
          apply: { artists in
            self.similarArtists = artists
            self.similarArtistSeedName = seed.name
            return "Loaded \(artists.count) artists similar to \(seed.name)"
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
    // `hasPrefetched` is deliberately not cleared. Discarding the data an
    // identity was allowed to see and restoring the launch-scoped prefetch
    // budget are different things: re-arming it turns "up to four requests per
    // app run" into "up to four per credential change", which is hidden
    // network the user did not ask for. After a new sign-in the sections load
    // on an explicit action.
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

    let failure = OperationFailure.classify(error, cancelled: Task.isCancelled)
    // A superseded section must not report itself as a network problem.
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
    dailySongs = []
    dailyPlaylists = []
    personalized = []
    toplists = []
    records = []
    similarSongs = []
    similarSeedName = nil
    clearCategoryPaging()
    clearHighQualityPaging()
    radarPlaylists = []
    newSongs = []
    similarArtists = []
    similarArtistSeedName = nil
  }

  private func clearCategoryPaging() {
    categoryPlaylists = []
    categoryHasMore = false
    categoryOffset = 0
  }

  private func clearHighQualityPaging() {
    highQualityPlaylists = []
    highQualityHasMore = false
    highQualityBefore = 0
  }

  private static func deduplicated(
    _ playlists: [DiscoveredPlaylist]
  ) -> [DiscoveredPlaylist] {
    var seen: Set<Int64> = []
    return playlists.filter { seen.insert($0.id).inserted }
  }
}
