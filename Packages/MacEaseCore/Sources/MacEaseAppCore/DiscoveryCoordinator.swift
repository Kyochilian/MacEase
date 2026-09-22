import Foundation
import NeteaseKit
import Observation

/// Discovery reads: the recommendation sections, the browsable playlist
/// catalogue, the radar family, recommended new songs, similar songs and
/// similar artists, plus listening rankings.
///
/// Independent sections load concurrently and publish as they arrive. Loaded
/// sections survive navigation; an account change clears their state.
@MainActor
@Observable
package final class DiscoveryCoordinator: SessionGuardedCoordinator {
  @ObservationIgnored private let transport: any NeteaseTransporting
  @ObservationIgnored package let vault: any CredentialStoring
  @ObservationIgnored private let arbiter: OperationArbiter
  @ObservationIgnored package private(set) var generation = 0
  @ObservationIgnored private var loadTasks: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var operationTokens: [String: OperationToken] = [:]
  @ObservationIgnored private var loadIDs: [String: UUID] = [:]
  @ObservationIgnored private var hasPrefetched = false
  @ObservationIgnored private var store: LibraryStore?
  @ObservationIgnored private var historyAccountID: Int64?
  @ObservationIgnored private var historyTask: Task<Void, Never>?

  package var noStoredSessionStatus: String { "No stored session to load Discover" }

  package func clearSessionScopedData() {
    clearAll()
  }

  package var dailySongs: [Track] = []
  package var dailyPlaylists: [DiscoveredPlaylist] = []
  package var personalized: [DiscoveredPlaylist] = []
  package var toplists: [DiscoveredPlaylist] = []
  package var records: [PlayRecordEntry] = []
  package private(set) var recentMusic: [RecentMusicEntry] = []
  package private(set) var recentKind: RecentMusicKind = .songs
  package private(set) var localHistory: [ListeningHistoryEntry] = []
  package private(set) var historyDiagnostic: String?
  package private(set) var playlistTags: [PlaylistTag] = []
  package private(set) var popularTags: [PlaylistTag] = []
  package private(set) var highQualityTags: [PlaylistTag] = []
  package private(set) var recommendationDates: [String] = []
  package private(set) var historicalRecommendations: [Track] = []
  package private(set) var recommendationDate: String?
  package var similarSongs: [Track] = []
  package var similarSeedName: String?
  package var recordScope: PlayRecordScope = .allTime
  package private(set) var loadingSections: Set<String> = []
  package private(set) var sectionErrors: [String: String] = [:]
  package private(set) var sectionStatuses: [String: String] = [:]
  package var isLoading: Bool { !loadingSections.isEmpty }
  package func isLoading(_ section: String) -> Bool { loadingSections.contains(section) }
  package var status = "Connect to discover music"

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

  /// Account-scoped initial content. One failed section never stops another.
  package func prefetch(session: any SessionProviding) {
    guard !hasPrefetched, session.isOnline else { return }
    hasPrefetched = true
    loadDailySongs(session: session)
    loadDailyPlaylists(session: session)
    loadPersonalized(session: session)
    loadToplists(session: session)
  }

  package func attach(store: LibraryStore?) { self.store = store }

  package func bindHistory(accountID: Int64?) {
    guard historyAccountID != accountID else { return }
    historyTask?.cancel()
    historyAccountID = accountID
    localHistory = []
    historyDiagnostic = nil
    guard let accountID else { return }
    historyTask = Task {
      do {
        let saved = try await store?.listeningHistory(accountID: accountID) ?? []
        guard historyAccountID == accountID, !Task.isCancelled else { return }
        var seen = Set(localHistory.map(\.id))
        localHistory = Array(
          (localHistory + saved.filter { seen.insert($0.id).inserted }).sorted {
            $0.playedAt > $1.playedAt
          }.prefix(1000))
      } catch {
        if historyAccountID == accountID {
          historyDiagnostic = "Listening history could not be read"
        }
      }
    }
  }

  package func recordPlayback(_ event: PlaybackLifecycleEvent) {
    guard case .started(let instance) = event, historyAccountID == instance.accountID,
      !localHistory.contains(where: { $0.id == instance.id })
    else { return }
    let entry = ListeningHistoryEntry(
      id: instance.id, track: instance.track, context: instance.context, playedAt: Date())
    localHistory.insert(entry, at: 0)
    localHistory = Array(localHistory.prefix(1000))
    Task {
      do { try await store?.saveListeningHistory(entry, accountID: instance.accountID) } catch {
        if historyAccountID == instance.accountID {
          historyDiagnostic = "Listening history could not be saved"
        }
      }
    }
  }

  package var recentSources: [PlaybackContext] {
    var sources: [PlaybackContext] = []
    for entry in localHistory {
      if !sources.contains(entry.context) { sources.append(entry.context) }
      if sources.count == 10 { break }
    }
    return sources
  }

  package func cancelLoading() {
    generation += 1
    for task in loadTasks.values { task.cancel() }
    loadTasks.removeAll()
    for token in operationTokens.values { arbiter.end(token, outcome: .cancelled) }
    operationTokens.removeAll()
    loadingSections.removeAll()
    loadIDs.removeAll()
  }

  private func cancelLoad(_ operation: String) {
    loadTasks.removeValue(forKey: operation)?.cancel()
    if let token = operationTokens.removeValue(forKey: operation) {
      arbiter.end(token, outcome: .cancelled)
    }
    loadingSections.remove(operation)
    loadIDs[operation] = nil
  }

  package func loadRecentMusic(kind: RecentMusicKind, session: any SessionProviding) {
    cancelLoad("Recent music")
    recentKind = kind
    recentMusic = []
    load(loadingStatus: "Loading recent music", operation: "Recent music", session: session) {
      account, generation, session in
      await self.run(
        operation: "Recent music", account: account, generation: generation, session: session,
        fetch: { credential, _ in
          try await self.transport.recentMusic(kind: kind, credential: credential)
        },
        apply: {
          self.recentMusic = $0
          return "Recent music loaded"
        })
    }
  }

  package func loadPlaylistTags(kind: PlaylistTagKind, session: any SessionProviding) {
    load(
      loadingStatus: "Loading playlist categories", operation: "Playlist categories \(kind)",
      session: session
    ) { account, generation, session in
      await self.run(
        operation: "Playlist categories \(kind)", account: account, generation: generation,
        session: session,
        fetch: { credential, _ in
          try await self.transport.playlistTags(kind: kind, credential: credential)
        },
        apply: {
          switch kind {
          case .all: self.playlistTags = $0
          case .popular: self.popularTags = $0
          case .highQuality: self.highQualityTags = $0
          }
          return "Playlist categories loaded"
        })
    }
  }

  package func loadBrowsingTags(session: any SessionProviding) async {
    for kind in PlaylistTagKind.allCases where sectionStatuses["Playlist categories \(kind)"] == nil
    {
      loadPlaylistTags(kind: kind, session: session)
    }
  }

  package func loadRecommendationHistory(date: String? = nil, session: any SessionProviding) {
    cancelLoad("Recommendation history")
    if let date {
      recommendationDate = date
      historicalRecommendations = []
      load(
        loadingStatus: "Loading recommendation history", operation: "Recommendation history",
        session: session
      ) { account, generation, session in
        await self.run(
          operation: "Recommendation history", account: account, generation: generation,
          session: session,
          fetch: { credential, _ in
            try await self.transport.recommendationHistory(date: date, credential: credential)
          },
          apply: {
            self.historicalRecommendations = $0
            return "Recommendations from \(date)"
          })
      }
    } else {
      load(
        loadingStatus: "Loading recommendation dates", operation: "Recommendation history",
        session: session
      ) { account, generation, session in
        await self.run(
          operation: "Recommendation history", account: account, generation: generation,
          session: session,
          fetch: { credential, _ in
            try await self.transport.recommendationHistoryDates(credential: credential)
          },
          apply: {
            self.recommendationDates = $0
            return $0.isEmpty
              ? "No recommendation history is available" : "Choose a recommendation date"
          })
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
  package func reloadCategory(session: any SessionProviding) {
    cancelLoad("Category playlists")
    loadCategoryPlaylists(reset: true, session: session)
  }

  package func reloadHighQuality(session: any SessionProviding) {
    cancelLoad("Highest-rated playlists")
    loadHighQualityPlaylists(reset: true, session: session)
  }

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
        guard
          let credential = try? await self.currentCredential(
            account: account, generation: generation, session: session)
        else { return false }
        self.radarPlaylists = []
        let transport = self.transport
        return await withTaskGroup(of: Result<DiscoveredPlaylist, OperationFailure>.self) { group in
          for playlistID in Self.radarPlaylistIDs {
            group.addTask {
              do {
                return .success(
                  try await transport.playlistBrief(
                    playlistID: playlistID, credential: credential))
              } catch {
                return .failure(OperationFailure.classify(error, cancelled: Task.isCancelled))
              }
            }
          }
          var success = true
          for await result in group {
            guard !Task.isCancelled, self.generation == generation,
              session.matchesValidatedSession(credential, account: account)
            else {
              group.cancelAll()
              return false
            }
            switch result {
            case .success(let playlist):
              self.radarPlaylists.append(playlist)
              self.radarPlaylists.sort {
                (Self.radarPlaylistIDs.firstIndex(of: $0.id) ?? 0)
                  < (Self.radarPlaylistIDs.firstIndex(of: $1.id) ?? 0)
              }
            case .failure:
              success = false
            }
          }
          self.status =
            "Loaded \(self.radarPlaylists.count) radar playlists"
            + (success ? "" : "; some playlists could not be loaded")
          self.sectionStatuses["Radar playlists"] = self.status
          if !success { self.sectionErrors["Radar playlists"] = self.status }
          return success
        }

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
    for task in loadTasks.values { await task.value }
  }

  package func reset() {
    cancelLoading()
    hasPrefetched = false
    sectionStatuses.removeAll()
    sectionErrors.removeAll()
    clearAll()
    status = "Connect to discover music"
  }

  private func load(
    loadingStatus: String,
    operation: String,
    session: any SessionProviding,
    run: @escaping @MainActor (NeteaseAccount, Int, any SessionProviding) async -> Bool
  ) {
    guard loadTasks[operation] == nil, session.isOnline, let account = session.account else {
      return
    }
    let currentGeneration = generation
    let loadID = UUID()
    loadIDs[operation] = loadID
    loadingSections.insert(operation)
    sectionErrors[operation] = nil
    sectionStatuses[operation] = loadingStatus
    status = loadingStatus
    loadTasks[operation] = Task {
      let token = await arbiter.beginWhenAvailable(name: operation, effect: .read)
      guard self.generation == currentGeneration, !Task.isCancelled else {
        if let token { arbiter.end(token, outcome: .cancelled) }
        return
      }
      var outcome = OperationOutcome.failed
      defer {
        if let token { arbiter.end(token, outcome: outcome) }
        if self.generation == currentGeneration, self.loadIDs[operation] == loadID {
          self.loadIDs[operation] = nil
          self.operationTokens[operation] = nil
          self.loadTasks[operation] = nil
          self.loadingSections.remove(operation)
        }
      }
      guard let token else {
        self.sectionStatuses[operation] = "Loading timed out; refresh to retry"
        return
      }
      self.operationTokens[operation] = token
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
      try Task.checkCancellation()
      let value = try await fetch(credential, account)
      guard
        try await sessionRemainsCurrent(
          account: account,
          credential: credential,
          generation: generation,
          session: session
        )
      else { return false }
      guard !Task.isCancelled else { return false }
      status = apply(value)
      sectionStatuses[operation] = status
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
    sectionErrors[operation] = status
    sectionStatuses[operation] = status
  }

  private func clearAll() {
    dailySongs = []
    dailyPlaylists = []
    personalized = []
    toplists = []
    records = []
    recentMusic = []
    bindHistory(accountID: nil)
    playlistTags = []
    popularTags = []
    highQualityTags = []
    recommendationDates = []
    historicalRecommendations = []
    recommendationDate = nil
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
