import Foundation
import QuietCore
import XCTest

final class RemoteSafetyTests: XCTestCase {
  func testClockFloorSurvivesSerializationAndExpiredObservation() throws {
    let clock = TestClock()
    let p = try pair(clock: clock)
    let token = try p.link(at: clock.now)
    let start = clock.now
    clock.now += 10000
    XCTAssertThrowsError(try p.verifier.verify(token))
    XCTAssertEqual(p.store.record?.usedNonces.count, 0)
    p.store.record = try JSONDecoder().decode(RemoteRecord.self, from: JSONEncoder().encode(p.store.record!))
    clock.now = start + 10
    let restarted = RemoteVerifier(store: p.store, clock: { clock.now })
    XCTAssertThrowsError(try restarted.verify(token)) { XCTAssertEqual($0 as? RemoteError, .expired) }
    XCTAssertThrowsError(try restarted.verify(try p.link(at: clock.now)))
    clock.now = start + 10000
    XCTAssertNoThrow(try restarted.verify(try p.link(at: clock.now)))
  }

  func testPrunedSpentLinkCannotReviveAfterDiskRestart() throws {
    let clock = TestClock()
    let p = try pair(clock: clock)
    let start = clock.now
    let first = try p.link(at: start)
    _ = try p.verifier.verify(first)
    clock.now += 800
    _ = try p.verifier.verify(try p.link(at: clock.now))
    XCTAssertEqual(p.store.record?.usedNonces.count, 1)
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try JSONEncoder().encode(p.store.record!).write(to: file)
    let reloaded = MemoryRemotes()
    reloaded.record = try JSONDecoder().decode(RemoteRecord.self, from: Data(contentsOf: file)).validated()
    clock.now = start + 300
    XCTAssertThrowsError(try RemoteVerifier(store: reloaded, clock: { clock.now }).verify(first))
    XCTAssertEqual(reloaded.record?.freshnessFloor, start + 800)
  }

  func testExactFreshnessAndFutureSkewBoundaries() throws {
    for (age, succeeds) in [(600.0, true), (600.01, false), (-120.0, true), (-120.01, false)] {
      let clock = TestClock()
      let p = try pair(clock: clock)
      let token = try p.link(at: clock.now)
      clock.now += age
      if succeeds {
        XCTAssertNoThrow(try p.verifier.verify(token))
      } else {
        XCTAssertThrowsError(try p.verifier.verify(token))
        XCTAssertEqual(p.store.record?.usedNonces.count, 0)
      }
    }
  }

  func testReplacementRejectsStaleLinkEvenAfterDisconnectAndRestart() throws {
    let clock = TestClock()
    var p = try pair(clock: clock)
    var record = p.store.record!
    let old = record.connectToken(for: p.remote)
    record.remove(id: p.remote.id)
    let replacement = try record.add(
      name: "Helper", ownerName: "Owner", now: clock.now, random: p.random.bytes)
    let latest = record.connectToken(for: replacement)
    XCTAssertTrue(try p.connections.connect(latest, now: clock.now))
    XCTAssertFalse(try p.connections.connect(latest, now: clock.now))
    XCTAssertThrowsError(try p.connections.connect(old, now: clock.now))
    p.connections.disconnect(id: replacement.id)
    p.connections = try JSONDecoder().decode(ConnectionRecord.self, from: JSONEncoder().encode(p.connections))
    XCTAssertThrowsError(try p.connections.connect(old, now: clock.now))
    XCTAssertTrue(try p.connections.connect(latest, now: clock.now))
    XCTAssertEqual(p.connections.connections.map(\.id), [replacement.id])
    try p.store.write(record)
    XCTAssertThrowsError(
      try p.verifier.verify(
        UnlockToken.issue(
          remoteID: old.remoteID, secret: old.secret,
          choice: .hour, now: clock.now, nonce: Data(repeating: 8, count: 8))))
  }

  func testLegacyMigrationRetainsCredentialsAndRejectsUnidentifiableLinks() throws {
    let clock = TestClock()
    let p = try pair(clock: clock)
    let spent = try p.link(at: clock.now)
    _ = try p.verifier.verify(spent)
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p.store.record!)) as! [String: Any]
    json["version"] = 1
    json.removeValue(forKey: "phoneID")
    json.removeValue(forKey: "generation")
    json.removeValue(forKey: "freshnessFloor")
    let legacy = try JSONDecoder().decode(
      RemoteRecord.self, from: JSONSerialization.data(withJSONObject: json))
    let migrated = try legacy.migrated()
    XCTAssertEqual(migrated.remotes.map(\.id), legacy.remotes.map(\.id))
    XCTAssertEqual(migrated.remotes.map(\.secret), legacy.remotes.map(\.secret))
    XCTAssertEqual(migrated, try migrated.migrated())
    XCTAssertEqual(migrated.usedNonces, legacy.usedNonces)
    p.store.record = migrated
    XCTAssertThrowsError(try p.verifier.verify(spent)) { XCTAssertEqual($0 as? RemoteError, .alreadyUsed) }
    var helper = ConnectionRecord()
    helper.version = 1
    helper.newest = nil
    helper.connections = [
      Connection(id: p.remote.id, ownerName: "Owner", secret: p.remote.secret, connectedAt: clock.now)
    ]
    helper = try JSONDecoder().decode(ConnectionRecord.self, from: JSONEncoder().encode(helper)).validated()
    XCTAssertNil(helper.connections[0].phoneID)
    XCTAssertNoThrow(try helper.issue(for: p.remote.id, choice: .hour, now: clock.now))
    var another = RemoteRecord()
    let fresh = try another.add(name: "Helper", ownerName: "Owner", now: clock.now)
    try helper.connect(another.connectToken(for: fresh), now: clock.now)
    XCTAssertEqual(helper.connections.count, 2, "Legacy rows must never be merged by owner name")
    helper.disconnect(id: p.remote.id)
    XCTAssertEqual(try helper.validated().connections.map(\.id), [fresh.id])
    XCTAssertThrowsError(try ConnectToken.decode("c1.any-old-token")) {
      XCTAssertEqual($0 as? RemoteError, .oldConnectLink)
    }
  }

  func testInvalidRecordsAreNeverAccepted() throws {
    let p = try pair(clock: TestClock())
    var record = p.store.record!
    record.version = 99
    XCTAssertThrowsError(try record.validated())
    record = p.store.record!
    record.remotes[0].secret = Data([1])
    XCTAssertThrowsError(try record.validated())
    record = p.store.record!
    record.remotes.append(record.remotes[0])
    XCTAssertThrowsError(try record.validated())
    record = p.store.record!
    record.phoneID = "invalid"
    XCTAssertThrowsError(try record.validated())
    var connections = p.connections
    connections.connections[0].generation = 88
    XCTAssertThrowsError(try connections.validated())
  }

  func testLiveNonceCapacityFailsClosedAndPrunesOnlyExpiredEntries() throws {
    let clock = TestClock()
    let p = try pair(clock: clock)
    p.store.record?.usedNonces = (0..<4096).map { number in
      var value = UInt64(number).bigEndian
      let nonce = withUnsafeBytes(of: &value) { Data($0).base64EncodedString() }
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
      return UsedNonce(remote: p.remote.id, nonce: nonce, issuedAt: clock.now)
    }
    XCTAssertThrowsError(try p.verifier.verify(try p.link(at: clock.now))) {
      XCTAssertEqual($0 as? RemoteError, .capacity)
    }
    XCTAssertEqual(p.store.record?.usedNonces.count, 4096)
    clock.now += 800
    XCTAssertNoThrow(try p.verifier.verify(try p.link(at: clock.now)))
    XCTAssertEqual(p.store.record?.usedNonces.count, 1)
    XCTAssertThrowsError(try RemoteName.validate("a" + String(repeating: "\u{0301}", count: 2048)))
  }

  func testParserBoundsPreserveFortyUnicodeCharacters() throws {
    var record = RemoteRecord()
    let remote = try record.add(
      name: String(repeating: "👩🏽‍🚀", count: 40),
      ownerName: String(repeating: "👩🏽‍🚀", count: 40), now: Date())
    XCTAssertEqual(try ConnectToken.decode(record.connectToken(for: remote).encode()).ownerName.count, 40)
    XCTAssertThrowsError(try ConnectToken.decode(String(repeating: "a", count: 9000)))
    XCTAssertThrowsError(try UnlockToken.decode(String(repeating: "a", count: 9000)))
    XCTAssertNil(
      RemoteLink.parse(
        URL(string: "https://www.ellington.design/calm/c#" + String(repeating: "a", count: 13000))!))
  }
}
