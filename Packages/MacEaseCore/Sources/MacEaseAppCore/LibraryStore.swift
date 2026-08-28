import Foundation
import NeteaseKit
import SQLite3

/// Per-account storage for the library, the playback queue and where playback
/// had got to.
///
/// The roadmap named GRDB for this. It is not used: its package pulls a git
/// submodule from a host this build environment cannot reach, and the storage
/// this app actually needs — a handful of rows keyed by account, read whole at
/// launch and written whole on change — is served by the SQLite that ships
/// with macOS. That also keeps the project's own rule, which puts Apple's own
/// frameworks ahead of a new dependency. Revisit if a feature arrives that
/// genuinely needs a query planner rather than a key and a blob.
///
/// Every row is scoped by account id. Signing in as someone else must never
/// show the previous account's library, so the account is part of the key
/// rather than something the caller is trusted to filter on.
package actor LibraryStore {
  /// The connection is opened `FULLMUTEX`, so SQLite serialises access to it
  /// itself. The pointer never changes after `init`, which is what lets
  /// `deinit` close it from outside the actor.
  private nonisolated(unsafe) let handle: OpaquePointer

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
  package static func defaultPath() -> String? {
    guard
      let base = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first
    else { return nil }
    let directory = base.appendingPathComponent("MacEase", isDirectory: true)
    try? FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    return directory.appendingPathComponent("library.sqlite").path
  }

  // MARK: - Playlists

  package func savePlaylists(_ playlists: [UserPlaylist], accountID: Int64) throws {
    try transaction {
      try run(
        "DELETE FROM playlist WHERE account_id = ?",
        bind: { try bind(int: accountID, at: 1, to: $0) }
      )
      for (position, playlist) in playlists.enumerated() {
        try run(
          """
          INSERT INTO playlist
            (account_id, playlist_id, name, track_count, owned, position)
          VALUES (?, ?, ?, ?, ?, ?)
          """,
          bind: { statement in
            try bind(int: accountID, at: 1, to: statement)
            try bind(int: playlist.id, at: 2, to: statement)
            try bind(text: playlist.name, at: 3, to: statement)
            try bind(int: Int64(playlist.trackCount), at: 4, to: statement)
            try bind(int: playlist.owned ? 1 : 0, at: 5, to: statement)
            try bind(int: Int64(position), at: 6, to: statement)
          }
        )
      }
    }
  }

  package func playlists(accountID: Int64) throws -> [UserPlaylist] {
    var result: [UserPlaylist] = []
    try query(
      """
      SELECT playlist_id, name, track_count, owned FROM playlist
      WHERE account_id = ? ORDER BY position ASC
      """,
      bind: { try bind(int: accountID, at: 1, to: $0) },
      row: { statement in
        guard let name = Self.text(statement, column: 1) else {
          throw LibraryStoreError.corruptRow
        }
        result.append(
          UserPlaylist(
            id: sqlite3_column_int64(statement, 0),
            name: name,
            trackCount: Int(sqlite3_column_int64(statement, 2)),
            owned: sqlite3_column_int64(statement, 3) != 0
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

  package func clearQueue(accountID: Int64) throws {
    try run(
      "DELETE FROM queue WHERE account_id = ?",
      bind: { try bind(int: accountID, at: 1, to: $0) }
    )
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

  /// Everything this account had. Used when the user signs out or the stored
  /// identity is replaced.
  package func clear(accountID: Int64) throws {
    try transaction {
      try run(
        "DELETE FROM playlist WHERE account_id = ?",
        bind: { try bind(int: accountID, at: 1, to: $0) }
      )
      try run(
        "DELETE FROM queue WHERE account_id = ?",
        bind: { try bind(int: accountID, at: 1, to: $0) }
      )
    }
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
  }

  // MARK: - SQLite plumbing

  private func transaction(_ body: () throws -> Void) throws {
    try Self.execute("BEGIN IMMEDIATE", on: handle)
    do {
      try body()
    } catch {
      // Best effort: the failure being reported is the one that matters, and
      // a rollback that also fails leaves the connection to be discarded.
      try? Self.execute("ROLLBACK", on: handle)
      throw error
    }
    try Self.execute("COMMIT", on: handle)
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

  private static func execute(_ sql: String, on handle: OpaquePointer) throws {
    let status = sqlite3_exec(handle, sql, nil, nil, nil)
    guard status == SQLITE_OK else { throw LibraryStoreError.sqlite(status) }
  }
}
