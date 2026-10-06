import Foundation

public enum QuietError: Error, LocalizedError {
  case invalidPolicy, repairRequired, unavailable, busy, invalidDuration, wrongPIN, lockedOut,
    expiredAuthorization, reselectionRequired, staleDraft
  public var errorDescription: String? {
    switch self {
    case .invalidPolicy:
      return "Choose distinct applications only, with at most 50 Allow and Limit selections in total."
    case .repairRequired: return "Your saved setup could not be read. Try again."
    case .unavailable: return "The required service is unavailable. Access was not granted."
    case .busy: return "Protection is busy. Try again in a moment."
    case .invalidDuration: return "Midnight is less than 15 minutes away."
    case .wrongPIN: return "Incorrect PIN. Try again."
    case .lockedOut: return "Too many attempts. Try again when the lockout ends."
    case .expiredAuthorization: return "Pass the phone to the PIN holder and enter their PIN again."
    case .staleDraft: return "The time changed or this confirmation expired. Enter the PIN again."
    case .reselectionRequired:
      return "Screen Time access changed. Ask the PIN holder to select the applications again."
    }
  }
}

public struct AppEntry: Codable, Equatable, Identifiable {
  public var id: String
  public var label: String
  public var token: String
  public init(id: String, label: String, token: String) {
    self.id = id
    self.label = label
    self.token = token
  }
}

public struct LimitRule: Codable, Equatable, Identifiable {
  public var id: UUID
  public var app: AppEntry
  public var minutes: Int
  public init(id: UUID = UUID(), app: AppEntry, minutes: Int) {
    self.id = id
    self.app = app
    self.minutes = minutes
  }
}

public struct Policy: Codable, Equatable {
  public var generation: UUID
  public var allowed: [AppEntry]
  public var limits: [LimitRule]
  public static let quotas = [
    "photos": 10, "apple-maps": 10, "google-maps": 10,
    "weather": 10, "files": 10, "claude": 30,
  ]
  public init(generation: UUID = UUID(), allowed: [AppEntry], limits: [LimitRule]) {
    self.generation = generation
    self.allowed = allowed
    self.limits = limits
  }
  public func validate() throws {
    let apps = allowed + limits.map(\.app)
    guard limits.count == 6, Set(limits.map { $0.app.id }) == Set(Self.quotas.keys),
      limits.allSatisfy({ (1...1440).contains($0.minutes) }),
      Set(limits.map(\.id)).count == limits.count,
      Set(apps.map(\.token)).count == apps.count, apps.count <= 50,
      Set(apps.map(\.id)).count == apps.count,
      apps.allSatisfy({ !$0.token.isEmpty && !$0.label.isEmpty && !$0.id.isEmpty })
    else { throw QuietError.invalidPolicy }
  }
  public var dailyName: String { "quiet.daily.\(generation.uuidString)" }
  public var tokens: Set<String> { Set(allowed.map(\.token) + limits.map { $0.app.token }) }
}

public enum LeaseChoice: String, CaseIterable { case quarterHour, hour, midnight }
public enum LeaseState: String, Codable { case pending, active, ended, failed }
public struct Lease: Codable, Equatable, Identifiable {
  public var id = UUID()
  public var state: LeaseState = .pending
  public var requestedAt: Date
  public var expiresAt: Date
  public var activatedAt: Date?
  public var endedAt: Date?
  public var relockedAt: Date?
  public var activityName: String { "quiet.lease.\(id.uuidString)" }
  public func isActive(at now: Date) -> Bool {
    state == .active && activatedAt != nil && now >= activatedAt! && now < expiresAt
  }
  public init(now: Date, expiresAt: Date) {
    requestedAt = now
    self.expiresAt = expiresAt
  }
}

public enum CivilTime {
  public static var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Brussels")!
    return calendar
  }
  public static func day(_ now: Date) -> String {
    let c = calendar.dateComponents([.year, .month, .day], from: now)
    return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
  }
  public static func expiry(_ choice: LeaseChoice, now: Date) throws -> Date {
    try GrantDraft.prepare(choice, now: now).expiresAt
  }

  public static func seconds(_ leases: [Lease], day: DateInterval, now: Date) -> Double {
    let pieces = leases.compactMap { lease -> DateInterval? in
      guard let activation = lease.activatedAt else { return nil }
      let start = max(activation, day.start)
      let end = min(lease.endedAt ?? lease.expiresAt, lease.expiresAt, day.end, now)
      return end > start ? DateInterval(start: start, end: end) : nil
    }.sorted { $0.start < $1.start }
    var total = 0.0
    var current: DateInterval?
    for piece in pieces {
      if let old = current {
        if piece.start <= old.end {
          current = DateInterval(start: old.start, end: max(old.end, piece.end))
        } else {
          total += old.duration
          current = piece
        }
      } else {
        current = piece
      }
    }
    return total + (current?.duration ?? 0)
  }
}

public struct ControlState: Codable, Equatable {
  public var setupComplete = false
  public var policy: Policy?
  public var pendingPolicy: Policy?
  public var pendingExhausted: Set<UUID> = []
  public var dailyRegistered = false
  public var needsReselection = false
  // Optional so existing v1 journals remain readable. Voided tokens never become reusable.
  public var invalidatedSelectionTokens: Set<String>?
  public var authorizationApproved = false
  public var repairedPendingGeneration: UUID?
  public var exhaustedDay = ""
  public var exhausted: Set<UUID> = []
  public var leases: [Lease] = []
  public var lastReconciledAt: Date?
  public var monitorFailed = false
  public var revision = 0
  public init() {}
  public var openLease: Lease? { leases.last { $0.state == .pending || $0.state == .active } }
  public func requiresFreshSelection(for policy: Policy) -> Bool {
    !policy.tokens.isDisjoint(with: invalidatedSelectionTokens ?? [])
  }
  public mutating func reconcile(now: Date, approved: Bool?) {
    // A new process has no authorization observation yet. Preserve confirmed facts and timers.
    if let approved,
      (setupComplete || pendingPolicy != nil)
        && (!approved || !authorizationApproved || (needsReselection && invalidatedSelectionTokens == nil))
    {
      needsReselection = true
      invalidatedSelectionTokens = (invalidatedSelectionTokens ?? [])
        .union(policy?.tokens ?? []).union(pendingPolicy?.tokens ?? [])
    }
    if let approved { authorizationApproved = approved }
    if exhaustedDay != CivilTime.day(now) {
      exhaustedDay = CivilTime.day(now)
      exhausted = []
      pendingExhausted = []
    }
    for i in leases.indices where leases[i].state == .active || leases[i].state == .pending {
      if now >= leases[i].expiresAt || !authorizationApproved || needsReselection || pendingPolicy != nil {
        leases[i].state = .ended
        if let start = leases[i].activatedAt { leases[i].endedAt = max(start, min(now, leases[i].expiresAt)) }
        leases[i].relockedAt = now
      }
    }
    // Control facts outlive projection imports; keep a little over the 30-day display window.
    let cutoff = CivilTime.calendar.date(byAdding: .day, value: -32, to: now)!
    leases.removeAll { $0.expiresAt < cutoff && $0.state != .active && $0.state != .pending }
    lastReconciledAt = now
  }
  public func projection(now: Date) throws -> ShieldProjection {
    guard let policy else { return ShieldProjection(exceptions: [], isOpen: false) }
    try policy.validate()
    guard setupComplete, !needsReselection, dailyRegistered, pendingPolicy == nil else {
      return ShieldProjection(exceptions: [], isOpen: false)
    }
    let remaining = policy.limits.filter { exhaustedDay != CivilTime.day(now) || !exhausted.contains($0.id) }
    return ShieldProjection(
      exceptions: Set(policy.allowed.map(\.token) + remaining.map { $0.app.token }),
      isOpen: authorizationApproved && openLease?.isActive(at: now) == true)
  }
}

public struct ShieldProjection: Equatable {
  public let exceptions: Set<String>
  public let isOpen: Bool
  public init(exceptions: Set<String>, isOpen: Bool) {
    self.exceptions = exceptions
    self.isOpen = isOpen
  }
}

public struct WidgetSnapshot: Codable {
  public var generatedAt: Date
  public var protectionReady: Bool
  public var leaseStart: Date?
  public var leaseEnd: Date?
  public var allowances: [String: Int]
  public var spent: Set<String>
  public init(state: ControlState, now: Date) {
    generatedAt = now
    protectionReady =
      state.setupComplete && state.authorizationApproved && !state.needsReselection
      && state.dailyRegistered && state.pendingPolicy == nil && !state.monitorFailed
    let lease = state.openLease.flatMap { $0.isActive(at: now) ? $0 : nil }
    leaseStart = lease?.activatedAt
    leaseEnd = lease?.expiresAt
    allowances = Dictionary(
      uniqueKeysWithValues: (state.policy?.limits ?? []).map { ($0.app.id, $0.minutes) })
    spent = Set(
      (state.policy?.limits ?? []).filter {
        state.exhaustedDay == CivilTime.day(now) && state.exhausted.contains($0.id)
      }.map { $0.app.id })
  }
}
