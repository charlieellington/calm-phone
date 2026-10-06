import FamilyControls
import QuietCore
import SwiftData
import SwiftUI
import UIKit

enum GuardianSheet: String, Identifiable {
  case setup, pin, duration, newPIN
  var id: String { rawValue }
}

@MainActor final class QuietModel: ObservableObject {
  @Published var state = ControlState()
  @Published var error: String?
  @Published var page = HomeRoute.status
  @Published var sheet: GuardianSheet?
  var showingSetup: Bool {
    get { sheet == .setup }
    set { if newValue { sheet = .setup } else if sheet == .setup { sheet = nil } }
  }
  var showingDuration: Bool {
    get { sheet == .duration }
    set { if newValue { sheet = .duration } else if sheet == .duration { sheet = nil } }
  }
  var showingNewPIN: Bool {
    get { sheet == .newPIN }
    set { if newValue { sheet = .newPIN } else if sheet == .newPIN { sheet = nil } }
  }
  @Published private(set) var checkingScreenTime = false
  private let screenTimeApproval: () -> Bool?
  @Published private(set) var restrictionsUnconfirmed = false
  @Published var hasCredential = false
  @Published var needsControlRepair = false
  @Published private(set) var grantDraft: GrantDraft?
  @Published private(set) var granting = false
  @Published var now: Date
  @Published private(set) var historyContainer: ModelContainer?
  @Published private(set) var historyError: String?
  private(set) var database: ControlDatabase?
  private(set) var coordinator: PolicyCoordinator?
  let pin: PINVerifier
  var operation = GuardianOperation.lease
  private var onVerified: ((GuardianAuthorization) throws -> Void)?
  private var authorization: GuardianAuthorization?
  private let clock: () -> Date
  private let historyFactory: @MainActor () throws -> ModelContainer
  private let repair: () -> Void
  private let validatePolicy: (Policy) throws -> Void
  private let requestScreenTimeAuthorization: @MainActor () async throws -> Void

  init(
    pin: PINVerifier? = nil,
    clock: @escaping () -> Date = Date.init,
    databaseFactory: () throws -> ControlDatabase = SharedContainer.database,
    coordinatorFactory: (ControlDatabase) -> PolicyCoordinator = ApplePolicy.coordinator,
    historyFactory: @escaping @MainActor () throws -> ModelContainer = HistoryProjection.container,
    repair: @escaping () -> Void = { if ApplePolicy.approved { ApplePolicy.closeForRepair() } },
    validatePolicy: @escaping (Policy) throws -> Void = TokenCodec.validate,
    screenTimeApproval: @escaping () -> Bool? = { ApplePolicy.authorizationApproval },
    requestScreenTimeAuthorization: @escaping @MainActor () async throws -> Void = {
      try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
    }
  ) {
    self.clock = clock
    self.now = clock()
    self.historyFactory = historyFactory
    self.repair = repair
    self.validatePolicy = validatePolicy
    self.requestScreenTimeAuthorization = requestScreenTimeAuthorization
    self.screenTimeApproval = screenTimeApproval
    self.pin =
      pin ?? PINVerifier(store: PINStore(), clock: Date.init, salt: PINStore.salt, derive: PINStore.derive)
    do {
      let database = try databaseFactory()
      self.database = database
      coordinator = coordinatorFactory(database)
      refresh()
    } catch {
      needsControlRepair = true
      repair()
      self.error = QuietError.repairRequired.localizedDescription
    }
  }
  func perform(failureMessage: String? = nil, _ action: () throws -> Void) {
    do {
      try action()
      refresh()
    } catch {
      self.error =
        (error as? QuietError) == .unavailable
        ? (failureMessage ?? error.localizedDescription) : error.localizedDescription
      refresh(preserveError: true)
    }
  }
  func refresh(preserveError: Bool = false) {
    now = clock()
    guard let database, let coordinator else { return }
    do {
      // A surviving private credential cannot authorize fresh setup after App Group state loss.
      restrictionsUnconfirmed = false
      state = try database.load()
      hasCredential = try pin.hasCredential()
      guard
        state.setupComplete
          ? hasCredential
          : (state.policy == nil && state.leases.isEmpty
            && (state.pendingPolicy != nil
              || (!hasCredential && !state.needsReselection
                && (state.invalidatedSelectionTokens?.isEmpty ?? true))))
      else {
        throw QuietError.repairRequired
      }
      restrictionsUnconfirmed = true
      try coordinator.reconcile()
      state = try database.load()
      needsControlRepair = false
      restrictionsUnconfirmed = false
    } catch {
      if !restrictionsUnconfirmed { needsControlRepair = true }
      repair()
      if !preserveError { self.error = error.localizedDescription }
      return
    }
    if let historyContainer {
      do {
        try HistoryProjection.replay(state, into: historyContainer.mainContext, now: now)
        historyError = nil
      } catch {
        historyError = "History is unavailable. Try again to replay it."
      }
    }
  }
  func retryHistory() {
    do {
      let container = try historyContainer ?? historyFactory()
      try HistoryProjection.replay(state, into: container.mainContext, now: clock())
      historyContainer = container
      historyError = nil
    } catch {
      historyError = "History is unavailable. Try again to replay it."
    }
  }
  var presentation: RestrictionPresentation {
    if database == nil || needsControlRepair { return .setupUnavailable }
    if checkingScreenTime
      || ((state.setupComplete || state.pendingPolicy != nil) && screenTimeApproval() == nil)
    {
      return .checking
    }
    if (state.setupComplete || state.pendingPolicy != nil) && screenTimeApproval() == false {
      return .permissionNeeded
    }
    if restrictionsUnconfirmed { return .checkRestrictions }
    if !state.setupComplete {
      return hasCredential && state.pendingPolicy != nil ? .finishSetup : .freshSetup
    }
    if state.needsReselection || state.pendingPolicy != nil || !state.dailyRegistered || state.monitorFailed
      || !state.authorizationApproved || !hasCredential
    {
      return .checkRestrictions
    }
    if let lease = activeLease { return .active(lease.expiresAt) }
    return .locked
  }
  var activeLease: Lease? { state.openLease.flatMap { $0.isActive(at: now) ? $0 : nil } }
  func prepareForeground() async {
    refresh()
    guard !needsControlRepair, state.setupComplete || state.pendingPolicy != nil else { return }
    if screenTimeApproval() == nil {
      checkingScreenTime = true
      defer { checkingScreenTime = false }
      do {
        try await requestScreenTimeAuthorization()
        self.error = nil
      } catch {
        self.error = "Screen Time access could not be checked. Try again."
      }
      refresh(preserveError: true)
    }
  }
  func foregroundTick() {
    now = clock()
    guard let database else { return }
    do {
      let fresh = try database.load()
      if screenTimeApproval().map({ $0 != state.authorizationApproved }) == true
        || fresh.revision != state.revision || fresh.openLease.map({ now >= $0.expiresAt }) == true
        || fresh.exhaustedDay != CivilTime.day(now)
      {
        refresh()
      }
    } catch {
      needsControlRepair = true
      repair()
      self.error = error.localizedDescription
    }
  }
  func background() {
    authorization?.invalidate()
    authorization = nil
    grantDraft = nil
    onVerified = nil
    // Keep incomplete setup reachable, but discard every backgrounded guardian capability.
    if sheet != .setup || state.setupComplete { sheet = nil }
  }
  func request(_ operation: GuardianOperation, action: @escaping (GuardianAuthorization) throws -> Void) {
    self.operation = operation
    onVerified = action
    sheet = .pin
  }
  func verify(_ text: String) throws {
    let authorization = try pin.verify(text, operation: operation)
    self.authorization = authorization
    let action = onVerified
    onVerified = nil
    do {
      try action?(authorization)
      if sheet == .pin { sheet = nil }
    } catch {
      authorization.invalidate()
      self.authorization = nil
      sheet = nil
      self.error = error.localizedDescription
      refresh(preserveError: true)
    }
  }
  func askGuardian() {
    request(.lease) { authorization in
      self.authorization = authorization
      self.showingDuration = true
      self.prepareGrant(.quarterHour)
    }
  }
  func lockNow() {
    perform(failureMessage: "Couldn’t confirm app restrictions. Try again.") {
      guard let coordinator else { throw QuietError.repairRequired }
      try coordinator.lockNow()
    }
  }
  func cancelGuardian() {
    background()
    sheet = nil
  }
  var lockoutEndpoint: Date? { try? pin.lockoutEndpoint() }
  func prepareGrant(_ choice: LeaseChoice) {
    do {
      guard let authorization, authorization.isValid(.lease, now: clock()) else {
        throw QuietError.expiredAuthorization
      }
      grantDraft = try GrantDraft.prepare(choice, now: clock())
    } catch {
      grantDraft = nil
      self.error = error.localizedDescription
    }
  }
  func grant(_ choice: LeaseChoice) {
    prepareGrant(choice)
    commitGrant()
  }
  func confirmGrant() {
    guard !granting else { return }
    granting = true
    Task { @MainActor in
      // Let SwiftUI present pending state before the coordinator's serialized transaction.
      await Task.yield()
      defer { granting = false }
      commitGrant()
    }
  }
  private func commitGrant() {
    perform(failureMessage: "Couldn’t unlock. Try again.") {
      defer { self.cancelGuardian() }
      guard let coordinator, let authorization, let grantDraft else { throw QuietError.expiredAuthorization }
      try coordinator.grant(grantDraft, authorization: authorization)
    }
  }
  func editPolicy() {
    request(.policy) { auth in
      self.authorization = auth
      self.showingSetup = true
    }
  }
  func savePolicy(_ policy: Policy) throws {
    if policy == state.policy {
      cancelGuardian()
      return
    }
    if let authorization, authorization.isValid(.policy, now: clock()) {
      defer {
        authorization.invalidate()
        self.authorization = nil
      }
      try install(policy, authorization: authorization)
    } else {
      request(.policy) { auth in try self.install(policy, authorization: auth) }
    }
  }
  func replacePIN() {
    request(.replacePIN) { auth in
      self.authorization = auth
      self.showingNewPIN = true
    }
  }
  func savePIN(_ text: String, confirmation: String) throws {
    guard let authorization else { throw QuietError.expiredAuthorization }
    try PINVerifier.validate(text)
    guard text == confirmation else { throw QuietError.wrongPIN }
    try pin.replace(text, confirmation: confirmation, authorization: authorization)
    authorization.invalidate()
    self.authorization = nil
    showingNewPIN = false
    error = "PIN changed"
  }
  func enroll(_ policy: Policy, pin text: String, confirmation: String) throws {
    guard let database, let coordinator, !needsControlRepair else { throw QuietError.repairRequired }
    let current = try database.load()
    guard !current.setupComplete, !(try pin.hasCredential()) else {
      throw QuietError.repairRequired
    }
    try validatePolicy(policy)
    try PINVerifier.validate(text)
    guard text == confirmation else { throw QuietError.wrongPIN }
    try coordinator.prepareEnrollment(policy)
    let auth = try pin.enroll(text, confirmation: confirmation, setupComplete: current.setupComplete)
    try install(policy, authorization: auth)
  }
  var canRecoverSavedEnrollment: Bool {
    guard let policy = state.pendingPolicy, let coordinator else { return false }
    return (try? coordinator.canRecoverPendingEnrollment(policy)) == true
  }
  func resumeEnrollment() {
    refresh()
    guard !needsControlRepair, !state.setupComplete, hasCredential, state.pendingPolicy != nil else { return }
    request(.policy) { auth in
      guard let database = self.database else { throw QuietError.repairRequired }
      let current = try database.load()
      guard !self.needsControlRepair, !current.setupComplete, let policy = current.pendingPolicy else {
        throw QuietError.repairRequired
      }
      self.refresh()
      guard !self.needsControlRepair else { throw QuietError.repairRequired }
      let recoverable = try self.coordinator?.canRecoverPendingEnrollment(policy) == true
      if self.screenTimeApproval() != true || !self.state.authorizationApproved
        || (self.state.requiresFreshSelection(for: policy) && !recoverable)
      {
        try auth.consume(.policy, now: self.clock())
        self.showingSetup = true
      } else {
        try self.install(policy, authorization: auth)
      }
    }
  }
  func approveScreenTime() async throws {
    refresh()
    guard !needsControlRepair else { throw QuietError.repairRequired }
    do {
      try await requestScreenTimeAuthorization()
      refresh()
    } catch {
      refresh()
      throw error
    }
  }
  func install(_ policy: Policy, authorization: GuardianAuthorization) throws {
    guard let coordinator, !needsControlRepair else { throw QuietError.repairRequired }
    try validatePolicy(policy)
    try coordinator.install(policy, authorization: authorization)
    showingSetup = false
    refresh()
  }
  func route(_ route: HomeRoute) {
    // Recognised cached widget links can only open status. Never launch an app or grant access.
    page = .status
  }
}

@main struct QuietApp: App {
  @StateObject private var model = QuietModel()
  @Environment(\.scenePhase) private var scenePhase
  var body: some Scene {
    WindowGroup {
      QuietRootView().environmentObject(model)
        .onOpenURL { if let route = HomeRoute.parse($0) { model.route(route) } }
        .onChange(of: scenePhase) { _, phase in
          if phase != .active { model.background() }
        }
        .task(id: scenePhase) {
          guard scenePhase == .active else { return }
          await model.prepareForeground()
          // UI observation only; the registered DeviceActivity monitor owns background expiry.
          while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            model.foregroundTick()
          }
        }
    }
  }
}

struct QuietRootView: View {
  @EnvironmentObject private var model: QuietModel
  var body: some View {
    NavigationStack {
      Group {
        switch model.presentation {
        case .locked, .active: StatusView()
        default: RecoveryView()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(QuietDesign.paper.ignoresSafeArea())
      .foregroundStyle(QuietDesign.ink)
    }
    .tint(QuietDesign.sage)
    .preferredColorScheme(.dark)
    .task {
      model.refresh()
      model.retryHistory()
    }
    .sheet(item: $model.sheet) { sheet in
      Group {
        switch sheet {
        case .setup: SetupView()
        case .pin: PINView()
        case .duration: DurationView()
        case .newPIN: NewPINView()
        }
      }.environmentObject(model).preferredColorScheme(.dark)
        .onDisappear { if model.sheet == nil { model.cancelGuardian() } }
    }
    .alert(
      "Calm Phone", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
    ) {
      Button("OK") { model.error = nil }
    } message: {
      Text(model.error ?? "")
    }
  }
}

#Preview {
  QuietRootView().environmentObject(QuietModel())
}
