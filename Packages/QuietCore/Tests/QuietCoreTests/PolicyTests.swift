import Foundation
import QuietCore
import XCTest

// Synthetic credentials exist only in test memory, never as saved phone data.
enum TestPIN {
  static let primary = String(repeating: "7", count: 6)
  static let replacement = String(repeating: "4", count: 6)
  static let wrong = String(repeating: "1", count: 6)
  static let zero = String(repeating: "0", count: 6)
  static let derivation = String(repeating: "8", count: 6)
  static let alternate = String(repeating: "9", count: 6)
}

final class TestClock {
  var now = Date(timeIntervalSince1970: 1_800_000_000)
}
final class Credentials: CredentialStorage {
  var value: Credential?
  var fail = false
  var failWrite = false
  func read() throws -> Credential? {
    if fail { throw QuietError.unavailable }
    return value
  }
  func write(_ credential: Credential, enrolling: Bool) throws {
    if fail || failWrite { throw QuietError.unavailable }
    value = credential
  }
}
final class Scheduler: ActivityScheduling {
  var names: [String] = []
  var fail = false
  var beforeLease: (() throws -> Void)?
  var beforeDaily: ((Policy) throws -> Void)?
  func registerDaily(_ policy: Policy) throws {
    try beforeDaily?(policy)
    if fail { throw QuietError.unavailable }
    names.append(policy.dailyName)
  }
  func registerLease(_ lease: Lease) throws {
    try beforeLease?()
    if fail { throw QuietError.unavailable }
    names.append(lease.activityName)
  }
  func isRegistered(_ name: String) -> Bool { names.contains(name) }
  func stop(_ old: [String]) { names.removeAll { old.contains($0) } }
}
func fixturePolicy() -> Policy {
  Policy(
    allowed: [AppEntry(id: "messages", label: "messages", token: "m")],
    limits: Policy.quotas.sorted { $0.key < $1.key }.map {
      LimitRule(app: AppEntry(id: $0.key, label: $0.key, token: $0.key), minutes: $0.value)
    })
}
func freshPolicy() -> Policy {
  var policy = fixturePolicy()
  for index in policy.allowed.indices { policy.allowed[index].token += "-reauthorized" }
  for index in policy.limits.indices { policy.limits[index].app.token += "-reauthorized" }
  return policy
}
final class Harness {
  let clock = TestClock()
  let credentials = Credentials()
  let scheduler = Scheduler()
  let database: ControlDatabase
  let directory: URL
  var isApproved = true
  var projections: [ShieldProjection] = []
  lazy var pin = newVerifier()
  func newVerifier() -> PINVerifier {
    PINVerifier(
      store: credentials, clock: { self.clock.now },
      salt: { Data(repeating: 9, count: 32) },
      derive: { text, _, _ in Data(repeating: text == TestPIN.primary ? 1 : 2, count: 32) })
  }
  lazy var coordinator = PolicyCoordinator(
    database: database, scheduler: scheduler,
    clock: { self.clock.now }, approved: { self.isApproved }, apply: { self.projections.append($0) })
  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    database = try ControlDatabase(directory: directory)
  }
  deinit { try? FileManager.default.removeItem(at: directory) }
  func setup() throws {
    let auth = try pin.enroll(TestPIN.primary, confirmation: TestPIN.primary, setupComplete: false)
    try coordinator.install(fixturePolicy(), authorization: auth)
  }
  func authorization(_ operation: GuardianOperation = .lease) throws -> GuardianAuthorization {
    try pin.verify(TestPIN.primary, operation: operation)
  }
}

final class PolicyTests: XCTestCase {
  func testUnknownStartupApprovalPreservesSelectionsAndExpiresDurableLease() throws {
    let h = try Harness()
    try h.setup()
    try h.coordinator.grant(.quarterHour, authorization: h.authorization())
    let policy = try XCTUnwrap(h.database.load().policy)
    let unresolved = PolicyCoordinator(
      database: h.database, scheduler: h.scheduler, clock: { h.clock.now }, approved: { nil },
      apply: { h.projections.append($0) })
    try unresolved.callback(activity: policy.dailyName, event: "quiet.limit.\(policy.limits[0].id)")
    var state = try h.database.load()
    XCTAssertEqual(state.policy, policy)
    XCTAssertFalse(state.needsReselection)
    XCTAssertTrue(state.invalidatedSelectionTokens?.isEmpty ?? true)
    XCTAssertTrue(state.exhausted.contains(policy.limits[0].id))
    XCTAssertThrowsError(try unresolved.install(policy, authorization: h.authorization(.policy)))
    XCTAssertThrowsError(try unresolved.grant(.hour, authorization: h.authorization()))
    h.clock.now = h.clock.now.addingTimeInterval(901)
    try unresolved.reconcile()
    state = try h.database.load()
    XCTAssertNil(state.openLease)
    XCTAssertFalse(h.projections.last!.isOpen)
    XCTAssertEqual(state.policy, policy)
    XCTAssertFalse(state.needsReselection)
    h.isApproved = false
    try h.coordinator.reconcile()
    XCTAssertTrue(try h.database.load().needsReselection)
    XCTAssertEqual(try h.database.load().invalidatedSelectionTokens, policy.tokens)
    XCTAssertEqual(h.projections.last!.exceptions, [])
  }

  func testInitialEnrollmentSurvivesUninitializedMonitorCallbackDuringRegistration() throws {
    let h = try Harness()
    let unresolved = PolicyCoordinator(
      database: h.database, scheduler: h.scheduler, clock: { h.clock.now }, approved: { nil },
      apply: { h.projections.append($0) })
    h.scheduler.beforeDaily = { policy in
      try unresolved.callback(activity: policy.dailyName, event: "quiet.limit.\(policy.limits[0].id)")
    }
    try h.coordinator.prepareEnrollment(fixturePolicy())
    try h.setup()
    let state = try h.database.load()
    XCTAssertTrue(state.setupComplete)
    XCTAssertFalse(state.needsReselection)
    XCTAssertNil(state.pendingPolicy)
    XCTAssertEqual(state.exhausted.count, 1)
    XCTAssertTrue(state.dailyRegistered)
    XCTAssertFalse(h.projections.last!.isOpen)
  }

  func testDiagnosedEnrollmentRepairNeedsExactPendingPolicyApprovalAndFreshPINOnce() throws {
    for mismatch in [false, true] {
      let h = try Harness()
      let policy = fixturePolicy()
      try h.coordinator.prepareEnrollment(policy)
      _ = try h.pin.enroll(TestPIN.primary, confirmation: TestPIN.primary, setupComplete: false)
      h.isApproved = false
      try h.coordinator.reconcile()
      let repair = PolicyCoordinator(
        database: h.database, scheduler: h.scheduler, clock: { h.clock.now }, approved: { h.isApproved },
        apply: { h.projections.append($0) }, recoverablePendingPolicy: { $0.generation == policy.generation })
      XCTAssertFalse(try repair.canRecoverPendingEnrollment(policy))
      XCTAssertThrowsError(try repair.install(policy, authorization: h.authorization(.policy)))
      XCTAssertNil(try h.database.load().repairedPendingGeneration)
      h.isApproved = true
      try repair.reconcile()
      var selected = policy
      if mismatch { selected.allowed[0].token = "different-token" }
      if mismatch {
        XCTAssertFalse(try repair.canRecoverPendingEnrollment(selected))
        XCTAssertThrowsError(try repair.install(selected, authorization: h.authorization(.policy)))
        XCTAssertEqual(try h.database.load().invalidatedSelectionTokens, policy.tokens)
      } else {
        XCTAssertTrue(try repair.canRecoverPendingEnrollment(policy))
        let authorization = try h.authorization(.policy)
        try repair.install(policy, authorization: authorization)
        XCTAssertTrue(try h.database.load().setupComplete)
        XCTAssertEqual(try h.database.load().policy, policy)
        XCTAssertEqual(try h.database.load().repairedPendingGeneration, policy.generation)
        XCTAssertNil(try h.database.load().openLease)
        XCTAssertFalse(h.projections.last!.isOpen)
        XCTAssertThrowsError(try repair.install(policy, authorization: authorization))
        h.isApproved = false
        try repair.reconcile()
        h.isApproved = true
        try repair.reconcile()
        XCTAssertFalse(try repair.canRecoverPendingEnrollment(policy))
        XCTAssertThrowsError(try repair.install(policy, authorization: h.authorization(.policy)))
        XCTAssertTrue(try h.database.load().needsReselection)
      }
    }
  }

  func testGivenFreshState_WhenRegisteredLeaseCallbackArrives_ThenRepairAndRestrictiveProjection() throws {
    let h = try Harness()
    XCTAssertThrowsError(try h.coordinator.callback(activity: "quiet.lease.\(UUID())", didEnd: true))
    XCTAssertEqual(h.projections.last, ShieldProjection(exceptions: [], isOpen: false))
    XCTAssertFalse(try h.database.load().setupComplete)
    XCTAssertTrue(try h.database.load().needsReselection)
    try h.coordinator.reconcile()
    XCTAssertEqual(h.projections.last, ShieldProjection(exceptions: [], isOpen: false))
  }
  func testGivenAllowOnlyRevision_WhenCallbacksAbsentOrDelayed_ThenSameDayExhaustionSurvives() throws {
    let h = try Harness()
    try h.setup()
    let old = try XCTUnwrap(h.database.load().policy)
    try h.coordinator.callback(activity: old.dailyName, event: "quiet.limit.\(old.limits[0].id)")
    var replacement = fixturePolicy()  // Deliberately new identities, same tokens and quotas.
    replacement.allowed.append(AppEntry(id: "notes", label: "notes", token: "n"))
    try h.coordinator.install(replacement, authorization: h.authorization(.policy))
    let expected = replacement.limits.first { $0.app.token == old.limits[0].app.token }!
    XCTAssertEqual(try h.database.load().exhausted, [expected.id])
    XCTAssertFalse(h.projections.last!.exceptions.contains(expected.app.token))
    try h.coordinator.callback(activity: old.dailyName, event: "quiet.limit.\(old.limits[1].id)")
    XCTAssertEqual(try h.database.load().exhausted, [expected.id])
    try h.coordinator.callback(activity: replacement.dailyName, event: "quiet.limit.\(expected.id)")
    XCTAssertEqual(try h.database.load().exhausted, [expected.id])
  }
  func testGivenReplacement_WhenOldThresholdArrivesDuringRegistration_ThenCarriedAtPromotion() throws {
    let h = try Harness()
    try h.setup()
    let old = try XCTUnwrap(h.database.load().policy)
    let replacement = fixturePolicy()
    h.scheduler.beforeDaily = { _ in
      try h.coordinator.callback(activity: old.dailyName, event: "quiet.limit.\(old.limits[0].id)")
    }
    try h.coordinator.install(replacement, authorization: h.authorization(.policy))
    let expected = replacement.limits.first { $0.app.token == old.limits[0].app.token }!
    XCTAssertEqual(try h.database.load().exhausted, [expected.id])
    XCTAssertFalse(h.projections.last!.exceptions.contains(expected.app.token))
  }
  func testGivenExhaustion_WhenQuotaLoweredRaisedOrTokenChanged_ThenOnlyProvenExhaustionCarried() throws {
    let h = try Harness()
    try h.setup()
    let old = try XCTUnwrap(h.database.load().policy)
    for rule in old.limits {
      try h.coordinator.callback(activity: old.dailyName, event: "quiet.limit.\(rule.id)")
    }
    var replacement = fixturePolicy()
    replacement.limits[0].minutes -= 1
    replacement.limits[1].minutes += 1
    replacement.limits[2].app.token = "different-app"
    try h.coordinator.install(replacement, authorization: h.authorization(.policy))
    let state = try h.database.load()
    XCTAssertTrue(state.exhausted.contains(replacement.limits[0].id))
    XCTAssertFalse(state.exhausted.contains(replacement.limits[1].id))
    XCTAssertFalse(state.exhausted.contains(replacement.limits[2].id))
    XCTAssertEqual(state.exhausted.count, 4)
  }
  func testGivenExhaustedPolicyReplacement_WhenRegistrationCrossesMidnight_ThenCarryCleared() throws {
    let h = try Harness()
    h.clock.now = CivilTime.calendar.dateInterval(of: .day, for: h.clock.now)!.end.addingTimeInterval(-1)
    try h.setup()
    let old = try XCTUnwrap(h.database.load().policy)
    try h.coordinator.callback(activity: old.dailyName, event: "quiet.limit.\(old.limits[0].id)")
    h.scheduler.beforeDaily = { _ in h.clock.now = h.clock.now.addingTimeInterval(2) }
    let replacement = fixturePolicy()
    try h.coordinator.install(replacement, authorization: h.authorization(.policy))
    XCTAssertTrue(try h.database.load().exhausted.isEmpty)
    XCTAssertTrue(h.projections.last!.exceptions.contains(old.limits[0].app.token))
  }
  func testGivenEarlyLock_WhenRestrictiveProjectionFails_ThenExpiryScheduleRetained() throws {
    let h = try Harness()
    try h.setup()
    try h.coordinator.grant(.quarterHour, authorization: h.authorization())
    let lease = try XCTUnwrap(h.database.load().openLease)
    let failing = PolicyCoordinator(
      database: h.database, scheduler: h.scheduler, clock: { h.clock.now }, approved: { true },
      apply: { _ in throw QuietError.unavailable })
    XCTAssertThrowsError(try failing.lockNow())
    XCTAssertTrue(h.scheduler.isRegistered(lease.activityName))
    try h.coordinator.callback(activity: lease.activityName, didEnd: true)
    XCTAssertFalse(h.projections.last!.isOpen)
  }
  func testGivenRegistrationAcrossMidnight_WhenPromoted_ThenPreviousDayPendingExhaustionCleared() throws {
    let h = try Harness()
    h.clock.now = CivilTime.calendar.dateInterval(of: .day, for: h.clock.now)!.end.addingTimeInterval(-1)
    h.scheduler.beforeDaily = { policy in
      try h.coordinator.callback(activity: policy.dailyName, event: "quiet.limit.\(policy.limits[0].id)")
      h.clock.now = h.clock.now.addingTimeInterval(2)
    }
    try h.setup()
    XCTAssertTrue(try h.database.load().exhausted.isEmpty)
  }
  func testGivenLeaseAcrossMidnight_WhenDayChanges_ThenAllowanceResetsAndHistoryClips() throws {
    let h = try Harness()
    let previous = CivilTime.calendar.dateInterval(of: .day, for: h.clock.now)!
    h.clock.now = previous.end.addingTimeInterval(-120)
    try h.setup()
    try h.coordinator.grant(.hour, authorization: h.authorization())
    let p = try XCTUnwrap(h.database.load().policy)
    try h.coordinator.callback(activity: p.dailyName, event: "quiet.limit.\(p.limits[0].id)")
    h.clock.now = previous.end.addingTimeInterval(1)
    try h.coordinator.reconcile()
    let state = try h.database.load()
    XCTAssertTrue(state.exhausted.isEmpty)
    XCTAssertTrue(h.projections.last!.isOpen)
    XCTAssertEqual(CivilTime.seconds(state.leases, day: previous, now: h.clock.now), 120)
    let next = CivilTime.calendar.dateInterval(of: .day, for: h.clock.now)!
    XCTAssertEqual(CivilTime.seconds(state.leases, day: next, now: h.clock.now), 1)
    try h.coordinator.lockNow()
    XCTAssertTrue(h.projections.last!.exceptions.contains(p.limits[0].app.token))
  }
  func testGivenPendingPolicy_WhenImmediateThreshold_ThenPromotionRetainsExhaustion() throws {
    let h = try Harness()
    h.scheduler.beforeDaily = { policy in
      try h.coordinator.callback(activity: policy.dailyName, event: "quiet.limit.\(policy.limits[0].id)")
    }
    try h.setup()
    let state = try h.database.load()
    XCTAssertEqual(state.exhausted.count, 1)
    XCTAssertFalse(h.projections.last!.exceptions.contains(state.policy!.limits[0].app.token))
  }
  func testGivenCrashLeftPendingLease_WhenForeground_ThenCannotActivate() throws {
    let h = try Harness()
    try h.setup()
    let lease = Lease(now: h.clock.now, expiresAt: h.clock.now.addingTimeInterval(900))
    try h.database.update { $0.leases.append(lease) }
    try h.scheduler.registerLease(lease)
    try h.coordinator.reconcile()
    XCTAssertNil(try h.database.load().openLease)
    XCTAssertFalse(h.projections.last!.isOpen)
  }
  func testGivenPolicy_WhenOverlappingOrOverCap_ThenRejected() throws {
    var p = fixturePolicy()
    try p.validate()
    p.allowed.append(p.limits[0].app)
    XCTAssertThrowsError(try p.validate())
    p = fixturePolicy()
    for i in 0..<43 { p.allowed.append(AppEntry(id: "a\(i)", label: "app", token: "t\(i)")) }
    try p.validate()
    p.allowed.append(AppEntry(id: "extra", label: "app", token: "extra"))
    XCTAssertThrowsError(try p.validate())
  }
  func testGivenSixLimits_WhenQuotaOrSelectionIsInvalid_ThenRejected() throws {
    var p = fixturePolicy()
    p.limits[0].minutes = 0
    XCTAssertThrowsError(try p.validate())
    p = fixturePolicy()
    p.limits.removeLast()
    XCTAssertThrowsError(try p.validate())
    p = fixturePolicy()
    p.limits[0].app.token = p.limits[1].app.token
    XCTAssertThrowsError(try p.validate())
  }
  func testGivenGrant_WhenSchedulerThrows_ThenNeverOpen() throws {
    let h = try Harness()
    try h.setup()
    h.scheduler.fail = true
    XCTAssertThrowsError(try h.coordinator.grant(.quarterHour, authorization: h.authorization()))
    XCTAssertFalse(h.projections.contains { $0.isOpen })
    XCTAssertEqual(try h.database.load().leases.last?.state, .failed)
  }
  func testGivenPendingLease_WhenImmediateStartCallback_ThenStillClosed() throws {
    let h = try Harness()
    try h.setup()
    h.scheduler.beforeLease = {
      let pending = try XCTUnwrap(h.database.load().openLease)
      try h.coordinator.callback(activity: pending.activityName)
      XCTAssertFalse(try h.database.load().projection(now: h.clock.now).isOpen)
    }
    try h.coordinator.grant(.quarterHour, authorization: h.authorization())
    XCTAssertTrue(h.projections.last!.isOpen)
  }
  func testGivenOpenLease_WhenExhaustedAndExpired_ThenExhaustionRetained() throws {
    let h = try Harness()
    try h.setup()
    try h.coordinator.grant(.quarterHour, authorization: h.authorization())
    let policy = try XCTUnwrap(h.database.load().policy)
    let lease = try XCTUnwrap(h.database.load().openLease)
    try h.coordinator.callback(activity: policy.dailyName, event: "quiet.limit.\(policy.limits[0].id)")
    XCTAssertTrue(h.projections.last!.isOpen)
    h.clock.now = lease.expiresAt
    try h.coordinator.callback(activity: lease.activityName, didEnd: true)
    XCTAssertFalse(h.projections.last!.isOpen)
    XCTAssertFalse(h.projections.last!.exceptions.contains(policy.limits[0].app.token))
    try h.coordinator.reconcile()
    XCTAssertEqual(try h.database.load().exhausted.count, 1)
  }
  func testGivenEarlyLockAndSuccessor_WhenOldEndArrives_ThenSuccessorStaysOpen() throws {
    let h = try Harness()
    try h.setup()
    try h.coordinator.grant(.hour, authorization: h.authorization())
    let old = try XCTUnwrap(h.database.load().openLease)
    try h.coordinator.lockNow()
    try h.coordinator.grant(.hour, authorization: h.authorization())
    try h.coordinator.callback(activity: old.activityName, didEnd: true)
    XCTAssertTrue(h.projections.last!.isOpen)
    try h.coordinator.callback(
      activity: "quiet.daily.\(UUID())", event: "quiet.limit.\(fixturePolicy().limits[0].id)")
    XCTAssertTrue(try h.database.load().exhausted.isEmpty)
  }
  func testGivenLease_WhenSecondGrant_ThenRejected() throws {
    let h = try Harness()
    try h.setup()
    try h.coordinator.grant(.hour, authorization: h.authorization())
    XCTAssertThrowsError(try h.coordinator.grant(.hour, authorization: h.authorization()))
    XCTAssertEqual(try h.database.load().leases.count, 1)
  }
  func testGivenRevocation_WhenReapproved_ThenRequiresPINReselection() throws {
    let h = try Harness()
    try h.setup()
    try h.coordinator.grant(.hour, authorization: h.authorization())
    h.isApproved = false
    try h.coordinator.reconcile()
    h.isApproved = true
    try h.coordinator.reconcile()
    XCTAssertTrue(try h.database.load().needsReselection)
    XCTAssertTrue(h.projections.last!.exceptions.isEmpty)
    XCTAssertThrowsError(try h.coordinator.grant(.hour, authorization: h.authorization()))
  }
  func testGivenMissingSchedule_WhenForegroundRecovery_ThenPastExhaustionSurvives() throws {
    let h = try Harness()
    try h.setup()
    let p = try XCTUnwrap(h.database.load().policy)
    try h.coordinator.callback(activity: p.dailyName, event: "quiet.limit.\(p.limits[0].id)")
    h.scheduler.names = []
    try h.coordinator.reconcile()
    XCTAssertTrue(h.scheduler.isRegistered(p.dailyName))
    XCTAssertFalse(h.projections.last!.exceptions.contains(p.limits[0].app.token))
  }
  func testGivenPolicyReplacement_WhenRegistrationFails_ThenOldPolicySurvives() throws {
    let h = try Harness()
    try h.setup()
    let old = try h.database.load().policy
    h.scheduler.fail = true
    XCTAssertThrowsError(try h.coordinator.install(fixturePolicy(), authorization: h.authorization(.policy)))
    XCTAssertEqual(try h.database.load().policy, old)
    XCTAssertNil(try h.database.load().pendingPolicy)
  }
  func testGivenFirstEnrollmentFailure_WhenRetryingSavedPolicy_ThenIntentAndExhaustionSurvive() throws {
    let h = try Harness()
    let policy = fixturePolicy()
    try h.coordinator.prepareEnrollment(policy)
    let auth = try h.pin.enroll(TestPIN.primary, confirmation: TestPIN.primary, setupComplete: false)
    h.scheduler.fail = true
    h.scheduler.beforeDaily = { pending in
      try h.coordinator.callback(activity: pending.dailyName, event: "quiet.limit.\(pending.limits[0].id)")
    }
    XCTAssertThrowsError(try h.coordinator.install(policy, authorization: auth))
    let restarted = try ControlDatabase(directory: h.directory)
    XCTAssertEqual(try restarted.load().pendingPolicy, policy)
    XCTAssertEqual(try restarted.load().pendingExhausted, [policy.limits[0].id])
    XCTAssertFalse(try restarted.load().setupComplete)
    XCTAssertTrue(try restarted.load().monitorFailed)
    XCTAssertEqual(h.projections.last, ShieldProjection(exceptions: [], isOpen: false))
    h.scheduler.fail = false
    h.scheduler.beforeDaily = nil
    try h.coordinator.reconcile()
    XCTAssertEqual(try restarted.load().pendingPolicy, policy)
    XCTAssertFalse(h.scheduler.isRegistered(policy.dailyName))
    XCTAssertThrowsError(try h.coordinator.install(policy, authorization: auth))
    XCTAssertThrowsError(try h.pin.enroll(TestPIN.wrong, confirmation: TestPIN.wrong, setupComplete: false))
    try h.coordinator.install(policy, authorization: h.authorization(.policy))
    XCTAssertTrue(try restarted.load().setupComplete)
    XCTAssertNil(try restarted.load().pendingPolicy)
    XCTAssertEqual(try restarted.load().exhausted, [policy.limits[0].id])
    XCTAssertFalse(h.projections.last!.exceptions.contains(policy.limits[0].app.token))
  }
  func testGivenEnrollmentIntent_WhenInterruptedAfterRegistration_ThenPINRequiredForPromotion() throws {
    let h = try Harness()
    let policy = fixturePolicy()
    try h.coordinator.prepareEnrollment(policy)
    _ = try h.pin.enroll(TestPIN.primary, confirmation: TestPIN.primary, setupComplete: false)
    try h.scheduler.registerDaily(policy)
    try h.coordinator.callback(activity: policy.dailyName)
    try h.coordinator.reconcile()
    XCTAssertFalse(try h.database.load().setupComplete)
    XCTAssertEqual(try h.database.load().pendingPolicy, policy)
    XCTAssertEqual(h.projections.last, ShieldProjection(exceptions: [], isOpen: false))
    XCTAssertFalse(h.scheduler.isRegistered(policy.dailyName))
    try h.coordinator.install(policy, authorization: h.authorization(.policy))
    XCTAssertTrue(try h.database.load().setupComplete)
  }
  func testGivenFailedFirstEnrollment_WhenRevokedAndReapproved_ThenVoidedTokensCannotPromote() throws {
    let h = try Harness()
    let policy = fixturePolicy()
    try h.coordinator.prepareEnrollment(policy)
    let auth = try h.pin.enroll(TestPIN.primary, confirmation: TestPIN.primary, setupComplete: false)
    let credential = try XCTUnwrap(h.credentials.value)
    h.scheduler.fail = true
    XCTAssertThrowsError(try h.coordinator.install(policy, authorization: auth))
    h.isApproved = false
    try h.coordinator.reconcile()
    let restarted = try ControlDatabase(directory: h.directory)
    XCTAssertTrue(try restarted.load().needsReselection)
    XCTAssertEqual(try restarted.load().invalidatedSelectionTokens, policy.tokens)
    XCTAssertEqual(try restarted.load().pendingPolicy, policy)
    h.isApproved = true
    h.scheduler.fail = false
    try h.coordinator.reconcile()
    var renamed = policy
    renamed.generation = UUID()
    for old in [policy, renamed] {
      XCTAssertThrowsError(try h.coordinator.install(old, authorization: h.authorization(.policy))) { error in
        XCTAssertEqual(error as? QuietError, .reselectionRequired)
      }
      XCTAssertFalse(h.scheduler.isRegistered(old.dailyName))
      XCTAssertFalse(try restarted.load().setupComplete)
      XCTAssertEqual(try restarted.load().pendingPolicy, policy)
      XCTAssertEqual(h.projections.last, ShieldProjection(exceptions: [], isOpen: false))
    }
    let fresh = freshPolicy()
    h.scheduler.fail = true
    h.scheduler.beforeDaily = { pending in
      try h.coordinator.callback(activity: pending.dailyName, event: "quiet.limit.\(pending.limits[0].id)")
    }
    XCTAssertThrowsError(try h.coordinator.install(fresh, authorization: h.authorization(.policy)))
    XCTAssertFalse(try restarted.load().setupComplete)
    XCTAssertEqual(try restarted.load().pendingPolicy, fresh)
    XCTAssertEqual(try restarted.load().invalidatedSelectionTokens, policy.tokens)
    XCTAssertEqual(try restarted.load().pendingExhausted, [fresh.limits[0].id])
    h.scheduler.fail = false
    h.scheduler.beforeDaily = nil
    try h.coordinator.install(fresh, authorization: h.authorization(.policy))
    XCTAssertTrue(try restarted.load().setupComplete)
    XCTAssertFalse(try restarted.load().needsReselection)
    XCTAssertEqual(try restarted.load().policy, fresh)
    XCTAssertEqual(try restarted.load().exhausted, [fresh.limits[0].id])
    XCTAssertEqual(h.credentials.value?.derivedKey, credential.derivedKey)
    XCTAssertFalse(h.projections.last!.isOpen)
    XCTAssertThrowsError(try h.coordinator.install(renamed, authorization: h.authorization(.policy)))
  }
  func testGivenPendingEnrollment_WhenApprovalLostDuringInstall_ThenInvalidationCommitsBeforeError() throws {
    for duringRegistration in [false, true] {
      let h = try Harness()
      let policy = fixturePolicy()
      try h.coordinator.prepareEnrollment(policy)
      let auth = try h.pin.enroll(TestPIN.primary, confirmation: TestPIN.primary, setupComplete: false)
      if duringRegistration {
        h.scheduler.beforeDaily = { _ in h.isApproved = false }
      } else {
        h.isApproved = false
      }
      XCTAssertThrowsError(try h.coordinator.install(policy, authorization: auth))
      XCTAssertFalse(try h.database.load().setupComplete)
      XCTAssertFalse(try h.database.load().authorizationApproved)
      XCTAssertTrue(try h.database.load().needsReselection)
      XCTAssertEqual(try h.database.load().invalidatedSelectionTokens, policy.tokens)
      XCTAssertEqual(h.projections.last, ShieldProjection(exceptions: [], isOpen: false))
      h.isApproved = true
      h.scheduler.beforeDaily = nil
      XCTAssertThrowsError(try h.coordinator.install(policy, authorization: h.authorization(.policy)))
      XCTAssertFalse(try h.database.load().setupComplete)
    }
  }
  func testGivenLegacyPendingJournal_WhenLossWasAlreadyObserved_ThenReapprovalDoesNotReviveTokens() throws {
    let h = try Harness()
    var legacy = ControlState()
    legacy.pendingPolicy = fixturePolicy()
    legacy.authorizationApproved = false
    var payload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
    payload.removeValue(forKey: "invalidatedSelectionTokens")
    let decoded = try JSONDecoder().decode(
      ControlState.self, from: JSONSerialization.data(withJSONObject: payload))
    XCTAssertNil(decoded.invalidatedSelectionTokens)
    try h.database.update { $0 = decoded }
    try h.coordinator.reconcile()
    XCTAssertTrue(try h.database.load().needsReselection)
    XCTAssertEqual(try h.database.load().invalidatedSelectionTokens, legacy.pendingPolicy?.tokens)
    XCTAssertEqual(h.projections.last, ShieldProjection(exceptions: [], isOpen: false))
  }
  func testGivenRevokedIntentBeforeCredential_WhenFreshlySelected_ThenInitialEnrollmentCanRecover() throws {
    let h = try Harness()
    let old = fixturePolicy()
    try h.coordinator.prepareEnrollment(old)
    h.isApproved = false
    try h.coordinator.reconcile()
    XCTAssertNil(h.credentials.value)
    h.isApproved = true
    XCTAssertThrowsError(try h.coordinator.prepareEnrollment(old))
    let fresh = freshPolicy()
    try h.coordinator.prepareEnrollment(fresh)
    let auth = try h.pin.enroll(TestPIN.primary, confirmation: TestPIN.primary, setupComplete: false)
    try h.coordinator.install(fresh, authorization: auth)
    XCTAssertTrue(try h.database.load().setupComplete)
    XCTAssertEqual(try h.database.load().policy, fresh)
  }
  func testGivenCompletedOrRepairState_WhenPreparingEnrollment_ThenIntentCannotReplaceIt() throws {
    let h = try Harness()
    try h.setup()
    let before = try h.database.load()
    XCTAssertThrowsError(try h.coordinator.prepareEnrollment(fixturePolicy()))
    XCTAssertEqual(try h.database.load(), before)
    let fresh = try Harness()
    XCTAssertThrowsError(try fresh.coordinator.callback(activity: "quiet.daily.\(UUID())"))
    XCTAssertThrowsError(try fresh.coordinator.prepareEnrollment(fixturePolicy()))
    XCTAssertNil(try fresh.database.load().pendingPolicy)
    XCTAssertEqual(fresh.projections.last, ShieldProjection(exceptions: [], isOpen: false))
  }
  func testGivenLostLeaseSchedule_WhenReconcile_ThenClosed() throws {
    let h = try Harness()
    try h.setup()
    try h.coordinator.grant(.hour, authorization: h.authorization())
    h.scheduler.names.removeAll { $0.hasPrefix("quiet.lease.") }
    try h.coordinator.reconcile()
    XCTAssertFalse(h.projections.last!.isOpen)
  }
  func testGivenPINFailures_WhenVerifierRecreated_ThenLockoutPersists() throws {
    let h = try Harness()
    try h.setup()
    for _ in 0..<5 { XCTAssertThrowsError(try h.pin.verify(TestPIN.zero, operation: .lease)) }
    let restarted = h.newVerifier()
    XCTAssertThrowsError(try restarted.verify(TestPIN.primary, operation: .lease))
    XCTAssertThrowsError(try h.authorization())
    h.clock.now = h.clock.now.addingTimeInterval(-1000)
    XCTAssertThrowsError(try h.authorization())
    h.clock.now = h.credentials.value!.lockedUntil!
    _ = try h.authorization()
    XCTAssertEqual(h.credentials.value!.failedAttempts, 0)
  }
  func testGivenCredentialFailure_WhenVerifying_ThenNoAuthorization() throws {
    let h = try Harness()
    try h.setup()
    h.credentials.fail = true
    XCTAssertThrowsError(try h.authorization())
    h.credentials.fail = false
    h.credentials.value = nil
    XCTAssertThrowsError(try h.authorization())
    XCTAssertThrowsError(
      try h.pin.enroll(TestPIN.primary, confirmation: TestPIN.primary, setupComplete: true))
  }
  func testGivenCredentialWriteFailure_WhenPINMatches_ThenNoAuthorization() throws {
    let h = try Harness()
    try h.setup()
    h.credentials.failWrite = true
    XCTAssertThrowsError(try h.authorization())
  }
  func testGivenAuthorization_WhenReusedOrWrongActionOrExpired_ThenRejected() throws {
    let h = try Harness()
    try h.setup()
    let auth = try h.authorization()
    try auth.consume(.lease, now: h.clock.now)
    XCTAssertThrowsError(try auth.consume(.lease, now: h.clock.now))
    XCTAssertThrowsError(try h.authorization().consume(.policy, now: h.clock.now))
    let later = try h.authorization()
    h.clock.now = h.clock.now.addingTimeInterval(60)
    XCTAssertThrowsError(try later.consume(.lease, now: h.clock.now))
    let background = try h.authorization()
    background.invalidate()
    XCTAssertThrowsError(try background.consume(.lease, now: h.clock.now))
  }
  func testGivenMalformedPIN_WhenValidated_ThenRejected() throws {
    for text in [
      "", String(repeating: "2", count: 5), String(repeating: "2", count: 7),
      String(repeating: "２", count: 6), "abc123",
    ] {
      XCTAssertThrowsError(try PINVerifier.validate(text))
    }
    XCTAssertFalse(PINVerifier.equal(Data([1, 2]), Data([1, 3])))
    XCTAssertFalse(PINVerifier.equal(Data([1]), Data([1, 0])))
  }
  func testGivenClock_WhenMidnightOrDST_ThenCivilTimeUsed() throws {
    let formatter = ISO8601DateFormatter()
    let late = formatter.date(from: "2026-10-03T21:50:00Z")!
    XCTAssertThrowsError(try GrantDraft.prepare(.midnight, now: late, calendar: CivilTime.calendar))
    for (date, hours) in [("2026-03-29T12:00:00Z", 23.0), ("2026-10-25T12:00:00Z", 25.0)] {
      let day = CivilTime.calendar.dateInterval(of: .day, for: formatter.date(from: date)!)!
      XCTAssertEqual(day.duration, hours * 3600)
    }
  }
  func testGivenDelayedRelock_WhenAccounting_ThenCappedAtExpiryAndUnioned() throws {
    let h = try Harness()
    var a = Lease(now: h.clock.now, expiresAt: h.clock.now.addingTimeInterval(900))
    a.state = .ended
    a.activatedAt = h.clock.now
    a.endedAt = h.clock.now.addingTimeInterval(5000)
    var b = a
    b.id = UUID()
    b.activatedAt = h.clock.now.addingTimeInterval(100)
    let day = CivilTime.calendar.dateInterval(of: .day, for: h.clock.now)!
    XCTAssertEqual(CivilTime.seconds([a, b], day: day, now: h.clock.now.addingTimeInterval(6000)), 900)
    var pending = a
    pending.activatedAt = nil
    XCTAssertEqual(CivilTime.seconds([pending], day: day, now: h.clock.now), 0)
  }
  func testGivenExternalURLs_WhenParsed_ThenOnlyFixedRoutesAccepted() throws {
    XCTAssertEqual(HomeRoute.parse(URL(string: "quiet://open/more")!), .more)
    for url in [
      "foqos://open/status", "quiet://open/status?unlock=1", "quiet://open/status#x",
      "quiet://evil/more", "quiet://u@open/more", "quiet://open:7/more", "quiet://open/%6dore",
      "quiet://open/more/", "quiet://open/unlock",
      "quiet://open/find-my", "quiet://open/whatsapp?url=https://example.com", "quiet://open//more",
      "quiet://open/../more", "quiet://open/%2e%2e/more", "quiet://open/all-apps?grant=1",
    ] { XCTAssertNil(HomeRoute.parse(URL(string: url)!)) }
  }
  func testLegacySelectionMetadataRoundTripsWithoutLaunchRoutes() throws {
    var policy = fixturePolicy()
    let findMy = AppEntry(id: "find-my", label: "find my", token: "existing-find-my-token")
    policy.allowed.append(findMy)
    let restored = try BulkSetupDraft(policy: policy).policy(previous: policy)
    XCTAssertEqual(restored, policy)
    XCTAssertEqual(restored.allowed.first { $0.id == "find-my" }, findMy)
    for route in HomeRoute.allCases {
      XCTAssertEqual(HomeRoute.parse(URL(string: "quiet://open/\(route.rawValue)")!), route)
    }
  }
  func testGivenSnapshot_WhenEncoded_ThenNoTokensOrCredentialsOrHistory() throws {
    let h = try Harness()
    try h.setup()
    h.isApproved = false
    try h.coordinator.reconcile()
    XCTAssertFalse(try XCTUnwrap(h.database.load().invalidatedSelectionTokens).isEmpty)
    let text = String(
      data: try JSONEncoder().encode(WidgetSnapshot(state: h.database.load(), now: h.clock.now)),
      encoding: .utf8)!
    for key in ["token", "invalidatedSelectionTokens", "salt", "derivedKey", "leases", "unlocked"] {
      XCTAssertFalse(text.contains(key))
    }
  }
}
