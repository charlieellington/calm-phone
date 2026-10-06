import CSQLite
import Foundation
import QuietCore
import XCTest

final class IntegrationTests: XCTestCase {
  func testGivenInitializedJournal_WhenMissingOrEmpty_ThenRepairWithoutFreshCreation() throws {
    for emptyReplacement in [false, true] {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      var database: ControlDatabase? = try ControlDatabase(directory: directory)
      database = nil
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("control.sqlite" + suffix))
      }
      let file = directory.appendingPathComponent("control.sqlite")
      if emptyReplacement { try Data().write(to: file) }
      XCTAssertThrowsError(try ControlDatabase(directory: directory))
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("installation.marker").path))
      if emptyReplacement {
        XCTAssertEqual(try Data(contentsOf: file).count, 0)
      } else {
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
      }
      XCTAssertNil(database)
    }
  }
  func testGivenLegacyJournal_WhenOpened_ThenMarkerAddedWithoutReset() throws {
    let h = try Harness()
    try h.setup()
    let before = try h.database.load()
    try FileManager.default.removeItem(at: h.directory.appendingPathComponent("installation.marker"))
    let reopened = try ControlDatabase(directory: h.directory)
    XCTAssertEqual(try reopened.load(), before)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: h.directory.appendingPathComponent("installation.marker").path))
  }
  func testGivenCorruptPayload_WhenOpened_ThenRepairWithoutRecreation() throws {
    let h = try Harness()
    var external: OpaquePointer?
    XCTAssertEqual(
      sqlite3_open(h.directory.appendingPathComponent("control.sqlite").path, &external), SQLITE_OK)
    defer { sqlite3_close(external) }
    XCTAssertEqual(sqlite3_exec(external, "UPDATE control SET payload=X'00FF'", nil, nil, nil), SQLITE_OK)
    XCTAssertThrowsError(try h.database.load())
    XCTAssertThrowsError(try ControlDatabase(directory: h.directory))
    var statement: OpaquePointer?
    XCTAssertEqual(
      sqlite3_prepare_v2(external, "SELECT length(payload) FROM control", -1, &statement, nil), SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
    XCTAssertEqual(sqlite3_column_int(statement, 0), 2)
  }
  func testGivenUnknownSchema_WhenOpened_ThenNeverMigratedOrReset() throws {
    let h = try Harness()
    var external: OpaquePointer?
    XCTAssertEqual(
      sqlite3_open(h.directory.appendingPathComponent("control.sqlite").path, &external), SQLITE_OK)
    defer { sqlite3_close(external) }
    XCTAssertEqual(sqlite3_exec(external, "PRAGMA user_version=999", nil, nil, nil), SQLITE_OK)
    XCTAssertThrowsError(try ControlDatabase(directory: h.directory))
    var statement: OpaquePointer?
    XCTAssertEqual(sqlite3_prepare_v2(external, "PRAGMA user_version", -1, &statement, nil), SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
    XCTAssertEqual(sqlite3_column_int(statement, 0), 999)
  }
  func testGivenSnapshotWriteFailure_WhenGrantRequested_ThenNoOpening() throws {
    let h = try Harness()
    try h.setup()
    let snapshot = h.directory.appendingPathComponent("widget.json")
    try FileManager.default.removeItem(at: snapshot)
    try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: false)
    XCTAssertThrowsError(try h.coordinator.grant(.quarterHour, authorization: h.authorization()))
    XCTAssertFalse(h.projections.contains { $0.isOpen })
    XCTAssertNil(try h.database.load().openLease?.activatedAt)
    try FileManager.default.removeItem(at: snapshot)
    try h.coordinator.reconcile()
    XCTAssertNil(try h.database.load().openLease)
  }
  func testGivenConcurrentWriters_WhenUpdating_ThenNoLostCommits() throws {
    let h = try Harness()
    let failures = NSLock()
    var errors = 0
    DispatchQueue.concurrentPerform(iterations: 8) { _ in
      do {
        let db = try ControlDatabase(directory: h.directory)
        for _ in 0..<20 { try db.update { $0.monitorFailed.toggle() } }
      } catch {
        failures.lock()
        errors += 1
        failures.unlock()
      }
    }
    XCTAssertEqual(errors, 0)
    XCTAssertEqual(try h.database.load().revision, 160)
  }
  func testGivenTransactionThrow_WhenReopened_ThenRollbackPreserved() throws {
    let h = try Harness()
    XCTAssertThrowsError(
      try h.database.update { state in
        state.setupComplete = true
        throw QuietError.unavailable
      })
    let reopened = try ControlDatabase(directory: h.directory)
    XCTAssertFalse(try reopened.load().setupComplete)
    XCTAssertEqual(try reopened.load().revision, 0)
  }
  func testGivenProjectionCrashBoundary_WhenReplayed_ThenDurableStateRemains() throws {
    let h = try Harness()
    XCTAssertThrowsError(
      try h.database.update({ $0.monitorFailed = true }, project: { _ in throw QuietError.unavailable }))
    let db = try ControlDatabase(directory: h.directory)
    XCTAssertTrue(try db.load().monitorFailed)
    var replayed = false
    try db.update({ _ in }, project: { replayed = $0.monitorFailed })
    XCTAssertTrue(replayed)
  }
  func testGivenDuplicateEndCallbacks_WhenReopened_ThenSingleInterval() throws {
    let h = try Harness()
    try h.setup()
    try h.coordinator.grant(.quarterHour, authorization: h.authorization())
    let lease = try XCTUnwrap(h.database.load().openLease)
    h.clock.now = h.clock.now.addingTimeInterval(120)
    try h.coordinator.callback(activity: lease.activityName, didEnd: true)
    try h.coordinator.callback(activity: lease.activityName, didEnd: true)
    let db = try ControlDatabase(directory: h.directory)
    XCTAssertEqual(try db.load().leases.count, 1)
    XCTAssertEqual(try db.load().leases[0].endedAt!.timeIntervalSince(lease.activatedAt!), 120)
  }
}
