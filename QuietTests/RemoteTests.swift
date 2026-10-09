// Native tests for remote unlock in the app: Keychain records, link routing, and when a link is refused
// without being spent, redeemed through the normal lease path, or held until Screen Time status resolves.
import Foundation
import QuietCore
import Security
import SwiftData
import XCTest

@testable import Quiet

@MainActor final class RemoteTests: XCTestCase {
  /// Owner's phone with Helper added, and the connection record Helper's phone would hold.
  private func paired(_ h: NativeHarness) throws -> (
    model: QuietModel, pairedRemote: Remote, theirs: ConnectionRecord
  ) {
    let model = h.model()
    let pairedRemote = try model.addRemote(name: "Helper", ownerName: "Owner")
    var theirs = ConnectionRecord()
    try theirs.connect(model.remotes.connectToken(for: pairedRemote), now: h.clock.now)
    return (model, pairedRemote, theirs)
  }
  private func unlockURL(
    _ theirs: ConnectionRecord, _ pairedRemote: Remote, _ now: Date, _ choice: LeaseChoice = .hour
  )
    throws -> URL
  {
    RemoteLink.url(.unlock, token: try theirs.issue(for: pairedRemote.id, choice: choice, now: now).encode())
  }

  func testReadFailuresAndStaleCachesCannotOverwriteRecords() throws {
    let h = try NativeHarness()
    defer { h.cleanUp() }
    let (model, pairedRemote, theirs) = try paired(h)
    h.connections.record = theirs
    let url = try unlockURL(theirs, pairedRemote, h.clock.now)
    h.remotes.failRead = true
    h.connections.failRead = true
    model.refresh()
    XCTAssertNotNil(model.remoteReadError)
    XCTAssertNotNil(model.connectionReadError)
    XCTAssertEqual(model.presentation, .locked)
    XCTAssertThrowsError(try model.addRemote(name: "Other", ownerName: "Owner"))
    XCTAssertThrowsError(try model.removeRemote(pairedRemote))
    XCTAssertThrowsError(try model.disconnect(theirs.connections[0]))
    XCTAssertEqual(h.remotes.record?.remotes, [pairedRemote])
    XCTAssertEqual(h.connections.record, theirs)
    h.remotes.failRead = false
    h.connections.failRead = false
    _ = try RemoteVerifier(store: h.remotes, clock: { h.clock.now }).verify(UnlockToken.decode(url.fragment!))
    _ = try model.addRemote(name: "Other", ownerName: "Owner")
    XCTAssertEqual(h.remotes.record?.usedNonces.count, 1)
    XCTAssertEqual(h.remotes.record?.remotes.count, 2)
    model.refresh()
    XCTAssertNil(model.remoteReadError)
    XCTAssertNil(model.connectionReadError)
  }

  func testUnreadableHelperStorageDoesNotBecomeFirstLaunchOrConnected() throws {
    let h = try NativeHarness(completedSetup: false)
    defer { h.cleanUp() }
    h.connections.failRead = true
    let model = h.model()
    XCTAssertNotEqual(model.presentation, .firstLaunch)
    var issuer = RemoteRecord()
    let remote = try issuer.add(name: "Helper", ownerName: "Owner", now: h.clock.now)
    model.connect(token: issuer.connectToken(for: remote).encode())
    XCTAssertNil(model.linkOutcome)
    XCTAssertTrue(h.connections.record.connections.isEmpty)
    h.connections.failRead = false
    model.connect(token: issuer.connectToken(for: remote).encode())
    XCTAssertNotNil(model.linkOutcome)
  }

  func testHelperWritesRereadConnectionsAndRePairReplacesWithoutNameMatching() throws {
    let issuer = try NativeHarness()
    let helper = try NativeHarness(completedSetup: false)
    defer {
      issuer.cleanUp()
      helper.cleanUp()
    }
    let (owner, remote, _) = try paired(issuer)
    let oldURL = owner.connectURL(for: remote)
    let model = helper.model()
    model.open(oldURL)
    let original = helper.connections.record
    helper.connections.failRead = true
    model.loadRemote()
    model.linkOutcome = nil
    model.open(oldURL)
    XCTAssertNil(model.linkOutcome)
    XCTAssertEqual(helper.connections.record, original)
    XCTAssertThrowsError(try model.unlockURL(for: original.connections[0], choice: .hour))
    helper.connections.failRead = false
    var anotherPhone = RemoteRecord()
    let other = try anotherPhone.add(name: "Helper", ownerName: "Owner", now: helper.clock.now)
    try helper.connections.record.connect(anotherPhone.connectToken(for: other), now: helper.clock.now)
    // This model's cache still has only the first connection. Its next write must preserve both.
    model.open(oldURL)
    XCTAssertEqual(helper.connections.record.connections.count, 2)
    try owner.removeRemote(remote)
    let replacement = try owner.addRemote(name: "Helper", ownerName: "Owner")
    model.open(owner.connectURL(for: replacement))
    XCTAssertEqual(Set(helper.connections.record.connections.map(\.id)), [other.id, replacement.id])
    model.linkOutcome = nil
    model.open(oldURL)
    XCTAssertNil(model.linkOutcome)
    XCTAssertEqual(helper.connections.record.connections.count, 2)
    let restarted = helper.model()
    XCTAssertEqual(restarted.presentation, .unlockOthers)
    XCTAssertEqual(restarted.connections, helper.connections.record)
  }

  func testKeychainRecordsRoundTripAndLeaveTheSimulatorClean() throws {
    let service = "design.ellington.quiet.tests." + UUID().uuidString
    let remotes = KeychainJSON<RemoteRecord>(account: "test-remotes", service: service)
    let connections = KeychainJSON<ConnectionRecord>(account: "test-connections", service: service)
    var record = RemoteRecord()
    let pairedRemote = try record.add(name: "Helper", ownerName: "Owner", now: Date())
    do { try remotes.write(record) } catch let failure as KeychainFailure
      where failure.status == errSecMissingEntitlement
    {
      throw XCTSkip(
        "Diagnosed Security \(failure.operation) status \(failure.status) (errSecMissingEntitlement): unsigned simulator host has no Keychain entitlement. Isolated service \(service); injected adapter tests remain required."
      )
    }
    defer {
      XCTAssertNoThrow(try remotes.delete())
      XCTAssertNoThrow(try connections.delete())
    }
    XCTAssertEqual(try remotes.read(), record)
    var connection = ConnectionRecord()
    try connection.connect(record.connectToken(for: pairedRemote), now: Date())
    try connections.write(connection)
    XCTAssertEqual(try connections.read(), connection)
    record.remove(id: pairedRemote.id)
    try remotes.write(record)
    XCTAssertEqual(try remotes.read()?.remotes, [])
    try remotes.delete()
    XCTAssertNil(try remotes.read())
  }

  func testKeychainStatusAndMalformedDataDiagnostics() throws {
    var status = errSecItemNotFound
    var bytes: Data? = nil
    var added = 0
    let access = KeychainAccess(
      read: { _ in (status, bytes) }, update: { _, _ in status },
      add: { _ in
        added += 1
        return errSecSuccess
      }, delete: { _ in status })
    let item = KeychainJSON<RemoteRecord>(account: "injected", service: "test-only", access: access)
    XCTAssertNil(try item.read())
    try item.write(RemoteRecord())
    XCTAssertEqual(added, 1)
    for code in [errSecInteractionNotAllowed, errSecAuthFailed, errSecMissingEntitlement, errSecDecode] {
      status = code
      XCTAssertThrowsError(try item.read()) {
        XCTAssertEqual($0 as? KeychainFailure, KeychainFailure(operation: "read", status: code))
      }
      XCTAssertThrowsError(try item.write(RemoteRecord())) {
        XCTAssertEqual($0 as? KeychainFailure, KeychainFailure(operation: "write", status: code))
      }
      XCTAssertThrowsError(try item.delete()) {
        XCTAssertEqual($0 as? KeychainFailure, KeychainFailure(operation: "delete", status: code))
      }
    }
    XCTAssertEqual(added, 1, "A failed update must not fall back to adding/replacing data")
    status = errSecSuccess
    bytes = Data("{truncated".utf8)
    XCTAssertThrowsError(try item.read()) { XCTAssertTrue($0 is DecodingError) }
    var record = RemoteRecord()
    record.version = 99
    bytes = try JSONEncoder().encode(record)
    XCTAssertThrowsError(try item.read()?.validated())
    bytes = try JSONEncoder().encode(RemoteRecord())
    XCTAssertNoThrow(try item.read()?.validated())
    XCTAssertNoThrow(try item.write(RemoteRecord()))
    XCTAssertEqual(added, 1)
    XCTAssertNoThrow(try item.delete())
  }

  func testFailedGrantStaysSpentAndMetadataFailureRecoversFromJournal() throws {
    let h = try NativeHarness()
    defer { h.cleanUp() }
    let (model, pairedRemote, theirs) = try paired(h)
    h.scheduler.failLease = true
    model.open(try unlockURL(theirs, pairedRemote, h.clock.now))
    XCTAssertNil(model.activeLease)
    XCTAssertNil(model.remotes.remotes.first?.lastUnlockAt)
    XCTAssertEqual(h.remotes.record?.usedNonces.count, 1)
    h.scheduler.failLease = false
    model.refresh()
    h.remotes.failAfterWrites = h.remotes.writes + 1  // Allow the nonce, fail success metadata only.
    model.error = nil
    model.open(try unlockURL(theirs, pairedRemote, h.clock.now))
    XCTAssertNotNil(model.activeLease)
    XCTAssertNil(model.error, "A successful activation must not say it failed")
    XCTAssertNotNil(model.remoteMetadataError)
    XCTAssertEqual(model.remotes.remotes.first?.lastUnlockAt, h.clock.now)
    XCTAssertNil(h.remotes.record?.remotes.first?.lastUnlockAt)
    h.remotes.failAfterWrites = nil
    let restarted = h.model()
    XCTAssertEqual(restarted.remotes.remotes.first?.lastUnlockAt, h.clock.now)
    XCTAssertEqual(h.remotes.record?.remotes.first?.lastUnlockAt, h.clock.now)
    XCTAssertEqual(try h.database!.load().leases.filter { $0.activatedAt != nil }.count, 1)
    try restarted.removeRemote(pairedRemote)
    XCTAssertEqual(try h.database!.load().leases.last?.remoteName, "Helper")
  }

  func testNearMidnightDeclineSpendsWithoutLastUnlock() throws {
    let h = try NativeHarness()
    defer { h.cleanUp() }
    h.clock.now = Calendar.current.date(bySettingHour: 23, minute: 50, second: 0, of: h.clock.now)!
    let (model, pairedRemote, theirs) = try paired(h)
    model.open(try unlockURL(theirs, pairedRemote, h.clock.now, .midnight))
    XCTAssertNil(model.activeLease)
    XCTAssertNotNil(model.error)
    XCTAssertEqual(h.remotes.record?.usedNonces.count, 1)
    XCTAssertNil(h.remotes.record?.remotes.first?.lastUnlockAt)
  }

  func testPendingLinkResolvesOnTickAndDropsOnBackground() async throws {
    let h = try NativeHarness()
    defer { h.cleanUp() }
    let (model, pairedRemote, theirs) = try paired(h)
    h.unresolvedApproval = true
    model.open(try unlockURL(theirs, pairedRemote, h.clock.now))
    model.background(dropPendingLink: false)  // System prompt/inactive is not leaving the app.
    XCTAssertNotNil(model.pendingLink)
    h.unresolvedApproval = false
    model.foregroundTick()
    XCTAssertNotNil(model.activeLease)
    model.lockNow()
    h.unresolvedApproval = true
    model.open(try unlockURL(theirs, pairedRemote, h.clock.now))
    var resume: CheckedContinuation<Void, Never>?
    h.authorizationWait = { await withCheckedContinuation { resume = $0 } }
    let task = Task { await model.prepareForeground() }
    for _ in 0..<10 { await Task.yield() }
    XCTAssertNotNil(resume)
    model.background()
    resume?.resume()
    await task.value
    XCTAssertNil(model.activeLease)
    XCTAssertNil(model.pendingLink)
    XCTAssertEqual(h.remotes.record?.usedNonces.count, 1)
  }

  func testAllRecoveryStatesDeclineWithoutSpendingAndHelperNeverEnforces() throws {
    for mode in ["active", "permission", "monitor", "projection", "repair", "unconfigured", "pending"] {
      let h = try NativeHarness(completedSetup: mode != "unconfigured" && mode != "pending")
      defer { h.cleanUp() }
      let (model, pairedRemote, theirs) = try paired(h)
      switch mode {
      case "active": try h.grant()
      case "permission": h.isApproved = false
      case "monitor":
        h.scheduler.names = []
        h.scheduler.failDaily = true
      case "projection": h.failProjection = true
      case "repair": try h.removeJournal(empty: true)
      case "pending":
        h.scheduler.failDaily = true
        XCTAssertThrowsError(try model.enroll(h.policy, pin: TestPIN.primary, confirmation: TestPIN.primary))
      default: break
      }
      model.refresh()
      let before = h.remotes.record
      model.open(try unlockURL(theirs, pairedRemote, h.clock.now))
      XCTAssertNotNil(model.error, mode)
      XCTAssertEqual(h.remotes.record?.usedNonces, before?.usedNonces, mode)
    }
    let helper = try NativeHarness(completedSetup: false)
    defer { helper.cleanUp() }
    let model = helper.model()
    let before = try helper.database!.load()
    var issuer = RemoteRecord()
    let remote = try issuer.add(name: "Helper", ownerName: "Owner", now: helper.clock.now)
    model.connect(token: issuer.connectToken(for: remote).encode())
    _ = try model.unlockURL(for: XCTUnwrap(model.connections.connections.first), choice: .midnight)
    do {
      XCTAssertEqual(helper.authorizationRequests, 0)
      XCTAssertEqual(try helper.database!.load(), before)
      XCTAssertTrue(helper.scheduler.names.isEmpty)
    }
  }

  func testMalformedAndUnsupportedRecordsPreserveStoredBytesOnEveryMutation() throws {
    let h = try NativeHarness()
    defer { h.cleanUp() }
    let (model, pairedRemote, theirs) = try paired(h)
    h.remotes.record?.version = 999
    h.connections.record = theirs
    h.connections.record.connections[0].secret = Data([0])
    let oldRemote = h.remotes.record
    let oldConnections = h.connections.record
    model.refresh()
    XCTAssertThrowsError(try model.addRemote(name: "Other", ownerName: "Owner"))
    XCTAssertThrowsError(try model.removeRemote(pairedRemote))
    XCTAssertThrowsError(try model.disconnect(theirs.connections[0]))
    model.connect(token: model.remotes.connectToken(for: pairedRemote).encode())
    XCTAssertNil(model.linkOutcome)
    XCTAssertEqual(h.remotes.record, oldRemote)
    XCTAssertEqual(h.connections.record, oldConnections)
  }

  func testDiskBackedBuild6JournalCredentialAndSwiftDataMigration() throws {
    let bundle = Bundle(for: RemoteTests.self)
    let source = try XCTUnwrap(bundle.resourceURL).appendingPathComponent("Build6Fixture")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.copyItem(at: source, to: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    for name in ["control", "pending"] {
      let path = directory.appendingPathComponent(name)
      let expected = try JSONDecoder().decode(
        ControlState.self, from: Data(contentsOf: path.appendingPathComponent("expected.json")))
      let database = try ControlDatabase(directory: path)
      XCTAssertEqual(try database.load(), expected)
      XCTAssertEqual(try database.load().policy?.allowed.count, 44)
      XCTAssertEqual(try database.load().policy?.limits.count, 6)
      XCTAssertTrue(try database.load().leases.allSatisfy { $0.remoteName == nil && $0.remoteID == nil })
      XCTAssertEqual(try ControlDatabase(directory: path).load(), expected)
    }
    let bytes = try Data(contentsOf: directory.appendingPathComponent("credential.json"))
    let credentials = FixtureCredentials()
    credentials.credential = try JSONDecoder().decode(Credential.self, from: bytes)
    let pin = PINVerifier(
      store: credentials, clock: { now }, salt: { Data() },
      derive: { _, _, _ in Data(repeating: 1, count: 32) })
    XCTAssertTrue(try pin.hasCredential())
    XCTAssertNoThrow(try pin.verify(TestPIN.primary, operation: .lease))
    XCTAssertEqual(credentials.credential?.salt, Data(repeating: 7, count: 32))
    let expected = try JSONDecoder().decode(
      [Lease].self, from: Data(contentsOf: directory.appendingPathComponent("history-expected.json")))
    let schema = Schema([UnlockInterval.self])
    let configuration = ModelConfiguration(
      "QuietHistory", schema: schema, url: directory.appendingPathComponent("history.store"),
      cloudKitDatabase: .none)
    do {
      let container = try ModelContainer(for: schema, configurations: configuration)
      let rows = try container.mainContext.fetch(FetchDescriptor<UnlockInterval>())
      XCTAssertEqual(Set(rows.map(\.id)), Set(expected.map(\.id)))
      for lease in expected {
        let row = try XCTUnwrap(rows.first { $0.id == lease.id })
        XCTAssertEqual(row.start, lease.activatedAt)
        XCTAssertEqual(row.plannedEnd, lease.expiresAt)
        XCTAssertEqual(row.earlyEnd, lease.endedAt)
        XCTAssertNil(row.remoteName)
      }
      var state = try ControlDatabase(directory: directory.appendingPathComponent("control")).load()
      state.leases[1].remoteName = "Helper"
      try HistoryProjection.replay(state, into: container.mainContext, now: now)
    }
    let reopened = try ModelContainer(for: schema, configurations: configuration)
    let rows = try reopened.mainContext.fetch(FetchDescriptor<UnlockInterval>())
    XCTAssertEqual(Set(rows.map(\.id)), Set(expected.prefix(2).map(\.id)))
    XCTAssertEqual(rows.first { $0.id == expected[1].id }?.remoteName, "Helper")
    let day = DateInterval(start: now - 7200, end: now + 7200)
    XCTAssertEqual(CivilTime.seconds(rows.map(\.lease), day: day, now: now), 1000)
  }

  func testLinksRouteToConnectRedeemOrStatusOnly() throws {
    let charlie = try NativeHarness()
    let other = try NativeHarness(completedSetup: false)
    defer {
      charlie.cleanUp()
      other.cleanUp()
    }
    let (model, pairedRemote, _) = try paired(charlie)
    let theirs = other.model()
    XCTAssertEqual(theirs.presentation, .firstLaunch)
    theirs.open(model.connectURL(for: pairedRemote))
    XCTAssertEqual(theirs.linkOutcome, LinkOutcome(owner: "Owner", already: false))
    XCTAssertEqual(other.connections.record.connections.map(\.id), [pairedRemote.id])
    XCTAssertEqual(theirs.presentation, .unlockOthers)
    theirs.linkOutcome = nil
    theirs.open(model.connectURL(for: pairedRemote))
    XCTAssertEqual(theirs.linkOutcome, LinkOutcome(owner: "Owner", already: true))
    // Each phone refuses the other's link with the spec's words.
    model.open(model.connectURL(for: pairedRemote))
    XCTAssertEqual(
      model.error,
      "This link is for the other phone. Send it to the person you added. They open it on their phone.")
    let connection = try XCTUnwrap(theirs.connections.connections.first)
    theirs.open(try theirs.unlockURL(for: connection, choice: .hour))
    XCTAssertEqual(theirs.error, "This link unlocks Owner’s phone. Open it there, not on this phone.")
    model.error = nil
    model.open(URL(string: "quiet://unlock?t=nonsense")!)
    XCTAssertEqual(model.error, "This isn’t a Calm Phone link.")
    model.error = nil
    model.open(URL(string: "quiet://open/whatsapp")!)
    XCTAssertEqual(model.page, .status)
    XCTAssertNil(model.error)
    XCTAssertNil(model.activeLease)
    // Disconnecting the only phone returns theirs to First launch; choosing to restrict opens setup.
    try theirs.disconnect(connection)
    XCTAssertEqual(theirs.presentation, .firstLaunch)
    theirs.choseRestrict = true
    XCTAssertEqual(theirs.presentation, .freshSetup)
  }

  func testLockedPhoneRedeemsOnceThroughTheLeasePath() throws {
    let h = try NativeHarness()
    defer { h.cleanUp() }
    let (model, pairedRemote, theirs) = try paired(h)
    let url = try unlockURL(theirs, pairedRemote, h.clock.now)
    XCTAssertEqual(model.presentation, .locked)
    model.open(url)
    XCTAssertNil(model.error)
    let lease = try XCTUnwrap(model.activeLease)
    XCTAssertEqual(lease.remoteName, "Helper")
    XCTAssertEqual(lease.expiresAt.timeIntervalSince(lease.requestedAt), 3600)
    XCTAssertEqual(model.remotes.usedNonces.count, 1)
    XCTAssertEqual(model.remotes.remotes.first?.lastUnlockAt, h.clock.now)
    XCTAssertTrue(h.projections.last!.isOpen)
    model.lockNow()
    XCTAssertNil(model.activeLease)
    model.open(url)
    XCTAssertEqual(model.error, "Link already used. Each link works once. Ask Helper for a new one.")
    XCTAssertNil(model.activeLease)
    model.error = nil
    let late = try unlockURL(theirs, pairedRemote, h.clock.now)
    h.clock.now += 601
    model.open(late)
    XCTAssertEqual(model.error, "Link expired. Unlock links work for 10 minutes. Ask Helper for a new one.")
    model.error = nil
    try model.removeRemote(pairedRemote)
    model.open(try unlockURL(theirs, pairedRemote, h.clock.now))
    XCTAssertEqual(
      model.error,
      "Link not recognised. No remote on this phone matches this link. Add them again from Unlock methods.")
    XCTAssertNil(model.activeLease)
  }

  func testActiveOrRecoveryRefusesWithoutSpendingTheLink() throws {
    let h = try NativeHarness()
    defer { h.cleanUp() }
    let (model, pairedRemote, theirs) = try paired(h)
    try h.grant()
    model.refresh()
    let end = try XCTUnwrap(model.activeLease).expiresAt
    let url = try unlockURL(theirs, pairedRemote, h.clock.now)
    model.open(url)
    XCTAssertEqual(
      model.error,
      "Already unlocked. Access is active until \(CalmTime.deadline(end)). Lock now first to start a new unlock."
    )
    XCTAssertEqual(model.remotes.usedNonces, [])
    XCTAssertNil(model.activeLease?.remoteName)
    model.lockNow()
    model.error = nil
    h.isApproved = false
    model.refresh()
    XCTAssertEqual(model.presentation, .permissionNeeded)
    model.open(url)
    XCTAssertEqual(model.error, "Couldn’t unlock. Check restrictions first.")
    XCTAssertEqual(model.remotes.usedNonces, [])
  }

  func testColdStartHoldsTheLinkUntilScreenTimeStatusResolves() async throws {
    let h = try NativeHarness()
    defer { h.cleanUp() }
    let (model, pairedRemote, theirs) = try paired(h)
    h.unresolvedApproval = true
    let url = try unlockURL(theirs, pairedRemote, h.clock.now)
    model.open(url)
    model.open(url)  // Duplicate delivery while unresolved must still grant only once.
    XCTAssertEqual(model.presentation, .checking)
    XCTAssertNil(model.error)
    XCTAssertEqual(model.pendingLink, url.fragment)
    XCTAssertEqual(model.remotes.usedNonces, [])
    await model.prepareForeground()
    XCTAssertNil(model.pendingLink)
    XCTAssertNil(model.error)
    XCTAssertEqual(model.activeLease?.remoteName, "Helper")
    // Leaving the app drops a held link without spending it.
    model.lockNow()
    h.unresolvedApproval = true
    let held = try unlockURL(theirs, pairedRemote, h.clock.now)
    model.open(held)
    XCTAssertNotNil(model.pendingLink)
    model.background()
    XCTAssertNil(model.pendingLink)
    XCTAssertEqual(model.remotes.usedNonces.count, 1)
  }
}
