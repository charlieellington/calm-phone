import CSQLite
import Darwin
import Foundation

/// The file lock includes the ManagedSettings/snapshot projection, not just the SQL write.
/// IPC with DeviceActivity is deliberately performed outside this scope.
public final class ControlDatabase {
  public let directory: URL
  private var connection: OpaquePointer?
  private let lockFD: Int32
  private let localLock = NSLock()
  public init(directory: URL) throws {
    self.directory = directory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    lockFD = open(directory.appendingPathComponent("writer.lock").path, O_CREAT | O_RDWR, 0o600)
    guard lockFD >= 0 else { throw QuietError.unavailable }
    do {
      try withLock {
        let marker = directory.appendingPathComponent("installation.marker")
        let databaseURL = directory.appendingPathComponent("control.sqlite")
        let priorInstallation =
          FileManager.default.fileExists(atPath: marker.path)
          || FileManager.default.fileExists(atPath: directory.appendingPathComponent("widget.json").path)
        if priorInstallation {
          guard let attributes = try? FileManager.default.attributesOfItem(atPath: databaseURL.path),
            let size = attributes[.size] as? NSNumber, size.int64Value > 0
          else { throw QuietError.repairRequired }
        }
        guard
          sqlite3_open_v2(
            databaseURL.path, &connection,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK
        else { throw QuietError.repairRequired }
        sqlite3_busy_timeout(connection, 2000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=FULL")
        try execute("PRAGMA foreign_keys=ON")
        let version = try integer("PRAGMA user_version")
        guard version == 0 || version == 1 else { throw QuietError.repairRequired }
        if version == 0 {
          // A pre-existing nonempty schema is not an invitation to replace control state.
          guard !priorInstallation,
            try integer("SELECT count(*) FROM sqlite_master WHERE type='table'") == 0
          else {
            throw QuietError.repairRequired
          }
          // Persist before creation: a crash must never turn initialized control into fresh setup.
          try markInstallation(marker)
          try execute("BEGIN IMMEDIATE")
          do {
            try execute(
              "CREATE TABLE control (singleton INTEGER PRIMARY KEY CHECK(singleton=1), payload BLOB NOT NULL)"
            )
            try write(ControlState())
            try execute("PRAGMA user_version=1")
            try execute("COMMIT")
          } catch {
            try? execute("ROLLBACK")
            throw error
          }
        }
        _ = try read()
        // Adopt valid journals created before the installation marker was introduced.
        if !FileManager.default.fileExists(atPath: marker.path) { try markInstallation(marker) }
      }
    } catch {
      sqlite3_close(connection)
      close(lockFD)
      throw error
    }
  }
  deinit {
    sqlite3_close(connection)
    close(lockFD)
  }

  private func markInstallation(_ url: URL) throws {
    try Data("quiet-control-v1\n".utf8).write(to: url, options: .atomic)
    let markerFD = open(url.path, O_RDONLY)
    guard markerFD >= 0 else { throw QuietError.repairRequired }
    defer { close(markerFD) }
    guard fsync(markerFD) == 0 else { throw QuietError.repairRequired }
    let directoryFD = open(directory.path, O_RDONLY)
    guard directoryFD >= 0 else { throw QuietError.repairRequired }
    defer { close(directoryFD) }
    guard fsync(directoryFD) == 0 else { throw QuietError.repairRequired }
  }

  private func withLock<T>(_ operation: () throws -> T) throws -> T {
    localLock.lock()
    defer { localLock.unlock() }
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    while flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
      guard errno == EWOULDBLOCK, ProcessInfo.processInfo.systemUptime < deadline else {
        throw QuietError.busy
      }
      usleep(10_000)
    }
    defer { flock(lockFD, LOCK_UN) }
    return try operation()
  }
  private func execute(_ sql: String) throws {
    guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw QuietError.repairRequired }
  }
  private func statement(_ sql: String) throws -> OpaquePointer {
    var result: OpaquePointer?
    guard sqlite3_prepare_v2(connection, sql, -1, &result, nil) == SQLITE_OK, let result else {
      throw QuietError.repairRequired
    }
    return result
  }
  private func integer(_ sql: String) throws -> Int {
    let s = try statement(sql)
    defer { sqlite3_finalize(s) }
    guard sqlite3_step(s) == SQLITE_ROW else { throw QuietError.repairRequired }
    return Int(sqlite3_column_int(s, 0))
  }
  private func read() throws -> ControlState {
    let s = try statement("SELECT payload FROM control WHERE singleton=1")
    defer { sqlite3_finalize(s) }
    guard sqlite3_step(s) == SQLITE_ROW, let bytes = sqlite3_column_blob(s, 0) else {
      throw QuietError.repairRequired
    }
    let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(s, 0)))
    do {
      let state = try JSONDecoder().decode(ControlState.self, from: data)
      if state.setupComplete && state.policy == nil { throw QuietError.repairRequired }
      try state.policy?.validate()
      try state.pendingPolicy?.validate()
      guard state.leases.filter({ $0.state == .pending || $0.state == .active }).count <= 1,
        Set(state.leases.map(\.id)).count == state.leases.count,
        state.leases.allSatisfy({
          $0.expiresAt > $0.requestedAt && ($0.state != .active || $0.activatedAt != nil)
        })
      else { throw QuietError.repairRequired }
      return state
    } catch { throw QuietError.repairRequired }
  }
  private func write(_ state: ControlState) throws {
    let bytes = try JSONEncoder().encode(state)
    let s = try statement(
      "INSERT INTO control(singleton,payload) VALUES(1,?) ON CONFLICT(singleton) DO UPDATE SET payload=excluded.payload"
    )
    defer { sqlite3_finalize(s) }
    let status = bytes.withUnsafeBytes {
      sqlite3_bind_blob(
        s, 1, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    guard status == SQLITE_OK, sqlite3_step(s) == SQLITE_DONE else { throw QuietError.repairRequired }
  }
  public func load() throws -> ControlState { try withLock { try read() } }
  @discardableResult
  public func update<T>(
    _ change: (inout ControlState) throws -> T,
    project: (ControlState) throws -> Void = { _ in }
  ) throws -> T {
    try withLock {
      try execute("BEGIN IMMEDIATE")
      let result: T
      var state: ControlState
      do {
        state = try read()
        result = try change(&state)
        state.revision += 1
        try write(state)
        try execute("COMMIT")
      } catch {
        try? execute("ROLLBACK")
        throw error
      }
      // A crash here leaves durable desired state; a registered monitor/foreground replays it.
      try project(state)
      return result
    }
  }
  public func writeSnapshot(_ snapshot: WidgetSnapshot) throws {
    try JSONEncoder().encode(snapshot).write(
      to: directory.appendingPathComponent("widget.json"), options: .atomic)
  }
  public static func readSnapshot(directory: URL) throws -> WidgetSnapshot {
    try JSONDecoder().decode(
      WidgetSnapshot.self, from: Data(contentsOf: directory.appendingPathComponent("widget.json")))
  }
}
