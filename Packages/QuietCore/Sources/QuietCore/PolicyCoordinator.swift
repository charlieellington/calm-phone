import Foundation

public protocol ActivityScheduling {
  func registerDaily(_ policy: Policy) throws
  func registerLease(_ lease: Lease) throws
  func isRegistered(_ name: String) -> Bool
  func stop(_ names: [String])
  var names: [String] { get }
}

public enum GuardianOperation { case lease, policy, replacePIN }

/// Single-use, action-scoped, memory-only capability. Only successful PIN verification creates one.
public final class GuardianAuthorization {
  private let operation: GuardianOperation
  private let expiresAt: Date
  let issuedAt: Date
  private var consumed = false
  private let lock = NSLock()
  init(operation: GuardianOperation, now: Date) {
    self.operation = operation
    issuedAt = now
    expiresAt = now.addingTimeInterval(60)
  }
  public func invalidate() {
    lock.lock()
    consumed = true
    lock.unlock()
  }
  public func isValid(_ operation: GuardianOperation, now: Date) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return !consumed && self.operation == operation && now >= issuedAt && now < expiresAt
  }
  func validateLifetime(now: Date) throws {
    guard now >= issuedAt, now < expiresAt else { throw QuietError.expiredAuthorization }
  }
  public func consume(_ operation: GuardianOperation, now: Date) throws {
    lock.lock()
    defer { lock.unlock() }
    guard !consumed, self.operation == operation, now >= issuedAt, now < expiresAt else {
      throw QuietError.expiredAuthorization
    }
    consumed = true
  }
}

public final class PolicyCoordinator {
  private let database: ControlDatabase
  private let scheduler: ActivityScheduling
  private let clock: () -> Date
  private let localCalendar: () -> Calendar
  private let uptime: () -> TimeInterval
  private let approved: () -> Bool?
  private let recoverablePendingPolicy: (Policy) -> Bool
  private let apply: (ShieldProjection) throws -> Void
  private let notify: () -> Void
  public init(
    database: ControlDatabase, scheduler: ActivityScheduling, clock: @escaping () -> Date,
    approved: @escaping () -> Bool?, apply: @escaping (ShieldProjection) throws -> Void,
    notify: @escaping () -> Void = {},
    localCalendar: @escaping () -> Calendar = { .current },
    uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    recoverablePendingPolicy: @escaping (Policy) -> Bool = { _ in false }
  ) {
    self.database = database
    self.scheduler = scheduler
    self.clock = clock
    self.approved = approved
    self.localCalendar = localCalendar
    self.uptime = uptime
    self.recoverablePendingPolicy = recoverablePendingPolicy
    self.apply = apply
    self.notify = notify
  }
  private func project(_ state: ControlState) throws {
    let now = clock()
    // First-run introduction does not assert protection before selections and consent.
    if state.setupComplete || state.pendingPolicy != nil || state.needsReselection {
      try apply(state.projection(now: now))
    }
    try database.writeSnapshot(WidgetSnapshot(state: state, now: now))
    notify()
  }
  public func reconcile() throws {
    let now = clock()
    let authorization = approved()
    try database.update(
      { state in
        state.reconcile(now: now, approved: authorization)
        if let lease = state.openLease, lease.state == .pending {
          end(&state, id: lease.id, now: now)
        }
        if let policy = state.policy, !scheduler.isRegistered(policy.dailyName) {
          state.dailyRegistered = false
          state.monitorFailed = true
        }
        if let lease = state.openLease, lease.state == .active, !scheduler.isRegistered(lease.activityName) {
          end(&state, id: lease.id, now: now)
          state.monitorFailed = true
        }
        // Once an ended/failed grant is closed and the permanent monitor is present,
        // successful projection below confirms the normal restriction policy again.
        if state.openLease == nil, state.setupComplete, !state.needsReselection,
          state.pendingPolicy == nil, state.dailyRegistered, authorization == true,
          let policy = state.policy, scheduler.isRegistered(policy.dailyName)
        {
          state.monitorFailed = false
        }
      }, project: project)
    let state = try database.load()
    if state.setupComplete, !state.needsReselection, authorization == true, state.pendingPolicy == nil,
      !state.dailyRegistered, let policy = state.policy
    {
      do {
        try scheduler.registerDaily(policy)
        try database.update(
          { state in
            guard state.policy?.generation == policy.generation, state.pendingPolicy == nil else { return }
            state.dailyRegistered = true
            state.monitorFailed = false
            state.reconcile(now: clock(), approved: approved())
          }, project: project)
      } catch { throw QuietError.unavailable }
    }
    // Crash-left pending changes never authorize opening. Clean their unused registrations.
    let fresh = try database.load()
    let retained = Set([fresh.policy?.dailyName, fresh.openLease?.activityName].compactMap { $0 })
    scheduler.stop(scheduler.names.filter { $0.hasPrefix("quiet.") && !retained.contains($0) })
  }
  public func prepareEnrollment(_ policy: Policy) throws {
    try policy.validate()
    let failure = try database.update(
      { state -> QuietError? in
        guard !state.setupComplete, state.policy == nil, state.leases.isEmpty,
          !state.needsReselection || state.pendingPolicy != nil
        else { throw QuietError.repairRequired }
        state.reconcile(now: clock(), approved: approved())
        guard approved() == true, state.authorizationApproved else { return .unavailable }
        guard !state.requiresFreshSelection(for: policy) else { return .reselectionRequired }
        // Commit intent before creating the private credential; either side of that write can resume.
        state.pendingPolicy = policy
        state.pendingExhausted = []
        return nil
      }, project: project)
    if let failure { throw failure }
  }
  private func canRecover(_ policy: Policy, in state: ControlState) -> Bool {
    // Bounded repair of one diagnosed initial enrollment, never a general token-revival path.
    approved() == true && state.authorizationApproved && recoverablePendingPolicy(policy)
      && !state.setupComplete && state.policy == nil && state.pendingPolicy == policy
      && state.leases.isEmpty && state.repairedPendingGeneration == nil
      && state.invalidatedSelectionTokens == policy.tokens
  }
  public func canRecoverPendingEnrollment(_ policy: Policy) throws -> Bool {
    canRecover(policy, in: try database.load())
  }
  public func install(_ policy: Policy, authorization: GuardianAuthorization) throws {
    try policy.validate()
    try authorization.consume(.policy, now: clock())
    let prepared = try database.update(
      { state -> (failure: QuietError?, old: String?) in
        // Replacing a crash-left pending revision is allowed only with a fresh PIN.
        state.reconcile(now: clock(), approved: approved())
        guard approved() == true, state.authorizationApproved else { return (.unavailable, nil) }
        if state.requiresFreshSelection(for: policy) {
          guard canRecover(policy, in: state) else { return (.reselectionRequired, nil) }
          state.invalidatedSelectionTokens = []
          state.needsReselection = false
          state.repairedPendingGeneration = policy.generation
        }
        guard
          state.setupComplete
            || (state.policy == nil && state.leases.isEmpty
              && (!state.needsReselection || state.pendingPolicy != nil))
        else { throw QuietError.repairRequired }
        let pendingExhausted =
          state.pendingPolicy?.generation == policy.generation ? state.pendingExhausted : []
        state.pendingPolicy = policy
        state.pendingExhausted = pendingExhausted.union(carriedExhaustion(from: state, to: policy))
        state.reconcile(now: clock(), approved: state.authorizationApproved)
        return (nil, state.policy?.dailyName)
      }, project: project)
    if let failure = prepared.failure { throw failure }
    do { try scheduler.registerDaily(policy) } catch {
      try database.update(
        { state in
          if state.pendingPolicy?.generation == policy.generation {
            if state.setupComplete {
              state.pendingPolicy = nil
              state.pendingExhausted = []
            }
            state.monitorFailed = true
          }
        }, project: project)
      throw QuietError.unavailable
    }
    let promoted = try database.update(
      { state -> Bool in
        state.reconcile(now: clock(), approved: approved())
        guard approved() == true, state.pendingPolicy?.generation == policy.generation,
          state.authorizationApproved,
          !state.requiresFreshSelection(for: policy),
          scheduler.isRegistered(policy.dailyName)
        else { return false }
        // Old-generation thresholds may arrive during registration; merge before replacing it.
        let exhausted = state.pendingExhausted.union(carriedExhaustion(from: state, to: policy))
        state.policy = policy
        state.pendingPolicy = nil
        state.setupComplete = true
        state.needsReselection = false
        state.dailyRegistered = true
        state.monitorFailed = false
        state.exhaustedDay = CivilTime.day(clock())
        state.exhausted = exhausted
        state.pendingExhausted = []
        state.reconcile(now: clock(), approved: state.authorizationApproved)
        return true
      }, project: project)
    guard promoted else { throw QuietError.unavailable }
    if let old = prepared.old, old != policy.dailyName { scheduler.stop([old]) }
  }
  private func carriedExhaustion(from state: ControlState, to policy: Policy) -> Set<UUID> {
    guard state.exhaustedDay == CivilTime.day(clock()), let old = state.policy else { return [] }
    return Set(
      policy.limits.filter { rule in
        old.limits.contains {
          state.exhausted.contains($0.id) && $0.app.token == rule.app.token && rule.minutes <= $0.minutes
        }
      }.map(\.id))
    // A higher quota or different token has no exhaustion proof; includesPastActivity supplies it.
  }
  public func grant(_ choice: LeaseChoice, authorization: GuardianAuthorization) throws {
    let draft = try GrantDraft.prepare(choice, now: clock(), calendar: localCalendar(), uptime: uptime())
    try grant(draft, authorization: authorization)
  }
  public func grant(_ draft: GrantDraft, authorization: GuardianAuthorization) throws {
    let now = clock()
    try authorization.consume(.lease, now: now)
    guard draft.observedAt >= authorization.issuedAt else { throw QuietError.expiredAuthorization }
    try draft.validate(now: now, calendar: localCalendar(), uptime: uptime())
    let lease = Lease(now: draft.requestedAt, expiresAt: draft.expiresAt)
    try database.update(
      { state in
        state.reconcile(now: now, approved: approved())
        guard approved() == true, state.setupComplete, state.authorizationApproved, !state.needsReselection,
          state.dailyRegistered, state.pendingPolicy == nil, state.openLease == nil,
          let policy = state.policy, scheduler.isRegistered(policy.dailyName)
        else { throw QuietError.unavailable }
        state.leases.append(lease)
      }, project: project)
    do { try scheduler.registerLease(lease) } catch {
      try database.update(
        { state in
          if let i = state.leases.firstIndex(where: { $0.id == lease.id && $0.state == .pending }) {
            state.leases[i].state = .failed
            state.monitorFailed = true
          }
        }, project: project)
      throw QuietError.unavailable
    }
    do {
      try authorization.validateLifetime(now: clock())
      try draft.validate(now: clock(), calendar: localCalendar(), uptime: uptime())
    } catch {
      scheduler.stop([lease.activityName])
      try database.update(
        { state in
          if let i = state.leases.firstIndex(where: { $0.id == lease.id && $0.state == .pending }) {
            state.leases[i].state = .failed
          }
        }, project: project)
      throw error
    }
    try database.update(
      { state in
        state.reconcile(now: clock(), approved: approved())
        guard let i = state.leases.firstIndex(where: { $0.id == lease.id }),
          approved() == true, state.leases[i].state == .pending, state.authorizationApproved,
          !state.needsReselection,
          state.pendingPolicy == nil, state.dailyRegistered, clock() < lease.expiresAt,
          scheduler.isRegistered(lease.activityName)
        else { throw QuietError.unavailable }
        try authorization.validateLifetime(now: clock())
        try draft.validate(now: clock(), calendar: localCalendar(), uptime: uptime())
        state.leases[i].state = .active
        state.leases[i].activatedAt = clock()
        state.monitorFailed = false
      }, project: project)
  }
  private func end(_ state: inout ControlState, id: UUID, now: Date) {
    guard
      let i = state.leases.firstIndex(where: { $0.id == id && ($0.state == .pending || $0.state == .active) })
    else { return }
    state.leases[i].state = .ended
    if let start = state.leases[i].activatedAt {
      state.leases[i].endedAt = max(start, min(now, state.leases[i].expiresAt))
    }
    state.leases[i].relockedAt = now
  }
  public func lockNow() throws {
    let name = try database.update(
      { state -> String? in
        let lease = state.openLease
        if let lease { end(&state, id: lease.id, now: clock()) }
        state.reconcile(now: clock(), approved: state.authorizationApproved)
        return lease?.activityName
      }, project: project)
    if let name { scheduler.stop([name]) }
  }
  public func callback(activity: String, event: String? = nil, didEnd: Bool = false) throws {
    try database.update(
      { state in
        let now = clock()
        if activity.hasPrefix("quiet."), !state.setupComplete, state.pendingPolicy == nil {
          state.needsReselection = true
          state.monitorFailed = true
        }
        state.reconcile(now: now, approved: approved())
        if let policy = state.policy, activity == policy.dailyName,
          let event, event.hasPrefix("quiet.limit."),
          let id = UUID(uuidString: String(event.dropFirst("quiet.limit.".count))),
          policy.limits.contains(where: { $0.id == id })
        {
          state.exhausted.insert(id)
        }
        if let policy = state.pendingPolicy, activity == policy.dailyName,
          let event, event.hasPrefix("quiet.limit."),
          let id = UUID(uuidString: String(event.dropFirst("quiet.limit.".count))),
          policy.limits.contains(where: { $0.id == id })
        {
          state.pendingExhausted.insert(id)
        }
        // A start callback cannot activate pending state. Stale end callbacks cannot end a successor.
        if didEnd, let lease = state.openLease, activity == lease.activityName {
          end(&state, id: lease.id, now: now)
        }
      },
      project: { state in
        if activity.hasPrefix("quiet."), !state.setupComplete, state.pendingPolicy == nil {
          // A registered callback is prior-installation evidence even if the whole directory was lost.
          try self.project(state)
          throw QuietError.repairRequired
        }
        try self.project(state)
      })
  }
}
