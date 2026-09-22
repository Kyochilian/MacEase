import Foundation
import NeteaseKit
import SQLite3

/// Per-account storage for the library, the playback queue and where playback
/// had got to.
///
/// The roadmap named GRDB for this. It is not used: what this app stores is a
/// handful of rows keyed by account, read whole at launch and written whole on
/// change, which the SQLite that ships with macOS already serves. That is also
/// the project's own order of preference, which puts Apple's own frameworks
/// ahead of a new dependency. Revisit if a feature arrives that genuinely
/// needs a query planner rather than a key and a blob.
///
/// Every row is scoped by account id. Signing in as someone else must never
/// show the previous account's library, so the account is part of the key
/// rather than something the caller is trusted to filter on.
package actor LibraryStore {
  /// The connection is opened `FULLMUTEX`, so SQLite serialises access to it
  /// itself. The pointer never changes after `init`, which is what lets
  /// `deinit` close it from outside the actor.
  private nonisolated(unsafe) let handle: OpaquePointer

  /// Set by `failNextWriteForTesting`, cleared by the write it refuses.
  private var injectedWriteFailure: Int32?

  /// Opens, or creates, the database at `url`. Pass
  /// `LibraryStore.inMemoryPath` for a store that leaves nothing behind.
  package static let inMemoryPath = ":memory:"

  package init(path: String) throws {
    var handle: OpaquePointer?
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    let status = sqlite3_open_v2(path, &handle, flags, nil)
    guard status == SQLITE_OK, let handle else {
      if let handle { sqlite3_close_v2(handle) }
      throw LibraryStoreError.sqlite(status)
    }
    self.handle = handle
    try Self.execute("PRAGMA journal_mode=WAL", on: handle)
    try Self.execute("PRAGMA foreign_keys=ON", on: handle)
    try Self.migrate(handle)
  }

  deinit {
    sqlite3_close_v2(handle)
  }

  /// The file the app uses. Application Support rather than Caches: a queue
  /// the user expects to find on relaunch is not something the system may
  /// delete to reclaim space.
  ///
  /// A directory that cannot be created is reported rather than swallowed.
  /// Handing back a path inside a directory that is not there would turn one
  /// diagnosable failure into an unexplained failure on every later write.
  package static func defaultPath() throws -> String {
    guard
      let base = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first
    else { throw LibraryStoreError.noApplicationSupportDirectory }
    let directory = base.appendingPathComponent("MacEase", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    return directory.appendingPathComponent("library.sqlite").path
  }

  /// A short account of a storage failure, for showing the user.
  ///
  /// Persistence is a convenience — losing it costs the resume point, not the
  /// app — but a failure must be visible rather than being mistaken for a save
  /// that worked.
  package static func diagnostic(for error: any Error) -> String {
    guard let error = error as? LibraryStoreError else {
      return (error as NSError).localizedDescription
    }
    switch error {
    case .sqlite(let code):
      return "SQLite \(code): \(String(cString: sqlite3_errstr(code)))"
    case .corruptRow:
      return "a stored row did not decode"
    case .noApplicationSupportDirectory:
      return "there is no Application Support directory"
    }
  }

  /// Test seam: refuses the next write with a real SQLite result code, so
  /// "a write that failed is retried rather than remembered" can be proved
  /// without a filesystem the test would have to break on purpose.
  package func failNextWriteForTesting(code: Int32 = SQLITE_IOERR) {
    injectedWriteFailure = code
  }

  private func failIfInjected() throws {
    guard let code = injectedWriteFailure else { return }
    injectedWriteFailure = nil
    throw LibraryStoreError.sqlite(code)
  }

  // MARK: - Playlists

  package func savePlaylists(_ playlists: [UserPlaylist], accountID: Int64) throws {
    try failIfInjected()
    try transaction {
      try run(
        "DELETE FROM playlist WHERE account_id = ?",
        bind: { try bind(int: accountID, at: 1, to: $0) }
      )
      for (position, playlist) in playlists.enumerated() {
        try run(
          """
          INSERT INTO playlist
            (account_id, playlist_id, name, track_count, owned, position, metadata)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          """,
          bind: { statement in
            try bind(int: accountID, at: 1, to: statement)
            try bind(int: playlist.id, at: 2, to: statement)
            try bind(text: playlist.name, at: 3, to: statement)
            try bind(int: Int64(playlist.trackCount), at: 4, to: statement)
            try bind(int: playlist.owned ? 1 : 0, at: 5, to: statement)
            try bind(int: Int64(position), at: 6, to: statement)
            try bind(blob: JSONEncoder().encode(playlist), at: 7, to: statement)
          }
        )
      }
    }
  }

  package func playlists(accountID: Int64) throws -> [UserPlaylist] {
    var result: [UserPlaylist] = []
    try query(
      """
      SELECT playlist_id, name, track_count, owned, metadata FROM playlist
      WHERE account_id = ? ORDER BY position ASC
      """,
      bind: { try bind(int: accountID, at: 1, to: $0) },
      row: { statement in
        if let data = Self.data(statement, column: 4) {
          let playlist = try JSONDecoder().decode(UserPlaylist.self, from: data)
          guard playlist.id == sqlite3_column_int64(statement, 0), playlist.id > 0,
            playlist.trackCount >= 0
          else { throw LibraryStoreError.corruptRow }
          result.append(playlist)
          return
        }
        guard let name = Self.text(statement, column: 1) else {
          throw LibraryStoreError.corruptRow
        }
        result.append(
          UserPlaylist(
            id: sqlite3_column_int64(statement, 0),
            name: name,
            trackCount: Int(sqlite3_column_int64(statement, 2)),
            owned: sqlite3_column_int64(statement, 3) != 0,
            // The existing schema never stored privacy. Unknown is the safe
            // restore value until the next authoritative server load.
            isPrivate: nil
          )
        )
      }
    )
    return result
  }

  // MARK: - Queue

  /// Replaces the stored queue. There is exactly one per account: a second
  /// queue would be a second answer to "what was I listening to".
  package func saveQueue(_ queue: PersistedQueue, accountID: Int64) throws {
    try failIfInjected()
    let payload = try JSONEncoder().encode(queue)
    try run(
      """
      INSERT INTO queue (account_id, payload) VALUES (?, ?)
      ON CONFLICT(account_id) DO UPDATE SET payload = excluded.payload
      """,
      bind: { statement in
        try bind(int: accountID, at: 1, to: statement)
        try bind(blob: payload, at: 2, to: statement)
      }
    )
  }

  /// Removes only this account's resume queue. Playlists and every other
  /// account remain untouched.
  package func clearQueue(accountID: Int64) throws {
    try failIfInjected()
    try run(
      "DELETE FROM queue WHERE account_id = ?",
      bind: { try bind(int: accountID, at: 1, to: $0) }
    )
  }

  /// The stored queue, or nil when there is none.
  ///
  /// A payload that no longer decodes returns nil rather than throwing: the
  /// only thing lost is a resume point, and refusing to start the app because
  /// an old schema is on disk would be a worse answer than starting fresh.
  package func queue(accountID: Int64) throws -> PersistedQueue? {
    var payload: Data?
    try query(
      "SELECT payload FROM queue WHERE account_id = ?",
      bind: { try bind(int: accountID, at: 1, to: $0) },
      row: { statement in
        guard
          let bytes = sqlite3_column_blob(statement, 0),
          case let count = sqlite3_column_bytes(statement, 0),
          count > 0
        else { return }
        payload = Data(bytes: bytes, count: Int(count))
      }
    )
    guard let payload else { return nil }
    return try? JSONDecoder().decode(PersistedQueue.self, from: payload)
  }

  /// Test seam: writes bytes no current build would write, so the "an older
  /// schema must not stop the app launching" rule can be exercised.
  package func writeRawQueuePayloadForTesting(
    _ payload: Data,
    accountID: Int64
  ) throws {
    try run(
      """
      INSERT INTO queue (account_id, payload) VALUES (?, ?)
      ON CONFLICT(account_id) DO UPDATE SET payload = excluded.payload
      """,
      bind: { statement in
        try bind(int: accountID, at: 1, to: statement)
        try bind(blob: payload, at: 2, to: statement)
      }
    )
  }

  // MARK: - Offline downloads

  package func saveDownload(_ download: OfflineDownload) throws {
    try failIfInjected()
    let track = try JSONEncoder().encode(download.track)
    try run(
      """
      INSERT INTO download (
        account_id, song_id, requested_quality, actual_quality, format,
        byte_count, relative_path, track, created_at, verified_complete
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(account_id, song_id, requested_quality) DO UPDATE SET
        actual_quality = excluded.actual_quality,
        format = excluded.format,
        byte_count = excluded.byte_count,
        relative_path = excluded.relative_path,
        track = excluded.track,
        created_at = excluded.created_at,
        verified_complete = excluded.verified_complete
      """,
      bind: { statement in
        try bind(int: download.accountID, at: 1, to: statement)
        try bind(int: download.track.id, at: 2, to: statement)
        try bind(text: download.requestedQuality.rawValue, at: 3, to: statement)
        try bind(text: download.actualQuality, at: 4, to: statement)
        try bind(text: download.format, at: 5, to: statement)
        try bind(int: download.byteCount, at: 6, to: statement)
        try bind(text: download.relativePath, at: 7, to: statement)
        try bind(blob: track, at: 8, to: statement)
        try bind(
          int: Int64(download.createdAt.timeIntervalSince1970),
          at: 9,
          to: statement
        )
        try bind(int: download.isVerifiedComplete ? 1 : 0, at: 10, to: statement)
      }
    )
  }

  package func downloads(accountID: Int64) throws -> StoredDownloads {
    var result: [OfflineDownload] = []
    var corruptRowIDs: [Int64] = []
    try query(
      """
      SELECT rowid, song_id, requested_quality, actual_quality, format,
             byte_count, relative_path, track, created_at, verified_complete
      FROM download WHERE account_id = ? ORDER BY created_at DESC
      """,
      bind: { try bind(int: accountID, at: 1, to: $0) },
      row: { statement in
        let rowID = sqlite3_column_int64(statement, 0)
        guard
          let requestedValue = Self.text(statement, column: 2),
          let requested = PlaybackQuality(rawValue: requestedValue),
          let actual = Self.text(statement, column: 3), !actual.isEmpty,
          let format = Self.text(statement, column: 4), !format.isEmpty,
          case let byteCount = sqlite3_column_int64(statement, 5),
          byteCount > 0,
          let relativePath = Self.text(statement, column: 6),
          !relativePath.isEmpty,
          let trackData = Self.data(statement, column: 7),
          let track = try? JSONDecoder().decode(Track.self, from: trackData),
          track.id == sqlite3_column_int64(statement, 1)
        else {
          corruptRowIDs.append(rowID)
          return
        }
        result.append(
          OfflineDownload(
            accountID: accountID,
            track: track,
            requestedQuality: requested,
            actualQuality: actual,
            format: format,
            byteCount: byteCount,
            relativePath: relativePath,
            createdAt: Date(
              timeIntervalSince1970: TimeInterval(
                sqlite3_column_int64(statement, 8)
              )
            ),
            isVerifiedComplete: sqlite3_column_int64(statement, 9) == 1
          )
        )
      }
    )
    for rowID in corruptRowIDs {
      try run(
        "DELETE FROM download WHERE rowid = ?",
        bind: { try bind(int: rowID, at: 1, to: $0) }
      )
    }
    return StoredDownloads(
      downloads: result,
      discardedCorruptRows: corruptRowIDs.count
    )
  }

  package func deleteDownload(_ id: OfflineDownloadID) throws {
    try failIfInjected()
    try run(
      """
      DELETE FROM download
      WHERE account_id = ? AND song_id = ? AND requested_quality = ?
      """,
      bind: { statement in
        try bind(int: id.accountID, at: 1, to: statement)
        try bind(int: id.songID, at: 2, to: statement)
        try bind(text: id.requestedQuality.rawValue, at: 3, to: statement)
      }
    )
  }

  package func clearDownloads(accountID: Int64) throws {
    try failIfInjected()
    try run(
      "DELETE FROM download WHERE account_id = ?",
      bind: { try bind(int: accountID, at: 1, to: $0) }
    )
  }

  // MARK: - Schema

  private static func migrate(_ handle: OpaquePointer) throws {
    try execute(
      """
      CREATE TABLE IF NOT EXISTS playlist (
        account_id  INTEGER NOT NULL,
        playlist_id INTEGER NOT NULL,
        name        TEXT    NOT NULL,
        track_count INTEGER NOT NULL,
        owned       INTEGER NOT NULL,
        position    INTEGER NOT NULL,
        PRIMARY KEY (account_id, playlist_id)
      )
      """,
      on: handle
    )
    try execute(
      """
      CREATE TABLE IF NOT EXISTS queue (
        account_id INTEGER PRIMARY KEY,
        payload    BLOB NOT NULL
      )
      """,
      on: handle
    )
    try execute(
      """
      CREATE TABLE IF NOT EXISTS download (
        account_id         INTEGER NOT NULL,
        song_id            INTEGER NOT NULL,
        requested_quality  TEXT    NOT NULL,
        actual_quality     TEXT    NOT NULL,
        format             TEXT    NOT NULL,
        byte_count         INTEGER NOT NULL,
        relative_path      TEXT    NOT NULL,
        track              BLOB    NOT NULL,
        created_at         INTEGER NOT NULL,
        PRIMARY KEY (account_id, song_id, requested_quality)
      )
      """,
      on: handle
    )
    try ensureColumn(
      "verified_complete", definition: "INTEGER NOT NULL DEFAULT 0", table: "download", on: handle)
    try ensureColumn("metadata", definition: "BLOB", table: "playlist", on: handle)
    try execute(
      "CREATE TABLE IF NOT EXISTS lyric (account_id INTEGER NOT NULL, song_id INTEGER NOT NULL, "
        + "payload BLOB, offset_ms INTEGER NOT NULL DEFAULT 0, version INTEGER NOT NULL DEFAULT 1, "
        + "PRIMARY KEY(account_id, song_id))", on: handle
    )
    try execute(
      "CREATE TABLE IF NOT EXISTS listening_history (account_id INTEGER NOT NULL, event_id TEXT NOT NULL, played_at INTEGER NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(account_id, event_id))",
      on: handle)
    try execute(
      "CREATE TABLE IF NOT EXISTS search_history (account_id INTEGER NOT NULL, query TEXT NOT NULL, used_at INTEGER NOT NULL, PRIMARY KEY(account_id, query))",
      on: handle)
  }

  private static func ensureColumn(
    _ column: String, definition: String, table: String, on handle: OpaquePointer
  ) throws {
    var exists = false
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(handle, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK
    else { throw LibraryStoreError.sqlite(sqlite3_errcode(handle)) }
    while sqlite3_step(statement) == SQLITE_ROW {
      if let name = sqlite3_column_text(statement, 1), String(cString: name) == column {
        exists = true
      }
    }
    sqlite3_finalize(statement)
    if !exists {
      try execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)", on: handle)
    }
  }

  package func saveLyrics(_ lyrics: Lyrics, accountID: Int64, songID: Int64) throws {
    let payload = try JSONEncoder().encode(lyrics)
    guard payload.count <= LyricsParser.maximumResponseBytes else {
      throw LibraryStoreError.corruptRow
    }
    try run(
      "INSERT INTO lyric(account_id, song_id, payload) VALUES (?, ?, ?) "
        + "ON CONFLICT(account_id, song_id) DO UPDATE SET payload = excluded.payload, version = 1",
      bind: {
        try bind(int: accountID, at: 1, to: $0)
        try bind(int: songID, at: 2, to: $0)
        try bind(blob: payload, at: 3, to: $0)
      }
    )
  }

  package func savedLyrics(accountID: Int64, songID: Int64) throws -> (
    document: Lyrics?, offset: Double
  ) {
    var result: (document: Lyrics?, offset: Double) = (nil, 0)
    try query(
      "SELECT payload, offset_ms, version FROM lyric WHERE account_id = ? AND song_id = ?",
      bind: {
        try bind(int: accountID, at: 1, to: $0)
        try bind(int: songID, at: 2, to: $0)
      },
      row: { statement in
        let offset = sqlite3_column_int64(statement, 1)
        guard (-30_000...30_000).contains(offset), sqlite3_column_int64(statement, 2) == 1 else {
          throw LibraryStoreError.corruptRow
        }
        result.offset = Double(offset) / 1000
        if let data = Self.data(statement, column: 0) {
          guard data.count <= LyricsParser.maximumResponseBytes else {
            throw LibraryStoreError.corruptRow
          }
          let document = try JSONDecoder().decode(Lyrics.self, from: data)
          let lines = document.lines
          guard lines.count <= 10_000,
            zip(lines, lines.dropFirst()).allSatisfy({ $0.timeSeconds <= $1.timeSeconds }),
            lines.allSatisfy({ line in
              line.timeSeconds.isFinite && line.timeSeconds >= 0 && line.words.count <= 100_000
                && line.words.allSatisfy {
                  $0.startSeconds.isFinite && $0.startSeconds >= line.timeSeconds
                    && $0.durationSeconds.isFinite && $0.durationSeconds >= 0
                }
                && zip(line.words, line.words.dropFirst()).allSatisfy {
                  $0.endSeconds <= $1.startSeconds
                }
            })
          else { throw LibraryStoreError.corruptRow }
          result.document = document
        }
      }
    )
    return result
  }

  package func saveLyricOffset(_ offset: Double, accountID: Int64, songID: Int64) throws {
    guard offset.isFinite, (-30...30).contains(offset) else { throw LibraryStoreError.corruptRow }
    try run(
      "INSERT INTO lyric(account_id, song_id, offset_ms) VALUES (?, ?, ?) "
        + "ON CONFLICT(account_id, song_id) DO UPDATE SET offset_ms = excluded.offset_ms",
      bind: {
        try bind(int: accountID, at: 1, to: $0)
        try bind(int: songID, at: 2, to: $0)
        try bind(int: Int64((offset * 1000).rounded()), at: 3, to: $0)
      }
    )
  }

  package func saveListeningHistory(_ entry: ListeningHistoryEntry, accountID: Int64) throws {
    let data = try JSONEncoder().encode(entry)
    try transaction {
      try run(
        "INSERT OR IGNORE INTO listening_history(account_id, event_id, played_at, payload) VALUES (?, ?, ?, ?)",
        bind: {
          try bind(int: accountID, at: 1, to: $0)
          try bind(text: entry.id.uuidString, at: 2, to: $0)
          try bind(int: Int64(entry.playedAt.timeIntervalSince1970 * 1000), at: 3, to: $0)
          try bind(blob: data, at: 4, to: $0)
        })
      try run(
        "DELETE FROM listening_history WHERE account_id = ? AND rowid NOT IN (SELECT rowid FROM listening_history WHERE account_id = ? ORDER BY played_at DESC, rowid DESC LIMIT 1000)",
        bind: {
          try bind(int: accountID, at: 1, to: $0)
          try bind(int: accountID, at: 2, to: $0)
        })
    }
  }

  package func listeningHistory(accountID: Int64) throws -> [ListeningHistoryEntry] {
    var entries: [ListeningHistoryEntry] = []
    try query(
      "SELECT payload FROM listening_history WHERE account_id = ? ORDER BY played_at DESC, rowid DESC LIMIT 1000",
      bind: {
        try bind(int: accountID, at: 1, to: $0)
      },
      row: {
        guard let data = Self.data($0, column: 0), data.count <= 1_000_000 else {
          throw LibraryStoreError.corruptRow
        }
        let entry = try JSONDecoder().decode(ListeningHistoryEntry.self, from: data)
        guard entry.track.id > 0, entry.playedAt.timeIntervalSince1970.isFinite else {
          throw LibraryStoreError.corruptRow
        }
        entries.append(entry)
      })
    return entries
  }

  package func saveSearch(_ query: String, accountID: Int64) throws {
    guard !query.isEmpty, query.count <= 1000 else { return }
    try transaction {
      try run(
        "INSERT INTO search_history(account_id, query, used_at) VALUES (?, ?, ?) ON CONFLICT(account_id, query) DO UPDATE SET used_at = excluded.used_at",
        bind: {
          try bind(int: accountID, at: 1, to: $0)
          try bind(text: query, at: 2, to: $0)
          try bind(int: Int64(Date().timeIntervalSince1970 * 1_000_000), at: 3, to: $0)
        })
      try run(
        "DELETE FROM search_history WHERE account_id = ? AND rowid NOT IN (SELECT rowid FROM search_history WHERE account_id = ? ORDER BY used_at DESC LIMIT 50)",
        bind: {
          try bind(int: accountID, at: 1, to: $0)
          try bind(int: accountID, at: 2, to: $0)
        })
    }
  }

  package func searchHistory(accountID: Int64) throws -> [String] {
    var queries: [String] = []
    try query(
      "SELECT query FROM search_history WHERE account_id = ? ORDER BY used_at DESC LIMIT 50",
      bind: {
        try bind(int: accountID, at: 1, to: $0)
      }, row: { if let query = Self.text($0, column: 0) { queries.append(query) } })
    return queries
  }

  package func clearSearchHistory(accountID: Int64) throws {
    try run(
      "DELETE FROM search_history WHERE account_id = ?",
      bind: { try bind(int: accountID, at: 1, to: $0) })
  }

  // MARK: - SQLite plumbing

  /// `COMMIT` is inside the `do`, so a commit that fails rolls back and
  /// reports its own error rather than leaving the connection in a
  /// transaction nobody closed.
  private func transaction(_ body: () throws -> Void) throws {
    try Self.execute("BEGIN IMMEDIATE", on: handle)
    do {
      try body()
      try Self.execute("COMMIT", on: handle)
    } catch {
      // Best effort: the failure being reported is the one that matters, and
      // a rollback that also fails leaves the connection to be discarded.
      try? Self.execute("ROLLBACK", on: handle)
      throw error
    }
  }

  private func run(
    _ sql: String,
    bind: (OpaquePointer) throws -> Void
  ) throws {
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    try bind(statement)
    let status = sqlite3_step(statement)
    guard status == SQLITE_DONE else { throw LibraryStoreError.sqlite(status) }
  }

  private func query(
    _ sql: String,
    bind: (OpaquePointer) throws -> Void,
    row: (OpaquePointer) throws -> Void
  ) throws {
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    try bind(statement)
    while true {
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { return }
      guard status == SQLITE_ROW else { throw LibraryStoreError.sqlite(status) }
      try row(statement)
    }
  }

  private func prepare(_ sql: String) throws -> OpaquePointer {
    var statement: OpaquePointer?
    let status = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
    guard status == SQLITE_OK, let statement else {
      if let statement { sqlite3_finalize(statement) }
      throw LibraryStoreError.sqlite(status)
    }
    return statement
  }

  private func bind(int value: Int64, at index: Int32, to statement: OpaquePointer) throws {
    let status = sqlite3_bind_int64(statement, index, value)
    guard status == SQLITE_OK else { throw LibraryStoreError.sqlite(status) }
  }

  /// `SQLITE_TRANSIENT` tells SQLite to copy the bytes, which it must: the
  /// Swift string backing them does not outlive this call.
  private func bind(text value: String, at index: Int32, to statement: OpaquePointer) throws {
    let status = sqlite3_bind_text(statement, index, value, -1, Self.transient)
    guard status == SQLITE_OK else { throw LibraryStoreError.sqlite(status) }
  }

  private func bind(blob value: Data, at index: Int32, to statement: OpaquePointer) throws {
    let status = value.withUnsafeBytes { buffer in
      sqlite3_bind_blob(
        statement,
        index,
        buffer.baseAddress,
        Int32(buffer.count),
        Self.transient
      )
    }
    guard status == SQLITE_OK else { throw LibraryStoreError.sqlite(status) }
  }

  private static let transient = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
  )

  private static func text(_ statement: OpaquePointer, column: Int32) -> String? {
    guard let bytes = sqlite3_column_text(statement, column) else { return nil }
    return String(cString: bytes)
  }

  private static func data(_ statement: OpaquePointer, column: Int32) -> Data? {
    guard
      let bytes = sqlite3_column_blob(statement, column),
      case let count = sqlite3_column_bytes(statement, column),
      count > 0
    else { return nil }
    return Data(bytes: bytes, count: Int(count))
  }

  private static func execute(_ sql: String, on handle: OpaquePointer) throws {
    let status = sqlite3_exec(handle, sql, nil, nil, nil)
    guard status == SQLITE_OK else { throw LibraryStoreError.sqlite(status) }
  }
}
