// Tests for remote unlock: connect and unlock tokens, strict link parsing, the single-use verifier,
// and one unlock link travelling through the same coordinator grant path the PIN uses.
import Foundation
import QuietCore
import XCTest

final class MemoryRemotes: RemoteStorage {
  var record: RemoteRecord?
  var writes = 0
  func read() throws -> RemoteRecord? { record }
  func write(_ record: RemoteRecord) throws {
    self.record = record
    writes += 1
  }
}

/// Deterministic bytes; every call differs so nonces stay unique.
final class FixedRandom {
  private var counter: UInt8 = 0
  func bytes(_ count: Int) -> Data {
    counter &+= 1
    return Data(repeating: counter, count: count)
  }
}

struct Paired {
  let store: MemoryRemotes
  let verifier: RemoteVerifier
  var connections: ConnectionRecord
  let remote: Remote
  let random: FixedRandom
  func link(_ choice: LeaseChoice = .hour, at now: Date) throws -> UnlockToken {
    try UnlockToken.decode(
      connections.issue(for: remote.id, choice: choice, now: now, random: random.bytes).encode())
  }
}

func pair(clock: TestClock) throws -> Paired {
  let random = FixedRandom()
  let store = MemoryRemotes()
  var record = RemoteRecord()
  let remote = try record.add(name: " Helper ", ownerName: "Owner", now: clock.now, random: random.bytes)
  try store.write(record)
  store.writes = 0
  var connections = ConnectionRecord()
  XCTAssertTrue(
    try connections.connect(
      try ConnectToken.decode(record.connectToken(for: remote).encode()), now: clock.now))
  return Paired(
    store: store, verifier: RemoteVerifier(store: store, clock: { clock.now }), connections: connections,
    remote: remote, random: random)
}

final class RemoteUnlockTests: XCTestCase {
  func testConnectTokenRoundTrip() throws {
    var record = RemoteRecord()
    let remote = try record.add(
      name: " Helper ", ownerName: "Owner", now: Date(), random: FixedRandom().bytes)
    XCTAssertEqual(remote.name, "Helper")
    XCTAssertEqual(remote.id.count, 22)
    XCTAssertEqual(remote.secret.count, 32)
    let token = record.connectToken(for: remote)
    let text = token.encode()
    XCTAssertTrue(text.hasPrefix("c2."))
    XCTAssertFalse(text.contains("="))
    XCTAssertEqual(try ConnectToken.decode(text), token)
    XCTAssertEqual(token.ownerName, "Owner")
    let parts = text.split(separator: ".").map(String.init)
    for bad in [
      "", "c3." + parts.dropFirst().joined(separator: "."), text + ".extra",
      [parts[0], parts[1], String(parts[2].dropLast(4)), parts[3]].joined(separator: "."),
      ["c2", "short", parts[2], parts[3]].joined(separator: "."),
    ] {
      XCTAssertThrowsError(try ConnectToken.decode(bad)) { XCTAssertEqual($0 as? RemoteError, .malformed) }
    }
    XCTAssertThrowsError(try record.add(name: "  ", ownerName: "Owner", now: Date()))
    XCTAssertThrowsError(
      try record.add(name: String(repeating: "a", count: 41), ownerName: "Owner", now: Date()))
    XCTAssertEqual(record.remotes.count, 1)
  }

  func testUnlockTokenRoundTrip() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000.75)
    for choice in LeaseChoice.allCases {
      let token = UnlockToken.issue(
        remoteID: String(repeating: "A", count: 22), secret: Data(repeating: 1, count: 32), choice: choice,
        now: now,
        nonce: Data(repeating: 2, count: 8))
      let text = token.encode()
      XCTAssertEqual(text.split(separator: ".").count, 6)
      XCTAssertEqual(try UnlockToken.decode(text), token)
      XCTAssertEqual(token.issuedAt.timeIntervalSince1970, 1_800_000_000)
    }
    let good = UnlockToken.issue(
      remoteID: String(repeating: "A", count: 22), secret: Data(repeating: 1, count: 32), choice: .hour,
      now: now,
      nonce: Data(repeating: 2, count: 8)
    ).encode()
    var parts = good.split(separator: ".").map(String.init)
    var bad = [parts.dropLast().joined(separator: ".")]
    parts[2] = "45"
    bad.append(parts.joined(separator: "."))
    parts = good.split(separator: ".").map(String.init)
    parts[3] = "-5"
    bad.append(parts.joined(separator: "."))
    parts = good.split(separator: ".").map(String.init)
    parts[4] = "AgICAgI"
    bad.append(parts.joined(separator: "."))
    parts = good.split(separator: ".").map(String.init)
    parts[5] += "=="
    bad.append(parts.joined(separator: "."))
    for text in bad {
      XCTAssertThrowsError(try UnlockToken.decode(text), text) {
        XCTAssertEqual($0 as? RemoteError, .malformed)
      }
    }
  }

  func testFreshLinkWorksOnce() throws {
    let clock = TestClock()
    let p = try pair(clock: clock)
    let token = try p.link(at: clock.now)
    clock.now += 300
    let verified = try p.verifier.verify(token)
    XCTAssertTrue(verified.authorization.isValid(.lease, now: clock.now))
    XCTAssertFalse(verified.authorization.isValid(.policy, now: clock.now))
    XCTAssertEqual(verified.remote.name, "Helper")
    XCTAssertNil(p.store.record?.remotes.first?.lastUnlockAt)
    XCTAssertEqual(p.store.record?.usedNonces.count, 1)
    XCTAssertEqual(p.store.writes, 1)
    XCTAssertThrowsError(try p.verifier.verify(token)) { XCTAssertEqual($0 as? RemoteError, .alreadyUsed) }
    XCTAssertNoThrow(try p.verifier.verify(try p.link(at: clock.now)))
    XCTAssertEqual(p.store.record?.usedNonces.count, 2)
  }

  func testExpiredFutureTamperedAndUnknownLinksAreRefused() throws {
    let clock = TestClock()
    let p = try pair(clock: clock)
    let start = clock.now
    clock.now = start + 601
    XCTAssertThrowsError(try p.verifier.verify(try p.link(at: start))) {
      XCTAssertEqual($0 as? RemoteError, .expired)
    }
    p.store.record?.freshnessFloor = nil  // Independent boundary case, not a rollback test.
    clock.now = start + 600
    XCTAssertNoThrow(try p.verifier.verify(try p.link(at: start)))
    clock.now = start
    XCTAssertThrowsError(try p.verifier.verify(try p.link(at: start + 121))) {
      XCTAssertEqual($0 as? RemoteError, .notYetValid)
    }
    XCTAssertNoThrow(try p.verifier.verify(try p.link(at: start + 119)))
    let tampered = try p.link(.quarterHour, at: start).encode().replacingOccurrences(of: ".15.", with: ".60.")
    XCTAssertThrowsError(try p.verifier.verify(try UnlockToken.decode(tampered))) {
      XCTAssertEqual($0 as? RemoteError, .badSignature)
    }
    let forged = UnlockToken.issue(
      remoteID: p.remote.id, secret: Data(repeating: 9, count: 32), choice: .hour, now: start,
      nonce: Data(repeating: 3, count: 8))
    XCTAssertThrowsError(try p.verifier.verify(forged)) { XCTAssertEqual($0 as? RemoteError, .badSignature) }
    let unknown = UnlockToken.issue(
      remoteID: String(repeating: "Z", count: 22), secret: p.remote.secret, choice: .hour, now: start,
      nonce: Data(repeating: 4, count: 8))
    XCTAssertThrowsError(try p.verifier.verify(unknown)) {
      XCTAssertEqual($0 as? RemoteError, .unknownRemote)
    }
  }

  func testRemovedRemoteAndNoncePruning() throws {
    let clock = TestClock()
    let p = try pair(clock: clock)
    let start = clock.now
    try p.verifier.verify(try p.link(at: start))
    clock.now = start + 800
    try p.verifier.verify(try p.link(at: clock.now))
    XCTAssertEqual(p.store.record?.usedNonces.count, 1)
    XCTAssertEqual(p.store.record?.usedNonces.first?.issuedAt, clock.now)
    let link = try p.link(at: clock.now)
    var record = try XCTUnwrap(p.store.record)
    record.remove(id: p.remote.id)
    XCTAssertTrue(record.remotes.isEmpty)
    XCTAssertTrue(record.usedNonces.isEmpty)
    try p.store.write(record)
    XCTAssertThrowsError(try p.verifier.verify(link)) { XCTAssertEqual($0 as? RemoteError, .unknownRemote) }
  }

  func testConnectionRecord() throws {
    let clock = TestClock()
    var p = try pair(clock: clock)
    var record = try XCTUnwrap(p.store.record)
    let token = try ConnectToken.decode(record.connectToken(for: p.remote).encode())
    XCTAssertFalse(try p.connections.connect(token, now: clock.now))
    XCTAssertEqual(p.connections.connections.count, 1)
    record.remove(id: p.remote.id)
    let readded = try record.add(name: "Helper", ownerName: "Owner", now: clock.now, random: p.random.bytes)
    XCTAssertNotEqual(readded.id, p.remote.id)
    XCTAssertTrue(try p.connections.connect(record.connectToken(for: readded), now: clock.now))
    XCTAssertEqual(p.connections.connections.count, 1)
    p.connections.disconnect(id: p.remote.id)
    XCTAssertEqual(p.connections.connections.map(\.id), [readded.id])
    XCTAssertThrowsError(try p.connections.issue(for: p.remote.id, choice: .hour, now: clock.now)) {
      XCTAssertEqual($0 as? RemoteError, .unknownRemote)
    }
  }

  func testLinksParseStrictly() throws {
    let connect = RemoteLink.url(.connect, token: "c1.abc")
    let unlock = RemoteLink.url(.unlock, token: "u1.abc")
    XCTAssertEqual(connect.absoluteString, "https://www.ellington.design/calm/c#c1.abc")
    XCTAssertEqual(RemoteLink.parse(connect)?.kind, .connect)
    XCTAssertEqual(RemoteLink.parse(connect)?.token, "c1.abc")
    XCTAssertEqual(RemoteLink.parse(unlock)?.kind, .unlock)
    XCTAssertEqual(RemoteLink.parse(URL(string: "quiet://connect?t=c1.abc")!)?.kind, .connect)
    XCTAssertEqual(RemoteLink.parse(URL(string: "quiet://unlock?t=u1.abc")!)?.token, "u1.abc")
    for bad in [
      "https://www.ellington.design/calm/c", "https://www.ellington.design/calm/x#c1.abc",
      "https://example.com/calm/c#c1.abc", "http://www.ellington.design/calm/c#c1.abc",
      "https://www.ellington.design/calm/c?x=1#c1.abc", "https://me@www.ellington.design/calm/c#c1.abc",
      "https://www.ellington.design:8443/calm/c#c1.abc", "https://ellington.design/calm/c#c1.abc",
      "quiet://open/status", "quiet://unlock?t=", "quiet://unlock?t=a&t=b", "quiet://unlock/path?t=u1.abc",
      "quiet://unlock?t=u1.abc#frag",
    ] {
      XCTAssertNil(RemoteLink.parse(URL(string: bad)!), bad)
    }
    XCTAssertNil(HomeRoute.parse(connect))
    XCTAssertNil(HomeRoute.parse(URL(string: "quiet://unlock?t=u1.abc")!))
    XCTAssertEqual(HomeRoute.parse(URL(string: "quiet://open/status")!), .status)
  }

  func testGeneratedTokensSurviveBrowserFallbackAndRedeem() throws {
    let clock = TestClock()
    let paired = try pair(clock: clock)
    let record = try XCTUnwrap(paired.store.record)
    let connect = record.connectToken(for: paired.remote)
    let unlock = try paired.link(at: clock.now)
    for (kind, token) in [(RemoteLink.Kind.connect, connect.encode()), (.unlock, unlock.encode())] {
      let https = RemoteLink.url(kind, token: token)
      let fragment = try XCTUnwrap(URLComponents(url: https, resolvingAgainstBaseURL: false)?.fragment)
      // The existing browser uses encodeURIComponent: no query delimiters may survive in the token.
      let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
      let encoded = try XCTUnwrap(fragment.addingPercentEncoding(withAllowedCharacters: unreserved))
      let fallback = try XCTUnwrap(URL(string: "quiet://\(kind.rawValue)?t=\(encoded)"))
      let parsed = try XCTUnwrap(RemoteLink.parse(fallback))
      XCTAssertEqual(parsed.kind, kind)
      XCTAssertEqual(parsed.token, token)
      if kind == .connect {
        XCTAssertEqual(try ConnectToken.decode(parsed.token), connect)
      } else {
        let verified = try paired.verifier.verify(UnlockToken.decode(parsed.token))
        XCTAssertEqual(verified.remote.id, paired.remote.id)
      }
    }
  }

  func testEndToEndThroughCoordinator() throws {
    let h = try Harness()
    try h.setup()
    let p = try pair(clock: h.clock)
    let token = try p.link(.hour, at: h.clock.now)
    h.clock.now += 30
    let verified = try p.verifier.verify(token)
    let draft = try GrantDraft.prepare(token.choice, now: h.clock.now)
    try h.coordinator.grant(draft, authorization: verified.authorization, remoteName: verified.remote.name)
    let lease = try XCTUnwrap(h.database.load().openLease)
    XCTAssertTrue(lease.isActive(at: h.clock.now))
    XCTAssertEqual(lease.remoteName, "Helper")
    XCTAssertEqual(lease.expiresAt, draft.expiresAt)
    XCTAssertTrue(h.projections.last!.isOpen)
    XCTAssertThrowsError(
      try h.coordinator.grant(
        GrantDraft.prepare(.hour, now: h.clock.now), authorization: verified.authorization, remoteName: "Helper"
      ))
    try h.coordinator.lockNow()
    XCTAssertNil(try h.database.load().openLease)
    XCTAssertFalse(h.projections.last!.isOpen)
    XCTAssertThrowsError(try p.verifier.verify(token)) { XCTAssertEqual($0 as? RemoteError, .alreadyUsed) }
    // A journal written before remote unlock existed still decodes, with no remote attribution.
    var old = Lease(now: h.clock.now, expiresAt: h.clock.now + 900)
    old.remoteName = nil
    let json = try JSONEncoder().encode(old)
    XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("remoteName"))
    XCTAssertNil(try JSONDecoder().decode(Lease.self, from: json).remoteName)
  }
}
