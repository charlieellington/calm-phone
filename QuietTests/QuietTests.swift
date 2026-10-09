import Foundation
import QuietCore
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Quiet

// Synthetic credentials exist only in test memory, never as saved phone data.
enum TestPIN {
  static let primary = String(repeating: "7", count: 6)
  static let replacement = String(repeating: "4", count: 6)
  static let wrong = String(repeating: "1", count: 6)
  static let zero = String(repeating: "0", count: 6)
  static let derivation = String(repeating: "8", count: 6)
  static let alternate = String(repeating: "9", count: 6)
}

final class FixtureCredentials: CredentialStorage {
  var credential: Credential?
  var afterEnrollment: (() throws -> Void)?
  func read() throws -> Credential? { credential }
  func write(_ credential: Credential, enrolling: Bool) throws {
    self.credential = credential
    if enrolling { try afterEnrollment?() }
  }
}

final class NativeClock {
  var now = Date(timeIntervalSince1970: 1_800_000_000)
}

final class NativeScheduler: ActivityScheduling {
  var names: [String] = []
  var failDaily = false
  var failLease = false
  var dailyAttempts = 0
  func registerDaily(_ policy: Policy) throws {
    dailyAttempts += 1
    if failDaily { throw QuietError.unavailable }
    names.append(policy.dailyName)
  }
  func registerLease(_ lease: Lease) throws {
    if failLease { throw QuietError.unavailable }
    names.append(lease.activityName)
  }
  func isRegistered(_ name: String) -> Bool { names.contains(name) }
  func stop(_ old: [String]) { names.removeAll { old.contains($0) } }
}

/// Remote unlock records held in memory so native tests never touch the simulator Keychain.
final class MemoryRemoteStore: RemoteStorage {
  var record: RemoteRecord?
  var failRead = false
  var failWrite = false
  var failAfterWrites: Int?
  var writes = 0
  func read() throws -> RemoteRecord? {
    if failRead { throw QuietError.unavailable }
    return record
  }
  func write(_ record: RemoteRecord) throws {
    if failWrite || failAfterWrites.map({ writes >= $0 }) == true { throw QuietError.unavailable }
    writes += 1
    self.record = record
  }
}

final class MemoryConnectionStore: ConnectionStoring {
  var record = ConnectionRecord()
  var failRead = false
  func read() throws -> ConnectionRecord {
    if failRead { throw QuietError.unavailable }
    return record
  }
  func write(_ record: ConnectionRecord) throws { self.record = record }
}

@MainActor final class NativeHarness {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let clock = NativeClock()
  let credentials = FixtureCredentials()
  let scheduler = NativeScheduler()
  let remotes = MemoryRemoteStore()
  let connections = MemoryConnectionStore()
  var isApproved = true
  var unresolvedApproval = false
  var diagnosedRecovery = false
  var failAuthorization = false
  var authorizationRequests = 0
  var authorizationWait: (() async -> Void)?
  var projections: [ShieldProjection] = []
  var failProjection = false
  var database: ControlDatabase?
  var coordinator: PolicyCoordinator?
  var policy = Policy(
    allowed: [
      AppEntry(id: "messages", label: "messages", token: "synthetic-messages"),
      AppEntry(id: "directions", label: "directions", token: "synthetic-comaps"),
    ],
    limits: Policy.quotas.map { id, quota in
      LimitRule(app: AppEntry(id: id, label: id, token: "synthetic-\(id)"), minutes: quota)
    })
  var freshPolicy: Policy {
    var fresh = policy
    fresh.generation = UUID()
    for index in fresh.allowed.indices { fresh.allowed[index].token += "-reauthorized" }
    for index in fresh.limits.indices {
      fresh.limits[index].id = UUID()
      fresh.limits[index].app.token += "-reauthorized"
    }
    return fresh
  }
  lazy var pin = PINVerifier(
    store: credentials, clock: { self.clock.now }, salt: { Data(repeating: 7, count: 32) },
    derive: { text, _, _ in Data(repeating: text == TestPIN.primary ? 1 : 2, count: 32) })
  func makeCoordinator(_ database: ControlDatabase) -> PolicyCoordinator {
    PolicyCoordinator(
      database: database, scheduler: scheduler, clock: { self.clock.now },
      approved: { self.unresolvedApproval ? nil : self.isApproved },
      apply: {
        if self.failProjection { throw QuietError.unavailable }
        self.projections.append($0)
      },
      recoverablePendingPolicy: { self.diagnosedRecovery && $0 == self.policy })
  }
  init(completedSetup: Bool = true, launcherApps: Bool = false, now: Date? = nil) throws {
    if let now { clock.now = now }
    if launcherApps {
      policy.allowed = AppCatalog.allow.map { id, label in
        AppEntry(id: id, label: label, token: "synthetic-\(id)")
      }
    }
    let database = try ControlDatabase(directory: directory)
    self.database = database
    let coordinator = makeCoordinator(database)
    self.coordinator = coordinator
    if completedSetup {
      try coordinator.install(
        policy,
        authorization: pin.enroll(TestPIN.primary, confirmation: TestPIN.primary, setupComplete: false))
    }
  }
  func model(
    historyFactory: @escaping @MainActor () throws -> ModelContainer = {
      try ModelContainer(
        for: UnlockInterval.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
  ) -> QuietModel {
    QuietModel(
      pin: pin, clock: { self.clock.now },
      databaseFactory: { try ControlDatabase(directory: self.directory) },
      coordinatorFactory: makeCoordinator, historyFactory: historyFactory,
      repair: { self.projections.append(ShieldProjection(exceptions: [], isOpen: false)) },
      validatePolicy: { try $0.validate() },
      screenTimeApproval: { self.unresolvedApproval ? nil : self.isApproved },
      requestScreenTimeAuthorization: {
        self.authorizationRequests += 1
        await self.authorizationWait?()
        if self.failAuthorization { throw QuietError.unavailable }
        self.isApproved = true
        self.unresolvedApproval = false
      }, remoteStore: remotes, connectionStore: connections)
  }
  func grant() throws {
    try coordinator!.grant(.quarterHour, authorization: pin.verify(TestPIN.primary, operation: .lease))
  }
  func removeJournal(empty: Bool) throws {
    coordinator = nil
    database = nil
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(at: directory.appendingPathComponent("control.sqlite" + suffix))
    }
    if empty { try Data().write(to: directory.appendingPathComponent("control.sqlite")) }
  }
  func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor final class QuietTests: XCTestCase {
  func testCachedTimedColourIntentRejectsBeforeCreatingAnInterval() async throws {
    XCTAssertFalse(StartColourOnlyIntent.isDiscoverable)
    do {
      _ = try await StartColourOnlyIntent().perform()
      XCTFail("A cached shortcut must not enable colour without automatic return.")
    } catch {
      XCTAssertTrue(error is ColourAutomationError)
    }
  }
  func testDailyAutomationCannotLeaveColourOnForAnUnscheduledGrantExpiry() throws {
    let h = try NativeHarness()
    defer { h.cleanUp() }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Brussels"))
    let night = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 19, minute: 0)))
    h.clock.now = night
    try h.grant()
    let control = try h.database!.load()
    var colour = ColourState()
    colour.interval = ColourInterval(now: night)
    // The complete policy would grant colour, but this build only has daily triggers.
    XCTAssertFalse(try ColourDecision.evaluate(control: control, colour: colour, now: night).filtersOn)
    let applied = try ColourBridge.supportedDecision(
      control: control, colour: colour, now: night, calendar: calendar)
    XCTAssertTrue(applied.filtersOn)
    XCTAssertEqual(applied.reason, .night)
    XCTAssertEqual(try h.database!.load(), control)
  }
  func testDailyColourDecisionNeedsNoControlOrColourStore() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Madrid"))
    let morning = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 9)))
    let evening = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 19)))
    XCTAssertFalse(try ColourBridge.decision(now: morning, calendar: calendar).filtersOn)
    XCTAssertTrue(try ColourBridge.decision(now: evening, calendar: calendar).filtersOn)
  }
  func testColourReadFailureNeverReportsAppliedOrChangesAppRestrictions() throws {
    let h = try NativeHarness()
    defer { h.cleanUp() }
    let before = try h.database!.load()
    let model = ColourSettingsModel(
      readState: { throw QuietError.repairRequired },
      readDecision: { throw QuietError.repairRequired })
    XCTAssertNil(model.decision)
    XCTAssertNil(model.state.lastApplication)
    XCTAssertNotNil(model.error)
    XCTAssertEqual(try h.database!.load(), before)
  }
  func testColourOnlyStartAndReturnPreserveAppLeaseCredentialAndHistory() throws {
    let h = try NativeHarness()
    defer { h.cleanUp() }
    try h.grant()
    let before = try h.database!.load()
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let credential = try encoder.encode(h.credentials.credential)
    let store = try ColourStore(directory: h.directory)
    _ = try store.start(now: h.clock.now)
    try store.end()
    XCTAssertEqual(try h.database!.load(), before)
    XCTAssertEqual(try encoder.encode(h.credentials.credential), credential)
    XCTAssertNil(try store.load().interval)
  }
  func testColourShortcutAcknowledgmentIsOnlyAnObservationAtItsRecordedTime() throws {
    var state = ColourState()
    state.lastApplication = ColourApplication(
      checkedAt: Date(timeIntervalSince1970: 0), filtersOn: true, matched: false)
    let model = ColourSettingsModel(
      readState: { state },
      readDecision: { try ColourDecision.evaluate(now: Date(timeIntervalSince1970: 900)) })
    XCTAssertEqual(model.state.lastApplication?.matched, false)
    XCTAssertNil(model.error)
  }
  func testLegacyRoutesOnlyShowStatusAndNeverChangeControlCredentialOrHistory() throws {
    let h = try NativeHarness(launcherApps: true)
    defer { h.cleanUp() }
    try h.grant()
    let model = h.model()
    let before = try h.database!.load()
    let credential = h.credentials.credential!.derivedKey
    let schedules = h.scheduler.names
    for route in HomeRoute.allCases {
      model.route(route)
      XCTAssertEqual(model.page, .status)
      XCTAssertNil(model.sheet)
      XCTAssertEqual(try h.database!.load(), before)
      XCTAssertEqual(h.credentials.credential!.derivedKey, credential)
      XCTAssertEqual(h.scheduler.names, schedules)
    }
  }
  func testFailedStartupCheckPreservesSavedChoicesUntilApprovalResolved() async throws {
    let h = try NativeHarness(launcherApps: true)
    defer { h.cleanUp() }
    h.unresolvedApproval = true
    h.failAuthorization = true
    let model = h.model()
    model.route(.whatsapp)
    await model.prepareForeground()
    XCTAssertEqual(model.presentation, .checking)
    XCTAssertEqual(model.state.policy, h.policy)
    XCTAssertFalse(model.state.needsReselection)
    h.failAuthorization = false
    await model.prepareForeground()
    XCTAssertEqual(model.presentation, .locked)
    XCTAssertEqual(model.page, .status)
  }
  func testDiagnosedSavedSetupFinishesWithCurrentPINWithoutSelectingAppsAgain() async throws {
    let h = try NativeHarness(completedSetup: false, launcherApps: true)
    defer { h.cleanUp() }
    let original = h.model()
    h.scheduler.failDaily = true
    XCTAssertThrowsError(try original.enroll(h.policy, pin: TestPIN.primary, confirmation: TestPIN.primary))
    h.isApproved = false
    original.refresh()
    h.isApproved = true
    h.unresolvedApproval = true
    h.diagnosedRecovery = true
    h.scheduler.failDaily = false
    let recovered = h.model()
    await recovered.prepareForeground()
    XCTAssertFalse(recovered.state.setupComplete)
    XCTAssertEqual(recovered.state.pendingPolicy, h.policy)
    recovered.resumeEnrollment()
    XCTAssertThrowsError(try recovered.verify(TestPIN.zero))
    XCTAssertNil(try h.database!.load().repairedPendingGeneration)
    try recovered.verify(TestPIN.primary)
    XCTAssertNil(recovered.sheet)
    XCTAssertTrue(recovered.state.setupComplete)
    XCTAssertEqual(recovered.state.policy, h.policy)
    XCTAssertNil(recovered.state.pendingPolicy)
    XCTAssertNil(recovered.activeLease)
    recovered.route(.whatsapp)
    XCTAssertEqual(recovered.page, .status)
    XCTAssertEqual(h.authorizationRequests, 1)
  }

  func testBulkSetupRendersWithoutChangingExistingProtection() async throws {
    for completedSetup in [false, true] {
      let h = try NativeHarness(completedSetup: completedSetup)
      defer { h.cleanUp() }
      let model = h.model()
      let before = try h.database!.load()
      let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
      let previous = scene.windows.first { $0.isKeyWindow }
      let window = UIWindow(windowScene: scene)
      defer {
        window.isHidden = true
        previous?.makeKeyAndVisible()
      }
      // Synthetic tokens are intentionally not real Apple tokens. No picker or authorization is invoked.
      if completedSetup {
        h.isApproved = false
        model.refresh()
      }
      let preserved = try h.database!.load()
      for large in [false, true] {
        let host = UIHostingController(
          rootView: SetupView().environmentObject(model)
            .dynamicTypeSize(large ? .accessibility5 : .large))
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(400))
        host.view.layoutIfNeeded()
        func scrollView(_ view: UIView) -> UIScrollView? {
          if let scroll = view as? UIScrollView { return scroll }
          return view.subviews.compactMap { scrollView($0) }.first
        }
        let scroll = try XCTUnwrap(scrollView(host.view))
        XCTAssertGreaterThan(scroll.contentSize.height, 0)
        XCTAssertLessThanOrEqual(scroll.bounds.width, host.view.bounds.width)
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
          XCTAssertTrue(host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name =
          "bulk-setup-\(completedSetup ? "existing" : "fresh")-\(large ? "accessibility" : "default")"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(try h.database!.load(), preserved)
        XCTAssertEqual(h.authorizationRequests, 0)
      }
      if !completedSetup { XCTAssertEqual(try h.database!.load(), before) }
    }
  }

  func testGivenFailedEnrollmentAndRevocation_WhenDismissedOrRelaunched_ThenCurrentPINOpensFreshSetup()
    async throws
  {
    for relaunch in [false, true] {
      let h = try NativeHarness(completedSetup: false)
      defer { h.cleanUp() }
      let model = h.model()
      model.showingSetup = true
      h.scheduler.failDaily = true
      XCTAssertThrowsError(try model.enroll(h.policy, pin: TestPIN.primary, confirmation: TestPIN.primary))
      let credential = try XCTUnwrap(h.credentials.credential)
      model.showingSetup = false
      h.isApproved = false
      model.refresh()
      XCTAssertTrue(model.state.needsReselection)
      XCTAssertEqual(model.state.invalidatedSelectionTokens, h.policy.tokens)
      XCTAssertFalse(model.needsControlRepair)
      let recovered = relaunch ? h.model() : model
      let host = UIHostingController(rootView: QuietRootView().environmentObject(recovered))
      host.loadViewIfNeeded()
      XCTAssertFalse(recovered.needsControlRepair)
      XCTAssertNil(recovered.sheet)
      recovered.resumeEnrollment()
      XCTAssertEqual(recovered.sheet, .pin)
      XCTAssertThrowsError(try recovered.verify(TestPIN.zero))
      XCTAssertEqual(recovered.sheet, .pin)
      XCTAssertEqual(h.credentials.credential?.failedAttempts, 1)
      XCTAssertEqual(h.authorizationRequests, 0)
      XCTAssertEqual(h.scheduler.dailyAttempts, 1)
      try recovered.verify(TestPIN.primary)
      XCTAssertEqual(recovered.sheet, .setup)
      XCTAssertFalse(recovered.state.authorizationApproved)
      XCTAssertFalse(recovered.state.setupComplete)
      h.failAuthorization = true
      do {
        try await recovered.approveScreenTime()
        XCTFail("Denied authorization must remain unavailable")
      } catch {}
      XCTAssertFalse(recovered.state.authorizationApproved)
      XCTAssertFalse(recovered.needsControlRepair)
      h.failAuthorization = false
      try await recovered.approveScreenTime()
      XCTAssertTrue(recovered.state.authorizationApproved)
      XCTAssertTrue(recovered.state.needsReselection)
      XCTAssertEqual(h.authorizationRequests, 2)
      h.scheduler.failDaily = false
      var renamed = h.policy
      renamed.generation = UUID()
      recovered.request(.policy) { try recovered.install(renamed, authorization: $0) }
      try recovered.verify(TestPIN.primary)
      XCTAssertEqual(recovered.error, QuietError.reselectionRequired.localizedDescription)
      XCTAssertFalse(recovered.state.setupComplete)
      XCTAssertEqual(h.scheduler.dailyAttempts, 1)
      recovered.resumeEnrollment()
      try recovered.verify(TestPIN.primary)
      XCTAssertEqual(recovered.sheet, .setup)
      // Reauthorization did not load or promote the saved selection. A fresh picker policy is required.
      let fresh = h.freshPolicy
      recovered.request(.policy) { try recovered.install(fresh, authorization: $0) }
      XCTAssertThrowsError(try recovered.verify(TestPIN.zero))
      XCTAssertFalse(recovered.state.setupComplete)
      h.scheduler.failDaily = true
      try recovered.verify(TestPIN.primary)
      XCTAssertFalse(recovered.state.setupComplete)
      XCTAssertEqual(recovered.state.pendingPolicy, fresh)
      XCTAssertEqual(h.projections.last, ShieldProjection(exceptions: [], isOpen: false))
      h.scheduler.failDaily = false
      let restarted = h.model()
      XCTAssertFalse(restarted.needsControlRepair)
      restarted.resumeEnrollment()
      try restarted.verify(TestPIN.primary)
      XCTAssertTrue(restarted.state.setupComplete)
      XCTAssertEqual(restarted.state.policy, fresh)
      XCTAssertNil(restarted.state.pendingPolicy)
      XCTAssertFalse(restarted.state.needsReselection)
      XCTAssertTrue(restarted.state.dailyRegistered)
      XCTAssertNil(restarted.activeLease)
      XCTAssertEqual(h.credentials.credential?.derivedKey, credential.derivedKey)
      XCTAssertEqual(h.credentials.credential?.salt, credential.salt)
      XCTAssertEqual(h.scheduler.dailyAttempts, 3)
      XCTAssertFalse(h.projections.last!.isOpen)
    }
  }
  func testGivenInvalidatedEnrollment_WhenEditorDismissedOrBackgrounded_ThenRecoveryNeedsCurrentPINAgain()
    throws
  {
    let h = try NativeHarness(completedSetup: false)
    defer { h.cleanUp() }
    let model = h.model()
    h.scheduler.failDaily = true
    XCTAssertThrowsError(try model.enroll(h.policy, pin: TestPIN.primary, confirmation: TestPIN.primary))
    h.isApproved = false
    model.refresh()
    model.resumeEnrollment()
    try model.verify(TestPIN.primary)
    XCTAssertEqual(model.sheet, .setup)
    model.showingSetup = false
    let recovered = h.model()
    XCTAssertFalse(recovered.needsControlRepair)
    XCTAssertEqual(recovered.state.pendingPolicy, h.policy)
    recovered.resumeEnrollment()
    XCTAssertEqual(recovered.sheet, .pin)
    recovered.background()
    XCTAssertNil(recovered.sheet)
    recovered.resumeEnrollment()
    XCTAssertThrowsError(try recovered.verify(TestPIN.zero))
    XCTAssertEqual(recovered.sheet, .pin)
    try recovered.verify(TestPIN.primary)
    XCTAssertEqual(recovered.sheet, .setup)
    XCTAssertEqual(h.scheduler.dailyAttempts, 1)
    XCTAssertFalse(recovered.state.setupComplete)
    XCTAssertEqual(h.projections.last, ShieldProjection(exceptions: [], isOpen: false))
  }
  func testGivenPendingEnrollment_WhenApprovalRestoredBeforePINRetry_ThenFreshSelectionStillRequired() throws
  {
    let h = try NativeHarness(completedSetup: false)
    defer { h.cleanUp() }
    let model = h.model()
    h.scheduler.failDaily = true
    XCTAssertThrowsError(try model.enroll(h.policy, pin: TestPIN.primary, confirmation: TestPIN.primary))
    h.isApproved = false
    model.refresh()
    h.isApproved = true
    h.scheduler.failDaily = false
    let restarted = h.model()
    restarted.resumeEnrollment()
    try restarted.verify(TestPIN.primary)
    XCTAssertEqual(restarted.sheet, .setup)
    XCTAssertTrue(restarted.state.needsReselection)
    XCTAssertFalse(restarted.state.setupComplete)
    XCTAssertEqual(h.scheduler.dailyAttempts, 1)
    XCTAssertThrowsError(
      try restarted.install(h.policy, authorization: h.pin.verify(TestPIN.primary, operation: .policy)))
    XCTAssertFalse(try h.database!.load().setupComplete)
  }
  func testGivenFirstEnrollmentFailure_WhenDismissedOrRelaunched_ThenCurrentPINCompletesSavedPolicy() throws {
    for relaunch in [false, true] {
      let h = try NativeHarness(completedSetup: false)
      defer { h.cleanUp() }
      let model = h.model()
      model.showingSetup = true
      h.scheduler.failDaily = true
      XCTAssertThrowsError(try model.enroll(h.policy, pin: TestPIN.primary, confirmation: TestPIN.primary))
      model.refresh()
      XCTAssertFalse(model.needsControlRepair)
      XCTAssertTrue(model.hasCredential)
      XCTAssertFalse(model.state.setupComplete)
      XCTAssertEqual(model.state.pendingPolicy, h.policy)
      XCTAssertEqual(h.projections.last, ShieldProjection(exceptions: [], isOpen: false))
      let credential = try XCTUnwrap(h.credentials.credential)
      model.showingSetup = false
      h.scheduler.failDaily = false
      let recovered = relaunch ? h.model() : model
      let host = UIHostingController(rootView: QuietRootView().environmentObject(recovered))
      host.loadViewIfNeeded()
      recovered.refresh()
      XCTAssertFalse(recovered.needsControlRepair)
      XCTAssertNil(recovered.sheet)
      XCTAssertEqual(h.scheduler.dailyAttempts, 1)
      XCTAssertThrowsError(try recovered.enroll(h.policy, pin: TestPIN.wrong, confirmation: TestPIN.wrong))
      recovered.resumeEnrollment()
      XCTAssertEqual(recovered.sheet, .pin)
      XCTAssertThrowsError(try recovered.verify(TestPIN.zero))
      XCTAssertEqual(recovered.sheet, .pin)
      XCTAssertEqual(h.credentials.credential?.failedAttempts, 1)
      XCTAssertFalse(try h.database!.load().setupComplete)
      XCTAssertEqual(h.scheduler.dailyAttempts, 1)
      try recovered.verify(TestPIN.primary)
      XCTAssertNil(recovered.sheet)
      XCTAssertTrue(recovered.state.setupComplete)
      XCTAssertEqual(recovered.state.policy, h.policy)
      XCTAssertNil(recovered.state.pendingPolicy)
      XCTAssertTrue(recovered.state.dailyRegistered)
      XCTAssertNil(recovered.activeLease)
      XCTAssertFalse(h.projections.last!.isOpen)
      XCTAssertEqual(h.credentials.credential?.derivedKey, credential.derivedKey)
      XCTAssertEqual(h.scheduler.dailyAttempts, 2)
    }
  }
  func testGivenCredentialWriteInterruption_WhenRelaunched_ThenSavedIntentRequiresCurrentPIN() throws {
    let h = try NativeHarness(completedSetup: false)
    defer { h.cleanUp() }
    let model = h.model()
    h.credentials.afterEnrollment = {
      XCTAssertEqual(try h.database!.load().pendingPolicy, h.policy)
      XCTAssertEqual(h.projections.last, ShieldProjection(exceptions: [], isOpen: false))
      XCTAssertEqual(h.scheduler.dailyAttempts, 0)
      throw QuietError.unavailable
    }
    XCTAssertThrowsError(try model.enroll(h.policy, pin: TestPIN.primary, confirmation: TestPIN.primary))
    h.credentials.afterEnrollment = nil
    let restarted = h.model()
    XCTAssertFalse(restarted.needsControlRepair)
    XCTAssertTrue(restarted.hasCredential)
    XCTAssertEqual(restarted.state.pendingPolicy, h.policy)
    XCTAssertFalse(restarted.state.setupComplete)
    XCTAssertEqual(h.scheduler.dailyAttempts, 0)
    restarted.resumeEnrollment()
    XCTAssertEqual(restarted.sheet, .pin)
    XCTAssertThrowsError(try restarted.verify(TestPIN.zero))
    XCTAssertFalse(restarted.state.setupComplete)
    try restarted.verify(TestPIN.primary)
    XCTAssertTrue(restarted.state.setupComplete)
    XCTAssertEqual(restarted.state.policy, h.policy)
    XCTAssertEqual(h.scheduler.dailyAttempts, 1)
  }
  func testGivenIntentBeforeCredential_WhenRelaunched_ThenInitialEnrollmentCanFinish() throws {
    let h = try NativeHarness(completedSetup: false)
    defer { h.cleanUp() }
    try h.coordinator!.prepareEnrollment(h.policy)
    let restarted = h.model()
    XCTAssertFalse(restarted.needsControlRepair)
    XCTAssertFalse(restarted.hasCredential)
    XCTAssertEqual(restarted.state.pendingPolicy, h.policy)
    restarted.resumeEnrollment()
    XCTAssertNil(restarted.sheet)
    try restarted.enroll(h.policy, pin: TestPIN.primary, confirmation: TestPIN.primary)
    XCTAssertTrue(restarted.state.setupComplete)
    XCTAssertEqual(restarted.state.policy, h.policy)
  }
  func testGivenIncompleteEnrollmentJournal_WhenMissingOrEmpty_ThenRepairCannotRetry() throws {
    for empty in [false, true] {
      let h = try NativeHarness(completedSetup: false)
      defer { h.cleanUp() }
      var model: QuietModel? = h.model()
      h.scheduler.failDaily = true
      XCTAssertThrowsError(try model!.enroll(h.policy, pin: TestPIN.primary, confirmation: TestPIN.primary))
      let credential = try XCTUnwrap(h.credentials.credential)
      model = nil
      try h.removeJournal(empty: empty)
      h.scheduler.failDaily = false
      let restarted = h.model()
      XCTAssertTrue(restarted.needsControlRepair)
      XCTAssertNil(restarted.database)
      restarted.resumeEnrollment()
      XCTAssertNil(restarted.sheet)
      XCTAssertThrowsError(try restarted.enroll(h.policy, pin: TestPIN.wrong, confirmation: TestPIN.wrong))
      XCTAssertEqual(h.projections.last, ShieldProjection(exceptions: [], isOpen: false))
      XCTAssertEqual(h.credentials.credential?.derivedKey, credential.derivedKey)
      XCTAssertEqual(h.scheduler.dailyAttempts, 1)
      XCTAssertThrowsError(try ControlDatabase(directory: h.directory))
    }
  }
  func testGivenLostOpenLeaseJournal_WhenCallbackOrForeground_ThenRepairAndCredentialPreserved() throws {
    for empty in [false, true] {
      for callback in [false, true] {
        let h = try NativeHarness()
        defer { h.cleanUp() }
        try h.grant()
        let lease = try XCTUnwrap(h.database!.load().openLease)
        let credential = try XCTUnwrap(h.credentials.credential)
        XCTAssertTrue(h.projections.last!.isOpen)
        try h.removeJournal(empty: empty)
        h.clock.now = lease.expiresAt
        if callback {
          XCTAssertThrowsError(
            try ApplePolicy.handleCallback(
              activity: lease.activityName, didEnd: true,
              databaseFactory: { try ControlDatabase(directory: h.directory) },
              coordinatorFactory: h.makeCoordinator,
              repair: { h.projections.append(ShieldProjection(exceptions: [], isOpen: false)) }))
        } else {
          let model = h.model()
          XCTAssertTrue(model.needsControlRepair)
          XCTAssertNil(model.database)
          XCTAssertNil(model.sheet)
        }
        XCTAssertEqual(h.projections.last, ShieldProjection(exceptions: [], isOpen: false))
        XCTAssertEqual(h.credentials.credential?.derivedKey, credential.derivedKey)
        XCTAssertEqual(h.credentials.credential?.failedAttempts, credential.failedAttempts)
        _ = try h.pin.verify(TestPIN.primary, operation: .lease)
        XCTAssertThrowsError(try ControlDatabase(directory: h.directory))
      }
    }
  }
  func testGivenSurvivingCredentialAndFreshJournal_WhenForeground_ThenRepairWithoutEnrollment() throws {
    let h = try NativeHarness()
    defer { h.cleanUp() }
    try h.removeJournal(empty: false)
    try FileManager.default.removeItem(at: h.directory)
    let model = h.model()
    XCTAssertTrue(model.needsControlRepair)
    XCTAssertFalse(model.state.setupComplete)
    XCTAssertTrue(model.hasCredential)
    XCTAssertEqual(h.projections.last, ShieldProjection(exceptions: [], isOpen: false))
    XCTAssertNil(model.sheet)
  }
  func testGivenWholeStateLossAndCallback_WhenCredentialAlsoMissing_ThenRepairRemainsOnForeground() throws {
    let h = try NativeHarness()
    defer { h.cleanUp() }
    try h.grant()
    let lease = try XCTUnwrap(h.database!.load().openLease)
    try h.removeJournal(empty: false)
    try FileManager.default.removeItem(at: h.directory)
    h.credentials.credential = nil
    h.clock.now = lease.expiresAt
    XCTAssertThrowsError(
      try ApplePolicy.handleCallback(
        activity: lease.activityName, didEnd: true,
        databaseFactory: { try ControlDatabase(directory: h.directory) },
        coordinatorFactory: h.makeCoordinator,
        repair: { h.projections.append(ShieldProjection(exceptions: [], isOpen: false)) }))
    let model = h.model()
    XCTAssertTrue(model.needsControlRepair)
    XCTAssertTrue(model.state.needsReselection)
    XCTAssertFalse(model.hasCredential)
    XCTAssertEqual(h.projections.last, ShieldProjection(exceptions: [], isOpen: false))
    XCTAssertNil(model.sheet)
  }
  func testGivenHistoryInitializationFailure_WhenUsingCoreActions_ThenPINLockAndRoutingStillWork() throws {
    let h = try NativeHarness()
    defer { h.cleanUp() }
    var fail = true
    let model = h.model {
      if fail { throw QuietError.unavailable }
      return try ModelContainer(
        for: UnlockInterval.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
    let before = try h.database!.load()
    model.retryHistory()
    XCTAssertNotNil(model.historyError)
    XCTAssertNil(model.historyContainer)
    XCTAssertFalse(model.needsControlRepair)
    XCTAssertEqual(try h.database!.load(), before)
    // Mount the same root used by the app with no SwiftData container.
    let host = UIHostingController(rootView: QuietRootView().environmentObject(model))
    host.loadViewIfNeeded()
    model.askGuardian()
    XCTAssertEqual(model.sheet, .pin)
    try model.verify(TestPIN.primary)
    XCTAssertEqual(model.sheet, .duration)
    model.grant(.quarterHour)
    XCTAssertNotNil(model.activeLease)
    model.route(.more)
    XCTAssertEqual(model.page, .status)
    model.route(.allApps)
    XCTAssertEqual(model.page, .status)
    model.lockNow()
    XCTAssertNil(model.activeLease)
    XCTAssertFalse(h.projections.last!.isOpen)
    XCTAssertNotNil(model.historyError)
    fail = false
    model.retryHistory()
    XCTAssertNil(model.historyError)
    let context = try XCTUnwrap(model.historyContainer?.mainContext)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<UnlockInterval>()), 1)
    XCTAssertEqual(try h.database!.load().policy, before.policy)
  }
  func testGivenForegroundLease_WhenDeadlinePassesWithoutCallback_ThenStatusAndHistoryRefresh() throws {
    let h = try NativeHarness()
    defer { h.cleanUp() }
    try h.grant()
    let model = h.model()
    model.retryHistory()
    let lease = try XCTUnwrap(model.activeLease)
    h.clock.now = lease.expiresAt.addingTimeInterval(-1)
    model.foregroundTick()
    XCTAssertNotNil(model.activeLease)
    h.clock.now = lease.expiresAt
    model.foregroundTick()
    XCTAssertNil(model.activeLease)
    XCTAssertNil(model.state.openLease)
    XCTAssertFalse(h.projections.last!.isOpen)
    model.askGuardian()
    XCTAssertEqual(model.sheet, .pin)
    let items = try model.historyContainer!.mainContext.fetch(FetchDescriptor<UnlockInterval>())
    XCTAssertEqual(items.first?.earlyEnd, lease.expiresAt)
    let revision = try h.database!.load().revision
    model.foregroundTick()
    XCTAssertEqual(try h.database!.load().revision, revision)
  }
  func testGivenForegroundModel_WhenMonitorEndsLease_ThenReloadsWithoutSceneTransition() throws {
    let h = try NativeHarness()
    defer { h.cleanUp() }
    try h.grant()
    let model = h.model()
    model.retryHistory()
    let lease = try XCTUnwrap(model.activeLease)
    h.clock.now = h.clock.now.addingTimeInterval(120)
    try h.coordinator!.callback(activity: lease.activityName, didEnd: true)
    XCTAssertNotNil(model.activeLease)  // Still cached until the next observation tick.
    model.foregroundTick()
    XCTAssertNil(model.activeLease)
    XCTAssertEqual(model.state.leases.last?.endedAt, h.clock.now)
    let items = try model.historyContainer!.mainContext.fetch(FetchDescriptor<UnlockInterval>())
    XCTAssertEqual(items.first?.earlyEnd, h.clock.now)
  }
  func testPresentationPrioritizesUnresolvedApprovalAndInvalidStateOverActiveLease() throws {
    let h = try NativeHarness()
    defer { h.cleanUp() }
    try h.grant()
    let model = h.model()
    XCTAssertEqual(model.presentation, .active(try XCTUnwrap(model.activeLease).expiresAt))
    h.unresolvedApproval = true
    XCTAssertEqual(model.presentation, .checking)
    h.unresolvedApproval = false
    h.isApproved = false
    model.refresh()
    XCTAssertEqual(model.presentation, .permissionNeeded)
    model.needsControlRepair = true
    XCTAssertEqual(model.presentation, .setupUnavailable)
  }
  func testHistoryFailureLeavesLockedPresentationAndRestrictionsIntact() throws {
    let h = try NativeHarness()
    defer { h.cleanUp() }
    let model = h.model(historyFactory: { throw QuietError.unavailable })
    let before = try h.database!.load()
    model.retryHistory()
    XCTAssertNotNil(model.historyError)
    XCTAssertEqual(model.presentation, .locked)
    XCTAssertEqual(try h.database!.load(), before)
  }
  private func fixtureVerifier() throws -> PINVerifier {
    let verifier = PINVerifier(
      store: FixtureCredentials(), clock: Date.init,
      salt: { Data(repeating: 7, count: 32) },
      derive: { text, _, _ in Data(repeating: text == TestPIN.primary ? 1 : 2, count: 32) })
    _ = try verifier.enroll(TestPIN.primary, confirmation: TestPIN.primary, setupComplete: false)
    return verifier
  }
  func testGivenPINSheet_WhenVerifiedAndBackgrounded_ThenDurationShownAndAuthorizationDiscarded() throws {
    let model = QuietModel(pin: try fixtureVerifier())
    model.askGuardian()
    XCTAssertEqual(model.sheet, .pin)
    try model.verify(TestPIN.primary)
    XCTAssertEqual(model.sheet, .duration)
    model.background()
    XCTAssertNil(model.sheet)
    model.grant(.quarterHour)
    XCTAssertEqual(model.error, QuietError.expiredAuthorization.localizedDescription)
  }
  func testGivenCorrectPIN_WhenGuardedActionFails_ThenVisibleErrorAndSheetClosed() throws {
    let model = QuietModel(pin: try fixtureVerifier())
    model.request(.policy) { _ in throw QuietError.unavailable }
    try model.verify(TestPIN.primary)
    XCTAssertNil(model.sheet)
    XCTAssertEqual(model.error, QuietError.unavailable.localizedDescription)
  }
  func testFailedLockNeverShowsLockedUntilRestrictionProjectionSucceeds() throws {
    let h = try NativeHarness()
    defer { h.cleanUp() }
    try h.grant()
    let model = h.model()
    h.failProjection = true
    model.lockNow()
    XCTAssertEqual(model.presentation, .checkRestrictions)
    XCTAssertNil(model.activeLease)
    h.failProjection = false
    model.refresh()
    XCTAssertEqual(model.presentation, .locked)
  }
  func testNoOpSaveAndCancelledEditNeverRewritePolicyOrClearHistory() throws {
    let h = try NativeHarness()
    defer { h.cleanUp() }
    try h.grant()
    let model = h.model()
    model.retryHistory()
    let before = try h.database!.load()
    model.editPolicy()
    XCTAssertEqual(model.sheet, .pin)
    model.cancelGuardian()
    XCTAssertEqual(try h.database!.load(), before)
    model.editPolicy()
    try model.verify(TestPIN.primary)
    XCTAssertEqual(model.sheet, .setup)
    let draft = try BulkSetupDraft(policy: h.policy).policy(previous: h.policy)
    try model.savePolicy(draft)
    XCTAssertNil(model.sheet)
    XCTAssertEqual(try h.database!.load(), before)
    XCTAssertEqual(try model.historyContainer!.mainContext.fetchCount(FetchDescriptor<UnlockInterval>()), 1)
  }
  func testPendingConfirmationRejectsDuplicateTapAndBackgroundCancellation() async throws {
    let h = try NativeHarness()
    defer { h.cleanUp() }
    let model = h.model()
    model.askGuardian()
    try model.verify(TestPIN.primary)
    model.confirmGrant()
    model.confirmGrant()
    XCTAssertTrue(model.granting)
    model.background()
    for _ in 0..<8 { await Task.yield() }
    XCTAssertNil(try h.database!.load().openLease)
    XCTAssertNil(model.sheet)
    XCTAssertFalse(model.granting)
    model.askGuardian()
    try model.verify(TestPIN.primary)
    let draft = try XCTUnwrap(model.grantDraft)
    model.confirmGrant()
    model.confirmGrant()
    for _ in 0..<8 { await Task.yield() }
    XCTAssertEqual(try h.database!.load().leases.filter { $0.activatedAt != nil }.count, 1)
    XCTAssertEqual(model.activeLease?.expiresAt, draft.expiresAt)
  }

  func testNativeDarkScreensAndHistorySelectionAtStandardAndAccessibilitySizes() async throws {
    let h = try NativeHarness(now: ISO8601DateFormatter().date(from: "2026-10-05T18:00:00Z")!)
    defer { h.cleanUp() }
    h.policy.allowed = (0..<44).map {
      AppEntry(id: "saved-\($0)", label: "Saved app \($0 + 1)", token: "fixture-allowed-\($0)")
    }
    for i in h.policy.limits.indices { h.policy.limits[i].app.label = "Saved limited app \(i + 1)" }
    try h.coordinator!.install(h.policy, authorization: h.pin.verify(TestPIN.primary, operation: .policy))
    let model = h.model()
    model.retryHistory()
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: scene)
    defer {
      window.isHidden = true
      previous?.makeKeyAndVisible()
    }
    func scrollView(_ view: UIView) -> UIScrollView? {
      if let scroll = view as? UIScrollView { return scroll }
      return view.subviews.compactMap { scrollView($0) }.first
    }
    let captures = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("NativeScreenCapture/\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
    func capture<V: View>(
      _ view: V, _ name: String, size: DynamicTypeSize = .large,
      system: UIUserInterfaceStyle = .light, navigation: Bool = true, scrollToBottom: Bool = false
    ) async throws {
      window.overrideUserInterfaceStyle = system
      let content = AnyView(view)
      let hosted = AnyView(
        Group {
          if navigation { NavigationStack { content } } else { content }
        }.environmentObject(model).foregroundStyle(QuietDesign.ink).tint(QuietDesign.ink)
          .background(QuietDesign.paper.ignoresSafeArea()).preferredColorScheme(.dark).dynamicTypeSize(size))
      let host = UIHostingController(rootView: hosted)
      window.rootViewController = host
      window.makeKeyAndVisible()
      try await Task.sleep(for: .milliseconds(180))
      host.view.layoutIfNeeded()
      if scrollToBottom, let scroll = scrollView(host.view) {
        XCTAssertGreaterThan(scroll.contentSize.height, 0)
        XCTAssertLessThanOrEqual(scroll.bounds.width, host.view.bounds.width)
        scroll.setContentOffset(
          CGPoint(
            x: 0,
            y: max(
              -scroll.adjustedContentInset.top,
              scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)),
          animated: false)
        try await Task.sleep(for: .milliseconds(100))
      }
      // simctl captures the native compositor; XCTest screen automation is unavailable
      // inside an app-hosted unit bundle. The runner acknowledges this test-only request.
      try await Task.sleep(for: .milliseconds(200))
      let name = "calm-\(name)"
      let ready = captures.appendingPathComponent(name + ".ready")
      let ack = captures.appendingPathComponent(name + ".ack")
      try JSONSerialization.data(withJSONObject: [
        "name": name, "dynamicType": String(describing: size),
        "systemAppearance": system == .light ? "light" : "dark",
      ]).write(to: ready, options: .atomic)
      // Allow the bounded simulator capture command to finish on a busy CI host.
      // The view stays presented until the compositor image is acknowledged.
      for _ in 0..<600 {
        if FileManager.default.fileExists(atPath: ack.path) { break }
        try await Task.sleep(for: .milliseconds(100))
      }
      guard FileManager.default.fileExists(atPath: ack.path) else {
        XCTFail("Native screenshot helper did not acknowledge \(name)")
        throw QuietError.unavailable
      }
      let attachment = XCTAttachment(
        data: try Data(contentsOf: captures.appendingPathComponent(name + ".png")),
        uniformTypeIdentifier: "public.png")
      attachment.name = name
      attachment.lifetime = .keepAlways
      add(attachment)
      XCTAssertEqual(host.traitCollection.userInterfaceStyle, .dark)
    }
    let before = try h.database!.load()
    try await capture(StatusView(), "locked-system-light")
    try await capture(StatusView(), "locked-system-dark", system: .dark)
    try await capture(StatusView(), "locked-accessibility5-top", size: .accessibility5)
    try await capture(
      StatusView(), "locked-accessibility5-bottom", size: .accessibility5, scrollToBottom: true)
    try await capture(SettingsView(), "settings")
    let colourModel = ColourSettingsModel(
      readState: { ColourState() },
      readDecision: { try ColourDecision.evaluate(now: h.clock.now) })
    try await capture(ColourView(model: colourModel), "colour-phone-setup")
    try await capture(ColourSetupView(), "colour-setup-actions")
    try await capture(ColourView(model: colourModel), "colour-accessibility5-top", size: .accessibility5)
    try await capture(
      ColourView(model: colourModel), "colour-accessibility5-bottom", size: .accessibility5,
      scrollToBottom: true)
    try await capture(AppsAndLimitsView(), "apps-and-limits")
    try await capture(AllowedAppsView(), "allowed-apps")
    XCTAssertEqual(try h.database!.load(), before)
    // Remote unlock on this phone (review chapter 9).
    try await capture(UnlockMethodsView(), "unlock-methods-pin-only")
    try await capture(AddRemoteView(message: .constant("")), "add-remote")
    let pairedRemote = try model.addRemote(name: "Helper", ownerName: "Owner")
    try await capture(SettingsView(), "settings-with-remote")
    try await capture(UnlockMethodsView(), "unlock-methods")
    try await capture(RemoteDetailView(remote: pairedRemote, message: .constant("")), "remote-detail")
    // Their phone (review chapter 10): first launch, connected, unlock others.
    let other = try NativeHarness(completedSetup: false, now: h.clock.now)
    defer { other.cleanUp() }
    let theirs = other.model()
    XCTAssertEqual(theirs.presentation, .firstLaunch)
    try await capture(FirstLaunchView().environmentObject(theirs), "first-launch")
    try await capture(
      FirstLaunchView().environmentObject(theirs), "first-launch-accessibility5", size: .accessibility5)
    theirs.open(model.connectURL(for: pairedRemote))
    let connected = try XCTUnwrap(theirs.linkOutcome)
    try await capture(
      ConnectedView(outcome: connected).environmentObject(theirs), "connected", navigation: false)
    theirs.linkOutcome = nil
    XCTAssertEqual(theirs.presentation, .unlockOthers)
    try await capture(UnlockOthersView().environmentObject(theirs), "unlock-others")
    try await capture(
      UnlockOthersView().environmentObject(theirs), "unlock-others-accessibility5-bottom",
      size: .accessibility5,
      scrollToBottom: true)
    // Back on this phone: the link unlocks everything, attributed to Helper, and Lock now needs no PIN.
    let connection = try XCTUnwrap(theirs.connections.connections.first)
    model.open(try theirs.unlockURL(for: connection, choice: .hour))
    XCTAssertNil(model.error)
    XCTAssertEqual(model.activeLease?.remoteName, "Helper")
    try await capture(StatusView(), "active-by-remote")
    try await capture(UnlockMethodsView(), "unlock-methods-after-unlock")
    model.lockNow()
    XCTAssertNil(model.activeLease)
    model.askGuardian()
    try await capture(PINView(), "pin", navigation: false)
    try await capture(PINView(), "pin-accessibility5-top", size: .accessibility5, navigation: false)
    try await capture(
      PINView(), "pin-accessibility5-bottom", size: .accessibility5, navigation: false, scrollToBottom: true)
    try model.verify(TestPIN.primary)
    for choice in LeaseChoice.allCases {
      model.prepareGrant(choice)
      try await capture(DurationView(), "duration-\(choice.rawValue)", navigation: false)
    }
    try await capture(DurationView(), "duration-midnight-bottom", navigation: false, scrollToBottom: true)
    try await capture(
      DurationView(), "duration-accessibility5-bottom", size: .accessibility5, navigation: false,
      scrollToBottom: true)
    model.grant(.midnight)
    XCTAssertNotNil(model.activeLease)
    try await capture(StatusView(), "active-midnight")
    model.lockNow()
    h.clock.now = Calendar.current.date(bySettingHour: 23, minute: 50, second: 0, of: h.clock.now)!
    model.refresh()
    model.askGuardian()
    try model.verify(TestPIN.primary)
    try await capture(DurationView(), "midnight-unavailable", navigation: false)
    model.cancelGuardian()
    for _ in 0..<5 { XCTAssertThrowsError(try h.pin.verify(TestPIN.zero, operation: .lease)) }
    try await capture(PINView(), "pin-lockout", navigation: false)
    h.clock.now += 901
    _ = try h.pin.verify(TestPIN.primary, operation: .replacePIN)
    model.refresh()
    model.replacePIN()
    try model.verify(TestPIN.primary)
    try await capture(NewPINView(), "new-pin", navigation: false)
    model.cancelGuardian()
    model.needsControlRepair = true
    try await capture(RecoveryView(), "setup-unavailable")
    model.needsControlRepair = false
    h.unresolvedApproval = true
    try await capture(RecoveryView(), "checking")
    h.unresolvedApproval = false
    h.isApproved = false
    try await capture(RecoveryView(), "permission-needed")
    h.isApproved = true
    h.failProjection = true
    model.refresh()
    model.error = nil
    try await capture(RecoveryView(), "check-restrictions")
    h.failProjection = false
    model.refresh()
    let saved = try NativeHarness(completedSetup: false)
    defer { saved.cleanUp() }
    saved.scheduler.failDaily = true
    let unfinished = saved.model()
    XCTAssertThrowsError(
      try unfinished.enroll(saved.policy, pin: TestPIN.primary, confirmation: TestPIN.primary))
    // Use the production recovery view with an injected saved-enrollment model.
    let savedView = RecoveryView().environmentObject(unfinished)
    try await capture(savedView, "finish-saved-setup")
    let failing = h.model(historyFactory: { throw QuietError.unavailable })
    failing.retryHistory()
    try await capture(HistoryUnavailableView().environmentObject(failing), "history-unavailable")
    let container = try ModelContainer(
      for: UnlockInterval.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    h.clock.now = ISO8601DateFormatter().date(from: "2026-10-05T18:00:00Z")!
    let historyState = HistorySelection()
    let history = HistoryView(now: h.clock.now, selection: historyState).modelContainer(container)
      .navigationTitle("History")
    try await capture(history, "history-empty")
    var historyControl = ControlState()
    for (offset, records) in [
      (0, [(1155, 1170)]), (1, [(750, 765), (1200, 1260)]),
      (3, [(1080, 1100)]), (4, [(510, 525), (1080, 1110)]), (6, [(540, 555)]),
    ] {
      let day = CivilTime.calendar.date(
        byAdding: .day, value: -offset, to: CivilTime.calendar.startOfDay(for: h.clock.now))!
      for (start, end) in records {
        var lease = Lease(now: day + Double(start * 60), expiresAt: day + Double(end * 60))
        lease.activatedAt = lease.requestedAt
        lease.state = .ended
        if offset == 1 && start == 1200 { lease.remoteName = "Helper" }
        historyControl.leases.append(lease)
      }
    }
    try HistoryProjection.replay(historyControl, into: container.mainContext, now: h.clock.now)
    historyState.selected = CivilTime.calendar.date(
      byAdding: .day, value: -1, to: CivilTime.calendar.startOfDay(for: h.clock.now))!
    let selected = historyState.selected
    try await capture(history, "history-time-selected-day")
    try await capture(history, "history-remote-attribution")
    historyState.measure = 1
    try await capture(history, "history-count-selected-day")
    XCTAssertEqual(historyState.selected, selected)
    try await capture(history, "history-accessibility5-top", size: .accessibility5)
    try await capture(history, "history-accessibility5-bottom", size: .accessibility5, scrollToBottom: true)
    historyState.offset = 28
    historyState.selected = nil
    try await capture(history, "history-oldest-two-days")
    try Data("complete\n".utf8).write(to: captures.appendingPathComponent("complete"))
  }
  func testNativeScheduleComponentsPreserveAbsoluteDraftAcrossTimeZonesAndRepeatedDSTHour() throws {
    for zone in ["Europe/Brussels", "America/New_York", "Pacific/Honolulu"] {
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = TimeZone(identifier: zone)!
      for timestamp in ["2026-10-25T00:50:00Z", "2026-10-25T01:30:00Z", "2026-11-01T06:30:00Z"] {
        let now = ISO8601DateFormatter().date(from: timestamp)!
        for choice in LeaseChoice.allCases {
          let draft = try GrantDraft.prepare(choice, now: now, calendar: calendar)
          let lease = Lease(now: draft.requestedAt, expiresAt: draft.expiresAt)
          let schedule = try AppleScheduler.leaseSchedule(lease)
          XCTAssertEqual(schedule.intervalStart.date, draft.requestedAt)
          XCTAssertEqual(schedule.intervalEnd.date, draft.expiresAt)
          XCTAssertFalse(schedule.repeats)
          XCTAssertEqual(
            schedule.intervalEnd.date!.timeIntervalSince(schedule.intervalStart.date!),
            draft.expiresAt.timeIntervalSince(draft.requestedAt))
        }
      }
    }
    XCTAssertEqual(CivilTime.calendar.timeZone.identifier, "Europe/Brussels")
  }
  func testGivenHistoryConfiguration_WhenCreated_ThenAppPrivateAndNoCloud() throws {
    let configuration = try HistoryProjection.configuration()
    let support = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true)
    XCTAssertTrue(configuration.url.path.hasPrefix(support.path + "/QuietHistory/"))
    XCTAssertNil(configuration.groupAppContainerIdentifier)
    XCTAssertNil(configuration.cloudKitContainerIdentifier)
  }
  func testGivenSalt_WhenGeneratedTwice_ThenIndependentEntropy() throws {
    let first = try PINStore.salt()
    let second = try PINStore.salt()
    XCTAssertEqual(first.count, 32)
    XCTAssertEqual(second.count, 32)
    XCTAssertNotEqual(first, second)
  }
  func testGivenSyntheticPIN_WhenDerived_ThenMatchesPBKDF2Vector() throws {
    let key = try PINStore.derive(TestPIN.derivation, salt: Data(repeating: 7, count: 32), rounds: 100_000)
    let hex = key.map { String(format: "%02x", $0) }.joined()
    // Independently calculated with Python's hashlib.pbkdf2_hmac for this synthetic input.
    XCTAssertEqual(hex, "0168827974bdd10c4a870d5974b9d830a665081c8deaabc9e68cc349c69137f1")
    XCTAssertNotEqual(
      key, try PINStore.derive(TestPIN.alternate, salt: Data(repeating: 7, count: 32), rounds: 100_000))
  }
  func testGivenProjection_WhenReplayed_ThenNoDuplicateHistoryAndEarlyEndUpdated() throws {
    let container = try ModelContainer(
      for: UnlockInterval.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let context = container.mainContext
    let now = Date()
    var lease = Lease(now: now, expiresAt: now.addingTimeInterval(900))
    lease.activatedAt = now
    lease.state = .active
    var state = ControlState()
    state.leases = [lease]
    try HistoryProjection.replay(state, into: context, now: now)
    state.leases[0].endedAt = now.addingTimeInterval(120)
    state.leases[0].state = .ended
    try HistoryProjection.replay(state, into: context, now: now)
    try HistoryProjection.replay(state, into: context, now: now)
    let items = try context.fetch(FetchDescriptor<UnlockInterval>())
    XCTAssertEqual(items.count, 1)
    XCTAssertEqual(items[0].earlyEnd, now.addingTimeInterval(120))
  }
  func testGivenOldHistory_WhenReplayed_ThenOutsideThirtyDaysRemoved() throws {
    let container = try ModelContainer(
      for: UnlockInterval.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let now = Date()
    let old = now.addingTimeInterval(-35 * 86_400)
    var lease = Lease(now: old, expiresAt: old.addingTimeInterval(900))
    lease.activatedAt = old
    lease.state = .ended
    var state = ControlState()
    state.leases = [lease]
    try HistoryProjection.replay(state, into: container.mainContext, now: now)
    XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<UnlockInterval>()), 0)
  }
}
