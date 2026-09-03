import Foundation
import NeteaseKit
import Observation

/// Search and the pages you open from it: albums, artists, the new-release
/// list and the artist chart.
///
/// Three streams of work run here and each is superseded by something
/// different — a new query supersedes a search, a new selection supersedes a
/// detail, a new keystroke supersedes a suggestion. They therefore hold
/// separate tasks and separate supersession counters, so typing cannot cancel
/// an album that is opening and opening an album cannot cancel a search.
/// `generation` stays what the shared session guard means by it: the identity
/// epoch, bumped only when the account changes.
///
/// Nothing here is prefetched and nothing polls. Every request follows a
/// choice the user has already made.
@MainActor
@Observable
package final class CatalogCoordinator: SessionGuardedCoordinator {
  package static let searchPageSize = 30
  package static let albumPageSize = 30
  package static let artistPageSize = 50

  /// One independently superseded stream of work.
  @MainActor
  private final class Lane {
    var task: Task<Void, Never>?
    var token: OperationToken?
    private(set) var generation = 0
    /// What the in-flight request is for, so pressing the same button twice
    /// does not send it twice while a different one still supersedes.
    private(set) var identity: String?

    func begin(_ identity: String) -> Int {
      generation += 1
      task?.cancel()
      task = nil
      self.identity = identity
      return generation
    }

    func accepts(_ generation: Int) -> Bool { self.generation == generation }

    func finish(_ generation: Int) {
      guard accepts(generation) else { return }
      identity = nil
      task = nil
    }

    func cancel() {
      generation += 1
      task?.cancel()
      task = nil
      identity = nil
    }
  }

  /// The identity of what is currently in the search controls. Raw spacing is
  /// not identity: the request uses the trimmed text, so the supersession rule
  /// must use that same value.
  private struct SearchInput: Equatable {
    let keywords: String
    let scope: SearchScope
  }

  @ObservationIgnored private let transport: any NeteaseTransporting
  @ObservationIgnored package let vault: any CredentialStoring
  @ObservationIgnored private let arbiter: OperationArbiter
  /// How long a keystroke waits before it becomes a request. Tests pass zero;
  /// the product value is short enough to feel immediate and long enough that
  /// typing a word is one request rather than one per letter.
  @ObservationIgnored private let suggestionDelay: Duration
  @ObservationIgnored package private(set) var generation = 0
  @ObservationIgnored private let search = Lane()
  @ObservationIgnored private let detail = Lane()
  @ObservationIgnored private let suggest = Lane()
  /// Album dynamic is an authoritative read for one id. The composition root
  /// forwards it to CollectionsCoordinator, the sole collection-state owner.
  @ObservationIgnored package var onAlbumCollectionStateConfirmed:
    (@MainActor (Int64, Bool) -> Void)?

  package var noStoredSessionStatus: String { "No stored session to search" }

  // MARK: - Search state

  package var query = "" {
    didSet {
      guard Self.trimmed(query) != Self.trimmed(oldValue) else { return }
      searchInputChanged(queryChanged: true)
    }
  }
  package var scope: SearchScope = .songs {
    didSet {
      guard scope != oldValue else { return }
      searchInputChanged(queryChanged: false)
    }
  }
  package private(set) var results: SearchItems = .songs([])
  package private(set) var resultsHaveMore = false
  /// What `results` are actually for, so a stale list is never labelled with
  /// whatever is in the field right now.
  package private(set) var resultsKeywords: String?
  package private(set) var suggestions: [SearchSuggestion] = []
  /// The service's own idea of what to search for. Shown as a placeholder and
  /// never run on the user's behalf.
  package private(set) var defaultKeyword: String?
  package var isSearching = false
  package var status = "Type a search and press Search"
  @ObservationIgnored private var searchOffset = 0

  // MARK: - Detail state

  package private(set) var album: AlbumDetail?
  package private(set) var albumDynamic: AlbumDynamic?
  package private(set) var artist: ArtistDetail?
  package private(set) var artistAlbums: [Album] = []
  package private(set) var artistAlbumsHaveMore = false
  @ObservationIgnored private var artistAlbumOffset = 0
  package var newAlbumArea: AlbumArea = .all {
    didSet {
      guard newAlbumArea != oldValue else { return }
      newAlbums = []
      newAlbumsHaveMore = false
      newAlbumOffset = 0
    }
  }
  package private(set) var newAlbums: [Album] = []
  package private(set) var newAlbumsHaveMore = false
  package private(set) var topArtists: [Artist] = []
  package private(set) var topArtistsHaveMore = false
  @ObservationIgnored private var newAlbumOffset = 0
  package var isLoadingDetail = false
  package var detailStatus = "Open an album or artist, or load a browse list"

  package init(
    transport: any NeteaseTransporting,
    vault: any CredentialStoring,
    arbiter: OperationArbiter,
    suggestionDelay: Duration = .milliseconds(250)
  ) {
    self.transport = transport
    self.vault = vault
    self.arbiter = arbiter
    self.suggestionDelay = suggestionDelay
  }

  package func clearSessionScopedData() {
    clearAll()
  }

  // MARK: - Search

  /// Runs the search the user submitted (1 request). Changing the keywords or
  /// the kind of thing being searched for starts over from offset zero.
  package func runSearch(session: any SessionProviding) {
    let keywords = Self.trimmed(query)
    guard !keywords.isEmpty else { return }
    performSearch(keywords: keywords, scope: scope, offset: 0, session: session)
  }

  /// Fetches the next page of the search already on screen (1 request). The
  /// The offset counts raw rows consumed from the server. Display rows are
  /// deduplicated separately, so a repeated row cannot move the next request
  /// backwards.
  package func loadMoreResults(session: any SessionProviding) {
    guard resultsHaveMore, let keywords = resultsKeywords else { return }
    performSearch(
      keywords: keywords,
      scope: results.scope,
      offset: searchOffset,
      session: session
    )
  }

  private func performSearch(
    keywords: String,
    scope requested: SearchScope,
    offset: Int,
    session: any SessionProviding
  ) {
    // A first page for a different query or kind replaces what is on screen
    // before the request goes out, so nothing stale is ever shown as a result
    // for the new one.
    let isNewQuery = offset == 0
    read(
      in: search,
      identity: "search|\(requested.rawValue)|\(offset)|\(keywords)",
      operation: "Search",
      loading: isNewQuery
        ? "Searching (1 request)" : "Loading more results (1 request)",
      report: { self.status = $0 },
      busy: { self.isSearching = $0 },
      session: session,
      onStart: {
        guard isNewQuery else { return }
        self.results = .empty(requested)
        self.resultsHaveMore = false
        self.resultsKeywords = keywords
        self.searchOffset = 0
        self.suggestions = []
      },
      fetch: { credential in
        try await self.transport.search(
          keywords: keywords,
          scope: requested,
          limit: Self.searchPageSize,
          offset: offset,
          credential: credential
        )
      },
      apply: { page in
        // The field may have moved on while the request was out.
        guard
          self.currentSearchInput == SearchInput(keywords: keywords, scope: requested),
          self.resultsKeywords == keywords,
          self.results.scope == requested
        else {
          return "Discarded results for \(keywords); the search changed"
        }
        self.results = isNewQuery ? page.items : self.results.appending(page.items)
        self.searchOffset = offset + page.items.count
        self.resultsHaveMore = Self.hasMore(
          consumed: self.searchOffset,
          page: page,
          limit: Self.searchPageSize
        )
        return "Found \(self.results.count) results for \(keywords)"
      }
    )
  }

  /// Whether another page is worth asking for. The service reports a total for
  /// most scopes; without one, a full page is taken as evidence that another
  /// may exist, which costs at most one request that returns nothing.
  private static func hasMore(consumed: Int, page: SearchPage, limit: Int) -> Bool {
    guard let total = page.totalCount else { return page.items.count >= limit }
    return consumed < total && page.items.count > 0
  }

  /// Asks for suggestions after a short pause in typing. Clearing the field
  /// clears the list without a request.
  package func updateSuggestions(session: any SessionProviding) {
    let keywords = Self.trimmed(query)
    guard !keywords.isEmpty else {
      cancelSuggestions()
      suggestions = []
      return
    }
    guard suggest.identity != keywords else { return }
    // The old rows describe the previous input. They disappear before the
    // debounce wait or an arbiter refusal, not only after a new answer lands.
    suggestions = []
    releaseLaneToken(suggest)
    let laneGeneration = suggest.begin(keywords)
    let identityGeneration = generation
    suggest.task = Task {
      defer { self.suggest.finish(laneGeneration) }
      // The wait happens before anything is claimed, so a keystroke that is
      // superseded never holds a read slot.
      try? await Task.sleep(for: self.suggestionDelay)
      guard !Task.isCancelled, self.suggest.accepts(laneGeneration) else { return }
      guard let account = session.account,
        let token = self.arbiter.begin(name: "Search suggestions", effect: .read)
      else { return }
      self.suggest.token = token
      var outcome = OperationOutcome.failed
      defer { self.releaseToken(token, in: self.suggest, outcome: outcome) }
      do {
        guard
          let credential = try await self.currentCredential(
            account: account,
            generation: identityGeneration,
            session: session
          )
        else { return }
        let rows = try await self.transport.searchSuggestions(
          keywords: keywords,
          credential: credential
        )
        guard
          self.suggest.accepts(laneGeneration),
          try await self.sessionRemainsCurrent(
            account: account,
            credential: credential,
            generation: identityGeneration,
            session: session
          )
        else {
          outcome = .cancelled
          return
        }
        self.suggestions = rows
        outcome = .applied
      } catch {
        outcome = Task.isCancelled ? .cancelled : .failed
        // A suggestion is an aid, not a result. Failing one must not overwrite
        // the line that says what the last real search found; it just leaves
        // the user with no suggestions, which is what they had before.
        guard self.suggest.accepts(laneGeneration) else { return }
        self.suggestions = []
      }
    }
  }

  package func cancelSuggestions() {
    releaseLaneToken(suggest)
    suggest.cancel()
  }

  /// A query or scope edit supersedes the submitted search immediately, but
  /// never submits the new input. Suggestions have their own lifecycle: only
  /// a query edit invalidates them, and the view explicitly starts their
  /// debounce afterwards.
  private func searchInputChanged(queryChanged: Bool) {
    releaseLaneToken(search)
    search.cancel()
    isSearching = false
    results = .empty(scope)
    resultsKeywords = nil
    resultsHaveMore = false
    searchOffset = 0
    if queryChanged {
      cancelSuggestions()
      suggestions = []
    }
    status = currentSearchInput.keywords.isEmpty
      ? "Type a search and press Search"
      : "Press Search to search the current input"
  }

  /// Loads the keyword the service would search for by default (1 request).
  /// It only ever becomes a placeholder.
  package func loadDefaultKeyword(session: any SessionProviding) {
    read(
      in: search,
      identity: "default-keyword",
      operation: "Default search keyword",
      loading: "Loading the default search keyword (1 request)",
      report: { self.status = $0 },
      busy: { self.isSearching = $0 },
      session: session,
      onStart: {},
      fetch: { credential in
        try await self.transport.defaultSearchKeyword(credential: credential)
      },
      apply: { keyword in
        self.defaultKeyword = keyword
        return keyword.map { "Suggested search: \($0)" }
          ?? "The service suggested no default search"
      }
    )
  }

  // MARK: - Album and artist pages

  /// Opens an album: what is on it, and whether the account has collected it
  /// (2 requests).
  package func openAlbum(id albumID: Int64, session: any SessionProviding) {
    read(
      in: detail,
      identity: "album-\(albumID)",
      operation: "Album",
      loading: "Loading the album (2 requests)",
      report: { self.detailStatus = $0 },
      busy: { self.isLoadingDetail = $0 },
      session: session,
      onStart: {
        self.album = nil
        self.albumDynamic = nil
        self.artist = nil
        self.artistAlbums = []
        self.artistAlbumsHaveMore = false
        self.artistAlbumOffset = 0
      },
      fetch: { credential in
        let detail = try await self.transport.albumDetail(
          albumID: albumID,
          credential: credential
        )
        let dynamic = try await self.transport.albumDynamic(
          albumID: albumID,
          credential: credential
        )
        return (detail, dynamic)
      },
      apply: { loaded in
        self.album = loaded.0
        self.albumDynamic = loaded.1
        if let collected = loaded.1.isCollected {
          self.onAlbumCollectionStateConfirmed?(albumID, collected)
        }
        return "Loaded \(loaded.0.tracks.count) tracks from \(loaded.0.album.name)"
      }
    )
  }

  /// Opens an artist: who they are, the songs the service ranks highest, and
  /// the first page of their albums (2 requests).
  package func openArtist(id artistID: Int64, session: any SessionProviding) {
    read(
      in: detail,
      identity: "artist-\(artistID)",
      operation: "Artist",
      loading: "Loading the artist (2 requests)",
      report: { self.detailStatus = $0 },
      busy: { self.isLoadingDetail = $0 },
      session: session,
      onStart: {
        self.artist = nil
        self.artistAlbums = []
        self.artistAlbumsHaveMore = false
        self.artistAlbumOffset = 0
        self.album = nil
        self.albumDynamic = nil
      },
      fetch: { credential in
        let detail = try await self.transport.artistDetail(
          artistID: artistID,
          credential: credential
        )
        let albums = try await self.transport.artistAlbums(
          artistID: artistID,
          limit: Self.albumPageSize,
          offset: 0,
          credential: credential
        )
        return (detail, albums)
      },
      apply: { loaded in
        self.artist = loaded.0
        self.artistAlbums = Self.deduplicated(loaded.1.items)
        self.artistAlbumOffset = loaded.1.items.count
        self.artistAlbumsHaveMore = loaded.1.more && !loaded.1.items.isEmpty
        return
          "Loaded \(loaded.0.hotSongs.count) top songs and "
          + "\(loaded.1.items.count) albums for \(loaded.0.artist.name)"
      }
    )
  }

  package func loadMoreArtistAlbums(session: any SessionProviding) {
    guard artistAlbumsHaveMore, let openArtist = artist?.artist else { return }
    let offset = artistAlbumOffset
    read(
      in: detail,
      identity: "artist-albums-\(openArtist.id)-\(offset)",
      operation: "Artist albums",
      loading: "Loading more albums (1 request)",
      report: { self.detailStatus = $0 },
      busy: { self.isLoadingDetail = $0 },
      session: session,
      onStart: {},
      fetch: { credential in
        try await self.transport.artistAlbums(
          artistID: openArtist.id,
          limit: Self.albumPageSize,
          offset: offset,
          credential: credential
        )
      },
      apply: { page in
        // Another artist may have been opened while this page was out.
        guard self.artist?.artist.id == openArtist.id else {
          return "Discarded albums for \(openArtist.name); the artist changed"
        }
        var seen = Set(self.artistAlbums.map(\.id))
        self.artistAlbums += page.items.filter { seen.insert($0.id).inserted }
        self.artistAlbumOffset = offset + page.items.count
        self.artistAlbumsHaveMore = page.more && !page.items.isEmpty
        return "Loaded \(self.artistAlbums.count) albums by \(openArtist.name)"
      }
    )
  }

  // MARK: - Browse lists

  package func loadNewAlbums(reset: Bool, session: any SessionProviding) {
    guard reset || newAlbumsHaveMore else { return }
    let area = newAlbumArea
    let offset = reset ? 0 : newAlbumOffset
    read(
      in: detail,
      identity: "new-albums-\(area.rawValue)-\(offset)",
      operation: "New albums",
      loading: "Loading new albums (1 request)",
      report: { self.detailStatus = $0 },
      busy: { self.isLoadingDetail = $0 },
      session: session,
      onStart: {},
      fetch: { credential in
        try await self.transport.newAlbums(
          area: area,
          limit: Self.albumPageSize,
          offset: offset,
          credential: credential
        )
      },
      apply: { page in
        guard self.newAlbumArea == area else {
          return "Discarded \(area.rawValue) albums; the region changed"
        }
        if reset {
          self.newAlbums = Self.deduplicated(page.items)
        } else {
          var seen = Set(self.newAlbums.map(\.id))
          self.newAlbums += page.items.filter { seen.insert($0.id).inserted }
        }
        self.newAlbumOffset = offset + page.items.count
        self.newAlbumsHaveMore = page.more && !page.items.isEmpty
        return "Loaded \(self.newAlbums.count) new albums"
      }
    )
  }

  package func loadTopArtists(reset: Bool, session: any SessionProviding) {
    guard reset || topArtistsHaveMore else { return }
    read(
      in: detail,
      identity: "top-artists",
      operation: "Top artists",
      loading: "Loading top artists (1 request)",
      report: { self.detailStatus = $0 },
      busy: { self.isLoadingDetail = $0 },
      session: session,
      onStart: {},
      fetch: { credential in
        try await self.transport.topArtists(
          credential: credential
        )
      },
      apply: { page in
        if reset {
          self.topArtists = Self.deduplicated(page.items)
        } else {
          var seen = Set(self.topArtists.map(\.id))
          self.topArtists += page.items.filter { seen.insert($0.id).inserted }
        }
        self.topArtistsHaveMore = false
        return "Loaded \(self.topArtists.count) top artists"
      }
    )
  }

  // MARK: - Lifecycle

  /// Test seam: awaits whichever lanes are running, so a test can assert on
  /// settled state without polling.
  package func settleForTesting() async {
    await search.task?.value
    await detail.task?.value
    await suggest.task?.value
  }

  package func reset() {
    generation += 1
    for lane in [search, detail, suggest] {
      releaseLaneToken(lane)
      lane.cancel()
    }
    clearAll()
    isSearching = false
    isLoadingDetail = false
    status = "Type a search and press Search"
    detailStatus = "Open an album or artist, or load a browse list"
  }

  // MARK: - Shared execution

  private func read<Value: Sendable>(
    in lane: Lane,
    identity: String,
    operation: String,
    loading: String,
    report: @escaping @MainActor (String) -> Void,
    busy: @escaping @MainActor (Bool) -> Void,
    session: any SessionProviding,
    onStart: @MainActor () -> Void,
    fetch: @escaping @MainActor (NeteaseCredential) async throws -> Value,
    apply: @escaping @MainActor (Value) -> String
  ) {
    // The same button pressed twice is one request; a different one supersedes.
    guard lane.identity != identity else { return }
    // Giving the superseded read its slot back before claiming a new one means
    // superseding cannot be refused by the read ceiling this lane itself is
    // occupying. There is no suspension in between.
    releaseLaneToken(lane)
    lane.cancel()
    busy(false)
    guard let token = arbiter.begin(name: operation, effect: .read) else { return }
    guard let account = session.account else {
      arbiter.end(token, outcome: .failed)
      report("Validate the session first")
      return
    }

    let identityGeneration = generation
    let laneGeneration = lane.begin(identity)
    lane.token = token
    onStart()
    busy(true)
    report(loading)
    lane.task = Task {
      var outcome = OperationOutcome.failed
      defer {
        self.releaseToken(token, in: lane, outcome: outcome)
        if lane.accepts(laneGeneration) { busy(false) }
        lane.finish(laneGeneration)
      }
      do {
        guard
          let credential = try await self.currentCredential(
            account: account,
            generation: identityGeneration,
            session: session
          )
        else { return }
        guard lane.accepts(laneGeneration) else {
          outcome = .cancelled
          return
        }
        let value = try await fetch(credential)
        guard
          lane.accepts(laneGeneration),
          try await self.sessionRemainsCurrent(
            account: account,
            credential: credential,
            generation: identityGeneration,
            session: session
          ),
          lane.accepts(laneGeneration)
        else {
          // A read that could not be published changed nothing on the server.
          outcome = .cancelled
          return
        }
        report(apply(value))
        outcome = .applied
      } catch {
        outcome = Task.isCancelled ? .cancelled : .failed
        guard lane.accepts(laneGeneration), self.generation == identityGeneration
        else { return }
        let failure = OperationFailure.classify(error, cancelled: Task.isCancelled)
        guard failure.isReportable else { return }
        report(failure.statusText(operation: operation))
      }
    }
  }

  private func releaseLaneToken(_ lane: Lane) {
    guard let token = lane.token else { return }
    lane.token = nil
    arbiter.end(token, outcome: .cancelled)
  }

  private func releaseToken(
    _ token: OperationToken,
    in lane: Lane,
    outcome: OperationOutcome
  ) {
    if lane.token == token { lane.token = nil }
    arbiter.end(token, outcome: outcome)
  }

  private func clearAll() {
    results = .empty(scope)
    resultsHaveMore = false
    resultsKeywords = nil
    searchOffset = 0
    suggestions = []
    defaultKeyword = nil
    album = nil
    albumDynamic = nil
    artist = nil
    artistAlbums = []
    artistAlbumsHaveMore = false
    artistAlbumOffset = 0
    newAlbums = []
    newAlbumsHaveMore = false
    newAlbumOffset = 0
    topArtists = []
    topArtistsHaveMore = false
  }

  private var currentSearchInput: SearchInput {
    SearchInput(keywords: Self.trimmed(query), scope: scope)
  }

  private static func trimmed(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func deduplicated<Item: Identifiable>(_ items: [Item]) -> [Item]
  where Item.ID: Hashable {
    var seen: Set<Item.ID> = []
    return items.filter { seen.insert($0.id).inserted }
  }
}
