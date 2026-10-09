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
  // Remote unlock (RemoteModel.swift): who may unlock this phone, and which phones this one may unlock.
  @Published var navigationEpoch = UUID()
  @Published var remoteMetadataError: String?
  @Published var remoteReadError: String?
  @Published var connectionReadError: String?
  @Published var remotes = RemoteRecord()
  @Published var connections = ConnectionRecord()
  @Published var linkOutcome: LinkOutcome?
  @Published var choseRestrict = false
  /// An unlock link opened before Screen Time status resolved; redeemed once it has, dropped on leaving.
  var pendingLink: String?
  let remoteStore: RemoteStorage
  let connectionStore: ConnectionStoring
  private(set) lazy var verifier = RemoteVerifier(store: remoteStore, clock: clock)
  private(set) var database: ControlDatabase?
  private(set) var coordinator: PolicyCoordinator?
  let pin: PINVerifier
  var operation = GuardianOperation.lease
  private var onVerified: ((GuardianAuthorization) throws -> Void)?
  private var authorization: GuardianAuthorization?
  let clock: () -> Date
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
    },
    remoteStore: RemoteStorage = RemoteStore(),
    connectionStore: ConnectionStoring = ConnectionStore()
  ) {
    self.clock = clock
    self.remoteStore = remoteStore
    self.connectionStore = connectionStore
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
    loadRemote()
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
    loadRemote()
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
    reconcileRemoteSuccess()
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
      if hasCredential && state.pendingPolicy != nil { return .finishSetup }
      if choseRestrict || state.pendingPolicy != nil { return .freshSetup }
      // No restriction setup started: a remote's phone, or a fresh install choosing what it is for.
      if connectionReadError != nil { return .remoteUnavailable }
      return connections.connections.isEmpty ? .firstLaunch : .unlockOthers
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
    defer { redeemPendingLink() }
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
    defer { if presentation != .checking { redeemPendingLink() } }
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
  func background(dropPendingLink: Bool = true) {
    authorization?.invalidate()
    authorization = nil
    grantDraft = nil
    onVerified = nil
    if dropPendingLink { pendingLink = nil }
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
      guard coordinator != nil, let authorization, let grantDraft else {
        throw QuietError.expiredAuthorization
      }
      try openLease(grantDraft, authorization: authorization)
    }
  }
  /// The app's one lease path, shared by the PIN and a remote's link.
  func openLease(
    _ draft: GrantDraft, authorization: GuardianAuthorization, remoteName: String? = nil,
    remoteID: String? = nil
  ) throws {
    guard let coordinator else { throw QuietError.repairRequired }
    try coordinator.grant(draft, authorization: authorization, remoteName: remoteName, remoteID: remoteID)
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
  #if DEBUG && targetEnvironment(simulator)
    @StateObject private var model = UITestApp.make()
  #else
    @StateObject private var model = QuietModel()
  #endif
  @Environment(\.scenePhase) private var scenePhase
  var body: some Scene {
    WindowGroup {
      QuietRootView().environmentObject(model)
        .onOpenURL { model.open($0) }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
          if let url = activity.webpageURL { model.open(url) }
        }
        .onChange(of: scenePhase) { _, phase in
          if phase != .active { model.background(dropPendingLink: phase == .background) }
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
        case .firstLaunch: FirstLaunchView()
        case .unlockOthers: UnlockOthersView()
        case .remoteUnavailable: RemoteStorageUnavailableView()
        default: RecoveryView()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(QuietDesign.paper.ignoresSafeArea())
      .foregroundStyle(QuietDesign.ink)
    }
    .id(model.navigationEpoch)
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
        .modifier(QuietErrorAlert(model: model))
        .onDisappear { if model.sheet == nil { model.cancelGuardian() } }
    }
    .fullScreenCover(item: $model.linkOutcome) { outcome in
      ConnectedView(outcome: outcome).environmentObject(model).preferredColorScheme(.dark)
        .modifier(QuietErrorAlert(model: model))
    }
    .modifier(
      QuietErrorAlert(model: model, enabled: model.sheet == nil && model.linkOutcome == nil))
  }
}

/// Present refusals from the visible surface so an alert cannot dismiss an unfinished setup sheet.
private struct QuietErrorAlert: ViewModifier {
  @ObservedObject var model: QuietModel
  var enabled = true
  func body(content: Content) -> some View {
    content.alert(
      "Calm Phone",
      isPresented: Binding(
        get: { enabled && model.error != nil },
        set: { if !$0 && enabled { model.error = nil } })
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

#if DEBUG && targetEnvironment(simulator)
  // Only compiled into Debug simulator builds. UI tests use a real root/navigation stack and private
  // temporary storage; no Screen Time, production Keychain or enforcement writer is invoked.
  private final class UITestCredentials: CredentialStorage {
    var value: Credential?
    func read() throws -> Credential? { value }
    func write(_ credential: Credential, enrolling: Bool) throws { value = credential }
  }
  private final class UITestRemotes: RemoteStorage {
    var value: RemoteRecord?
    func read() throws -> RemoteRecord? { value }
    func write(_ record: RemoteRecord) throws { value = record }
  }
  private final class UITestConnections: ConnectionStoring {
    var value = ConnectionRecord()
    func read() throws -> ConnectionRecord { value }
    func write(_ record: ConnectionRecord) throws { value = record }
  }
  private final class UITestScheduler: ActivityScheduling {
    var names: [String] = []
    func registerDaily(_ policy: Policy) throws { names.append(policy.dailyName) }
    func registerLease(_ lease: Lease) throws { names.append(lease.activityName) }
    func isRegistered(_ name: String) -> Bool { names.contains(name) }
    func stop(_ names: [String]) { self.names.removeAll { names.contains($0) } }
  }

  @MainActor private enum UITestApp {
    static let pinText = String(repeating: "7", count: 6)
    static func make() -> QuietModel {
      guard let mode = ProcessInfo.processInfo.environment["CALM_UI_FIXTURE"] else { return QuietModel() }
      do {
        let marker = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
          .appendingPathComponent("CalmUITestProcess.json")
        try JSONEncoder().encode(["instance": UUID().uuidString, "mode": mode]).write(to: marker)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
          "ui-" + UUID().uuidString)
        let database = try ControlDatabase(directory: directory)
        let credentials = UITestCredentials()
        let remotes = UITestRemotes()
        let connections = UITestConnections()
        let scheduler = UITestScheduler()
        let pin = PINVerifier(
          store: credentials, clock: { now }, salt: { Data(repeating: 7, count: 32) },
          derive: { text, _, _ in Data(repeating: text == pinText ? 1 : 2, count: 32) })
        let coordinator = PolicyCoordinator(
          database: database, scheduler: scheduler, clock: { now },
          approved: { true }, apply: { _ in })
        if mode == "restricted" || mode == "dual" {
          let policy = Policy(
            allowed: [AppEntry(id: "messages", label: "Messages", token: "synthetic")],
            limits: Policy.quotas.map {
              LimitRule(app: AppEntry(id: $0.key, label: $0.key, token: $0.key), minutes: $0.value)
            })
          try coordinator.install(
            policy, authorization: pin.enroll(pinText, confirmation: pinText, setupComplete: false))
          var record = RemoteRecord()
          record.phoneID = String(repeating: "B", count: 22)
          record.generation = 1
          record.ownerName = "Owner"
          var remote = Remote(
            id: String(repeating: "A", count: 22),
            name: ProcessInfo.processInfo.environment["CALM_UI_REMOTE_NAME"] ?? "Helper",
            secret: Data(repeating: 1, count: 32),
            addedAt: now)
          remote.generation = 1
          record.remotes = [remote]
          remotes.value = record
        }
        if mode == "helper" || mode == "dual" {
          for (index, name) in ["Owner", String(repeating: "W", count: 40)].enumerated() {
            let id = String(repeating: index == 0 ? "C" : "D", count: 22)
            try connections.value.connect(
              ConnectToken(
                phoneID: id, generation: 1, remoteID: id,
                secret: Data(repeating: 5, count: 32), ownerName: name), now: now)
          }
        }
        return QuietModel(
          pin: pin, clock: { now }, databaseFactory: { database },
          coordinatorFactory: { _ in coordinator },
          historyFactory: {
            try ModelContainer(
              for: UnlockInterval.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
          }, repair: {}, validatePolicy: { try $0.validate() }, screenTimeApproval: { true },
          requestScreenTimeAuthorization: {}, remoteStore: remotes, connectionStore: connections)
      } catch { fatalError("Isolated UI fixture failed: \(error)") }
    }
  }
#endif
