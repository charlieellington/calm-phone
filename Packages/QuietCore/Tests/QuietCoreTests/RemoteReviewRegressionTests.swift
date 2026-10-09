// Review starter tests, not installed in the app target.
// Public remote-unlock regression coverage.
// Uses the existing Harness, TestClock, pair, FixedRandom and MemoryRemotes fixtures.
// At reviewed commit 3049712: three fail and three pass. See review.md before using.
import Foundation
import QuietCore
import XCTest

final class RemoteReviewRegressionTests: XCTestCase {
  func testSpentLinkCannotGrantAgainAfterPruningAndClockRollback() throws {
    let h = try Harness()
    try h.setup()
    let p = try pair(clock: h.clock)
    let start = h.clock.now
    let first = try p.link(at: start)
    let verified = try p.verifier.verify(first)
    try h.coordinator.grant(
      GrantDraft.prepare(first.choice, now: h.clock.now), authorization: verified.authorization)
    try h.coordinator.lockNow()

    // A later legitimate link prunes the older spent nonce.
    h.clock.now = start + 800
    let later = try p.link(at: h.clock.now)
    let next = try p.verifier.verify(later)
    try h.coordinator.grant(
      GrantDraft.prepare(later.choice, now: h.clock.now), authorization: next.authorization)
    try h.coordinator.lockNow()

    // Moving the wall clock back must not make the first, spent link usable again.
    h.clock.now = start + 300
    do {
      let replayed = try p.verifier.verify(first)
      try h.coordinator.grant(
        GrantDraft.prepare(first.choice, now: h.clock.now), authorization: replayed.authorization)
      XCTFail("The same spent link granted a second lease after a wall-clock rollback.")
    } catch {
      XCTAssertNil(try h.database.load().openLease)
    }
  }

  func testReAddingRemoteReplacesTheOldConnectionForThatPhone() throws {
    let clock = TestClock()
    var p = try pair(clock: clock)
    var record = try XCTUnwrap(p.store.record)
    record.remove(id: p.remote.id)
    let replacement = try record.add(
      name: "Helper", ownerName: "Owner", now: clock.now, random: p.random.bytes)
    try p.connections.connect(record.connectToken(for: replacement), now: clock.now)

    // The receiver must not be left choosing between two indistinguishable Owners.
    // Implement with stable phone identity; never deduplicate solely by ownerName.
    XCTAssertEqual(p.connections.connections.map(\.id), [replacement.id])
  }

  func testFailedGrantDoesNotRecordASuccessfulLastUnlock() throws {
    let h = try Harness()
    try h.setup()
    let p = try pair(clock: h.clock)
    let token = try p.link(at: h.clock.now)
    let verified = try p.verifier.verify(token)
    h.scheduler.fail = true
    XCTAssertThrowsError(
      try h.coordinator.grant(
        GrantDraft.prepare(token.choice, now: h.clock.now), authorization: verified.authorization))
    XCTAssertNil(try h.database.load().openLease)
    XCTAssertFalse(h.projections.last!.isOpen)
    XCTAssertEqual(p.store.record?.usedNonces.count, 1, "Failure must still leave the link spent.")
    // Proposed spec amendment: Last unlock describes actual access, not an attempted grant.
    XCTAssertNil(p.store.record?.remotes.first?.lastUnlockAt)
  }

  func testFailedNonceWriteReturnsNoAuthorizationAndCanBeRetried() throws {
    let clock = TestClock()
    let p = try pair(clock: clock)
    let store = RejectingRemoteWrites(record: try XCTUnwrap(p.store.record))
    let verifier = RemoteVerifier(store: store, clock: { clock.now })
    let token = try p.link(at: clock.now)
    store.rejectWrites = true
    XCTAssertThrowsError(try verifier.verify(token))
    XCTAssertEqual(store.record.usedNonces, [])
    XCTAssertNil(store.record.remotes.first?.lastUnlockAt)

    store.rejectWrites = false
    XCTAssertNoThrow(try verifier.verify(token))
    XCTAssertEqual(store.record.usedNonces.count, 1)
  }

  func testSerializedSpentNonceSurvivesANewVerifier() throws {
    let clock = TestClock()
    let p = try pair(clock: clock)
    let token = try p.link(at: clock.now)
    _ = try p.verifier.verify(token)
    let saved = try JSONEncoder().encode(XCTUnwrap(p.store.record))
    let reloaded = MemoryRemotes()
    reloaded.record = try JSONDecoder().decode(RemoteRecord.self, from: saved)
    let restarted = RemoteVerifier(store: reloaded, clock: { clock.now })
    XCTAssertThrowsError(try restarted.verify(token)) {
      XCTAssertEqual($0 as? RemoteError, .alreadyUsed)
    }
  }

  func testDifferentPhonesWithTheSameOwnerNameRemainSeparate() throws {
    let clock = TestClock()
    let random = FixedRandom()
    var first = RemoteRecord()
    var second = RemoteRecord()
    let a = try first.add(name: "Helper", ownerName: "Owner", now: clock.now, random: random.bytes)
    let b = try second.add(name: "Helper", ownerName: "Owner", now: clock.now, random: random.bytes)
    var connections = ConnectionRecord()
    try connections.connect(first.connectToken(for: a), now: clock.now)
    try connections.connect(second.connectToken(for: b), now: clock.now)
    XCTAssertEqual(Set(connections.connections.map(\.id)), Set([a.id, b.id]))
  }
}

private final class RejectingRemoteWrites: RemoteStorage {
  var record: RemoteRecord
  var rejectWrites = false
  init(record: RemoteRecord) { self.record = record }
  func read() throws -> RemoteRecord? { record }
  func write(_ record: RemoteRecord) throws {
    if rejectWrites { throw QuietError.unavailable }
    self.record = record
  }
}
