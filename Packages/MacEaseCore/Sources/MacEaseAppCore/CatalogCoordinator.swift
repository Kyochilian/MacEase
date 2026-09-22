import Foundation
import NeteaseKit
import Observation

/// The choices exposed by the Search tab. `all` is composed in the app layer;
/// the remaining cases map one-to-one to the existing NetEase search scope.
package enum CatalogSearchScope: CaseIterable, Sendable, Hashable {
  case all
  case songs
  case artists
  case albums
  case playlists

  fileprivate var neteaseScope: SearchScope? {
    switch self {
    case .all: nil
    case .songs: .songs
    case .artists: .artists
    case .albums: .albums
    case .playlists: .playlists
    }
  }

  fileprivate init(_ scope: SearchScope) {
    switch scope {
    case .songs: self = .songs
    case .artists: self = .artists
    case .albums: self = .albums
    case .playlists: self = .playlists
    }
  }
}

/// The four bounded result groups produced by one explicit All search.
package struct CombinedSearchResults: Equatable, Sendable {
  package var songs: [Track] = []
  package var artists: [Artist] = []
  package var albums: [Album] = []
  package var playlists: [DiscoveredPlaylist] = []
  package var failedScopes: [SearchScope] = []

  package init() {}

  package var count: Int {
    songs.count + artists.count + albums.count + playlists.count
  }

  package var isEmpty: Bool { count == 0 }
  package var isIncomplete: Bool { !failedScopes.isEmpty }
}

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
    let scope: CatalogSearchScope
  }

  private struct SearchGroup: Sendable {
    let scope: SearchScope
    let result: Result<SearchPage, OperationFailure>
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
  package var scope: CatalogSearchScope = .songs {
    didSet {
      guard scope != oldValue else { return }
      searchInputChanged(queryChanged: false)
    }
  }
  package private(set) var results: SearchItems = .songs([])
  package private(set) var combinedResults = CombinedSearchResults()
  package private(set) var resultsHaveMore = false
  /// What `results` are actually for, so a stale list is never labelled with
  /// whatever is in the field right now.
  package private(set) var resultsKeywords: String?
  package private(set) var suggestions: [SearchSuggestion] = []
  /// The service's own idea of what to search for. Shown as a placeholder and
  /// never run on the user's behalf.
  package private(set) var defaultKeyword: String?
  package private(set) var hotSearches: [HotSearch] = []
  package private(set) var searchHistory: [String] = []
  @ObservationIgnored private var store: LibraryStore?
  @ObservationIgnored private var historyWriteTask: Task<Void, Never>?
  package var isSearching = false
  package var status = "Type a search and press Search"
  @ObservationIgnored private var searchOffset = 0

  // MARK: - Detail state

  package private(set) var album: AlbumDetail?
  package private(set) var albumDynamic: AlbumDynamic?
  package private(set) var artist: ArtistDetail?
  package private(set) var song: Track?
  package private(set) var artistSongs: [Track] = []
  package private(set) var artistSongsHaveMore = true
  package private(set) var artistBiography: String?
  @ObservationIgnored private var artistSongOffset = 0
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

  package func attach(store: LibraryStore?) { self.store = store }

  package func loadSearchHistory(session: any SessionProviding) async {
    guard let account = session.account else { return }
    let expected = generation
    do {
      let saved = try await store?.searchHistory(accountID: account.userID) ?? []
      if generation == expected, session.account?.userID == account.userID {
        var seen = Set(searchHistory)
        searchHistory = Array(
          (searchHistory + saved.filter { seen.insert($0).inserted }).prefix(50))
      }
    } catch { if generation == expected { status = "Search history could not be read" } }
  }

  package func clearSearchHistory(session: any SessionProviding) {
    guard let account = session.account else { return }
    searchHistory = []
    let previous = historyWriteTask
    let expected = generation
    historyWriteTask = Task {
      await previous?.value
      do { try await store?.clearSearchHistory(accountID: account.userID) } catch {
        if generation == expected { status = "Search history could not be cleared from storage" }
      }
    }
  }

  // MARK: - Search

  /// Runs the search the user submitted. All uses four bounded requests;
  /// individual scopes retain the existing single-request paging path.
  package func runSearch(session: any SessionProviding) {
    let keywords = Self.trimmed(query)
    guard !keywords.isEmpty else { return }
    if let account = session.account {
      searchHistory.removeAll { $0 == keywords }
      searchHistory.insert(keywords, at: 0)
      searchHistory = Array(searchHistory.prefix(50))
      let previous = historyWriteTask
      let expected = generation
      historyWriteTask = Task {
        await previous?.value
        do { try await store?.saveSearch(keywords, accountID: account.userID) } catch {
          if generation == expected { status = "Search history could not be saved" }
        }
      }
    }
    guard let requested = scope.neteaseScope else {
      performCombinedSearch(keywords: keywords, session: session)
      return
    }
    performSearch(keywords: keywords, scope: requested, offset: 0, session: session)
  }

  /// Fetches the next page of the search already on screen (1 request). The
  /// The offset counts raw rows consumed from the server. Display rows are
  /// deduplicated separately, so a repeated row cannot move the next request
  /// backwards.
  package func loadMoreResults(session: any SessionProviding) {
    guard
      resultsHaveMore,
      let keywords = resultsKeywords,
      scope.neteaseScope == results.scope
    else { return }
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
        self.combinedResults = CombinedSearchResults()
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
          self.currentSearchInput
            == SearchInput(keywords: keywords, scope: CatalogSearchScope(requested)),
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

  private func performCombinedSearch(
    keywords: String,
    session: any SessionProviding
  ) {
    read(
      in: search,
      identity: "search|all|\(keywords)",
      operation: "Search",
      loading: "Searching songs, artists, albums, and playlists (4 requests)",
      report: { self.status = $0 },
      busy: { self.isSearching = $0 },
      session: session,
      onStart: {
        self.results = .songs([])
        self.combinedResults = CombinedSearchResults()
        self.resultsHaveMore = false
        self.resultsKeywords = keywords
        self.searchOffset = 0
        self.suggestions = []
      },
      fetch: { credential in
        try await self.fetchCombinedSearch(keywords: keywords, credential: credential)
      },
      apply: { combined in
        guard
          self.currentSearchInput == SearchInput(keywords: keywords, scope: .all),
          self.resultsKeywords == keywords
        else {
          return "Discarded results for \(keywords); the search changed"
        }
        self.combinedResults = combined
        let successfulGroups = 4 - combined.failedScopes.count
        if combined.isIncomplete {
          return
            "Found \(combined.count) results across \(successfulGroups) of 4 categories "
            + "for \(keywords); results are incomplete"
        }
        return "Found \(combined.count) results across 4 categories for \(keywords)"
      }
    )
  }

  private func fetchCombinedSearch(
    keywords: String,
    credential: NeteaseCredential
  ) async throws -> CombinedSearchResults {
    async let songs = fetchSearchGroup(
      keywords: keywords,
      scope: .songs,
      limit: 12,
      credential: credential
    )
    async let artists = fetchSearchGroup(
      keywords: keywords,
      scope: .artists,
      limit: 10,
      credential: credential
    )
    async let albums = fetchSearchGroup(
      keywords: keywords,
      scope: .albums,
      limit: 10,
      credential: credential
    )
    async let playlists = fetchSearchGroup(
      keywords: keywords,
      scope: .playlists,
      limit: 10,
      credential: credential
    )

    let groups = await [songs, artists, albums, playlists]
    var combined = CombinedSearchResults()
    var firstFailure: OperationFailure?
    var successCount = 0
    for group in groups {
      switch group.result {
      case .success(let page):
        guard page.items.scope == group.scope else {
          combined.failedScopes.append(group.scope)
          firstFailure = firstFailure ?? .decode
          continue
        }
        successCount += 1
        switch page.items {
        case .songs(let rows): combined.songs = rows
        case .artists(let rows): combined.artists = rows
        case .albums(let rows): combined.albums = rows
        case .playlists(let rows): combined.playlists = rows
        }
      case .failure(let failure):
        combined.failedScopes.append(group.scope)
        firstFailure = firstFailure ?? failure
      }
    }
    if successCount == 0 { throw firstFailure ?? OperationFailure.transport }
    return combined
  }

  private func fetchSearchGroup(
    keywords: String,
    scope: SearchScope,
    limit: Int,
    credential: NeteaseCredential
  ) async -> SearchGroup {
    do {
      return SearchGroup(
        scope: scope,
        result: .success(
          try await transport.search(
            keywords: keywords,
            scope: scope,
            limit: limit,
            offset: 0,
            credential: credential
          )
        )
      )
    } catch {
      return SearchGroup(
        scope: scope,
        result: .failure(OperationFailure.classify(error, cancelled: Task.isCancelled))
      )
    }
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
    results = scope.neteaseScope.map(SearchItems.empty) ?? .songs([])
    combinedResults = CombinedSearchResults()
    resultsKeywords = nil
    resultsHaveMore = false
    searchOffset = 0
    if queryChanged {
      cancelSuggestions()
      suggestions = []
    }
    status =
      currentSearchInput.keywords.isEmpty
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

  package func loadHotSearches(session: any SessionProviding) {
    read(
      in: search, identity: "hot-searches", operation: "Hot searches",
      loading: "Loading hot searches", report: { self.status = $0 },
      busy: { self.isSearching = $0 }, session: session, onStart: {},
      fetch: {
        try await self.transport.hotSearches(credential: $0)
      },
      apply: {
        self.hotSearches = $0
        return "Hot searches loaded"
      })
  }

  package func openSong(id: Int64, session: any SessionProviding) {
    read(
      in: detail, identity: "song-\(id)", operation: "Song", loading: "Loading song",
      report: { self.detailStatus = $0 }, busy: { self.isLoadingDetail = $0 }, session: session,
      onStart: { self.song = nil },
      fetch: {
        try await self.transport.songDetails(songIDs: [id], credential: $0)
      },
      apply: { tracks in
        self.song = tracks.first
        return tracks.isEmpty ? "This song is unavailable" : "Song loaded"
      })
  }

  package func loadArtistBiography(session: any SessionProviding) {
    guard let artist = artist?.artist else { return }
    read(
      in: detail, identity: "artist-biography-\(artist.id)", operation: "Artist biography",
      loading: "Loading biography", report: { self.detailStatus = $0 },
      busy: { self.isLoadingDetail = $0 }, session: session, onStart: {},
      fetch: {
        try await self.transport.artistBiography(artistID: artist.id, credential: $0)
      },
      apply: {
        self.artistBiography = $0
        return "Biography loaded"
      })
  }

  package func loadArtistSongs(
    all: Bool = false, playback: PlaybackController? = nil, startingAt songID: Int64? = nil,
    session: any SessionProviding
  ) {
    guard let artist = artist?.artist, artistSongsHaveMore || playback != nil else { return }
    let offset = artistSongOffset
    let held = artistSongs
    let initialMore = artistSongsHaveMore
    let playbackIntent = playback?.intentRevision
    read(
      in: detail, identity: "artist-songs-\(artist.id)-\(offset)-\(all)", operation: "Artist songs",
      loading: "Loading artist songs", report: { self.detailStatus = $0 },
      busy: { self.isLoadingDetail = $0 }, session: session, onStart: {},
      fetch: { credential in
        var songs = held
        var offset = offset
        var more = initialMore
        var pages = 0
        var seen = Set(held.map(\.id))
        while more {
          try Task.checkCancellation()
          guard pages < 1000 else { throw NeteaseCatalogError.invalidResponse }
          let page = try await self.transport.artistSongs(
            artistID: artist.id, limit: 100, offset: offset, credential: credential)
          try Task.checkCancellation()
          if let playbackIntent, playback?.intentRevision != playbackIntent {
            throw CancellationError()
          }
          songs += page.items.filter { seen.insert($0.id).inserted }
          offset += page.items.count
          more = page.more
          pages += 1
          self.detailStatus = "Loaded \(songs.count) songs"
          if !all { break }
        }
        return (songs, offset, more)
      },
      apply: { result in
        self.artistSongs = result.0
        self.artistSongOffset = result.1
        self.artistSongsHaveMore = result.2
        if let playback {
          guard playback.intentRevision == playbackIntent else {
            return "Playback changed while the songs were loading"
          }
          let start: Int
          if let songID {
            guard let index = result.0.firstIndex(where: { $0.id == songID }) else {
              return "This song is no longer available"
            }
            start = index
          } else {
            start = 0
          }
          let reserved = self.detail.token.flatMap { self.arbiter.transferRead($0) }
          self.detail.token = nil
          _ = playback.play(
            tracks: result.0, startIndex: start, context: .artist(id: artist.id, name: artist.name),
            session: session, reservedResolution: reserved)
        }
        return "Loaded \(result.0.count) songs"
      })
  }

  /// Opens an album: what is on it, and whether the account has collected it
  /// (2 requests).
  package func openAlbum(id albumID: Int64, session: any SessionProviding) {
    let membershipRevision = arbiter.writeRevision
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
        let pageGeneration = self.detail.generation
        guard let account = session.account else { throw CancellationError() }
        async let dynamic = self.transport.albumDynamic(albumID: albumID, credential: credential)
        let detail = try await self.transport.albumDetail(albumID: albumID, credential: credential)
        guard self.detail.accepts(pageGeneration), !Task.isCancelled,
          session.matchesValidatedSession(credential, account: account)
        else { throw CancellationError() }
        self.album = detail
        self.detailStatus = "Loaded \(detail.tracks.count) tracks; updating collection status"
        do { return (detail, try await dynamic as AlbumDynamic?) } catch is CancellationError {
          throw CancellationError()
        } catch { return (detail, nil as AlbumDynamic?) }
      },
      apply: { loaded in
        self.album = loaded.0
        self.albumDynamic = loaded.1
        if self.arbiter.writeRevision == membershipRevision, self.arbiter.active?.effect != .write,
          self.arbiter.active?.effect != .upload,
          let collected = loaded.1?.isCollected
        {
          self.onAlbumCollectionStateConfirmed?(albumID, collected)
        }
        return "Loaded \(loaded.0.tracks.count) tracks from \(loaded.0.album.name)"
          + (loaded.1 == nil ? "; collection status unavailable" : "")
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
        self.artistSongs = []
        self.artistSongsHaveMore = true
        self.artistSongOffset = 0
        self.artistBiography = nil
        self.artistAlbums = []
        self.artistAlbumsHaveMore = false
        self.artistAlbumOffset = 0
        self.album = nil
        self.albumDynamic = nil
      },
      fetch: { credential in
        let pageGeneration = self.detail.generation
        guard let account = session.account else { throw CancellationError() }
        async let albums = self.transport.artistAlbums(
          artistID: artistID, limit: Self.albumPageSize, offset: 0, credential: credential)
        let detail = try await self.transport.artistDetail(
          artistID: artistID, credential: credential)
        guard self.detail.accepts(pageGeneration), !Task.isCancelled,
          session.matchesValidatedSession(credential, account: account)
        else { throw CancellationError() }
        self.artist = detail
        self.detailStatus = "Loaded \(detail.hotSongs.count) top songs; loading albums"
        do { return (detail, try await albums as CatalogPage<Album>?) } catch is CancellationError {
          throw CancellationError()
        } catch { return (detail, nil as CatalogPage<Album>?) }
      },
      apply: { loaded in
        self.artist = loaded.0
        if let albums = loaded.1 {
          self.artistAlbums = Self.deduplicated(albums.items)
          self.artistAlbumOffset = albums.items.count
          self.artistAlbumsHaveMore = albums.more && !albums.items.isEmpty
        }
        return "Loaded \(loaded.0.hotSongs.count) top songs for \(loaded.0.artist.name)"
          + (loaded.1 == nil ? "; albums could not be loaded" : "")
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

  package func cancelDetail() {
    releaseLaneToken(detail)
    detail.cancel()
    isLoadingDetail = false
    detailStatus = "Loading cancelled"
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
    guard let account = session.account, session.isOnline else {
      report("Validate the session first")
      return
    }

    let identityGeneration = generation
    let laneGeneration = lane.begin(identity)
    onStart()
    busy(true)
    report(loading)
    lane.task = Task {
      guard let token = await arbiter.beginWhenAvailable(name: operation, effect: .read) else {
        if lane.accepts(laneGeneration) {
          busy(false)
          lane.finish(laneGeneration)
        }
        return
      }
      guard lane.accepts(laneGeneration), self.generation == identityGeneration, !Task.isCancelled
      else {
        arbiter.end(token, outcome: .cancelled)
        return
      }
      lane.token = token
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
    results = scope.neteaseScope.map(SearchItems.empty) ?? .songs([])
    combinedResults = CombinedSearchResults()
    resultsHaveMore = false
    resultsKeywords = nil
    searchOffset = 0
    suggestions = []
    defaultKeyword = nil
    hotSearches = []
    searchHistory = []
    song = nil
    artistSongs = []
    artistSongOffset = 0
    artistSongsHaveMore = true
    artistBiography = nil
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
