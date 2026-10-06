import CryptoKit
import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings
import QuietCore
import WidgetKit

enum TokenCodec {
  static func encode(_ token: ApplicationToken) throws -> String {
    try JSONEncoder().encode(token).base64EncodedString()
  }
  static func decode(_ value: String) throws -> ApplicationToken {
    guard let data = Data(base64Encoded: value) else { throw QuietError.repairRequired }
    return try JSONDecoder().decode(ApplicationToken.self, from: data)
  }
  static func validate(_ policy: Policy) throws {
    try policy.validate()
    let apps = policy.allowed + policy.limits.map(\.app)
    let tokens = try apps.map { try decode($0.token) }
    guard Set(tokens).count == tokens.count else { throw QuietError.invalidPolicy }
  }
}

final class AppleScheduler: ActivityScheduling {
  private let center = DeviceActivityCenter()
  var names: [String] { center.activities.map(\.rawValue) }
  func isRegistered(_ name: String) -> Bool { center.activities.contains(DeviceActivityName(name)) }
  func registerDaily(_ policy: Policy) throws {
    try TokenCodec.validate(policy)
    var start = DateComponents(hour: 0, minute: 0, second: 0)
    var end = DateComponents(hour: 23, minute: 59, second: 59)
    start.calendar = CivilTime.calendar
    start.timeZone = CivilTime.calendar.timeZone
    end.calendar = CivilTime.calendar
    end.timeZone = CivilTime.calendar.timeZone
    let events = try Dictionary(
      uniqueKeysWithValues: policy.limits.map { rule in
        (
          DeviceActivityEvent.Name("quiet.limit.\(rule.id.uuidString)"),
          DeviceActivityEvent(
            applications: [try TokenCodec.decode(rule.app.token)],
            threshold: DateComponents(minute: rule.minutes), includesPastActivity: true)
        )
      })
    try center.startMonitoring(
      DeviceActivityName(policy.dailyName),
      during: DeviceActivitySchedule(intervalStart: start, intervalEnd: end, repeats: true), events: events)
  }
  static func leaseSchedule(_ lease: Lease) throws -> DeviceActivitySchedule {
    guard lease.expiresAt.timeIntervalSince(lease.requestedAt) >= 900 else {
      throw QuietError.invalidDuration
    }
    // Absolute UTC components avoid ambiguous repeated Brussels wall times at autumn DST.
    // Daily allowances and history continue to use CivilTime.calendar unchanged.
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let components: Set<Calendar.Component> = [.era, .year, .month, .day, .hour, .minute, .second]
    var start = calendar.dateComponents(components, from: lease.requestedAt)
    var end = calendar.dateComponents(components, from: lease.expiresAt)
    start.calendar = calendar
    start.timeZone = calendar.timeZone
    end.calendar = calendar
    end.timeZone = calendar.timeZone
    return DeviceActivitySchedule(intervalStart: start, intervalEnd: end, repeats: false)
  }
  func registerLease(_ lease: Lease) throws {
    try center.startMonitoring(DeviceActivityName(lease.activityName), during: Self.leaseSchedule(lease))
  }
  func stop(_ names: [String]) {
    if !names.isEmpty { center.stopMonitoring(names.map { DeviceActivityName($0) }) }
  }
}

enum ApplePolicy {
  private static var observedApproval = false
  static var authorizationApproval: Bool? {
    // Apple requires this property on the main queue. Extension callbacks may arrive elsewhere.
    if Thread.isMainThread { return readAuthorizationApproval() }
    return DispatchQueue.main.sync { readAuthorizationApproval() }
  }
  private static func readAuthorizationApproval() -> Bool? {
    switch AuthorizationCenter.shared.authorizationStatus {
    case .approved:
      observedApproval = true
      return true
    case .denied: return false
    case .notDetermined: return observedApproval ? false : nil
    @unknown default: return false
    }
  }
  static var approved: Bool { authorizationApproval == true }
  static func matchesDiagnosedEnrollment(_ policy: Policy) -> Bool {
    let digest = SHA256.hash(data: Data(policy.generation.uuidString.utf8))
      .map { String(format: "%02x", $0) }.joined()
    return digest == "47ff819cf7e12b5dafa27072e0729a08fba12f5035d1a3dfac09c617de614ec1"
  }
  static func closeForRepair() {
    // A corrupt store during open access cannot leave an unbounded relaxation behind.
    // No tokens are guessed or discarded from the authoritative database.
    try? apply(ShieldProjection(exceptions: [], isOpen: false))
    WidgetCenter.shared.reloadAllTimelines()
  }
  static func coordinator(database: ControlDatabase) -> PolicyCoordinator {
    PolicyCoordinator(
      database: database, scheduler: AppleScheduler(), clock: Date.init,
      approved: { authorizationApproval }, apply: apply,
      notify: { WidgetCenter.shared.reloadAllTimelines() },
      recoverablePendingPolicy: matchesDiagnosedEnrollment)
  }
  static func handleCallback(
    activity: String, event: String? = nil, didEnd: Bool = false,
    databaseFactory: () throws -> ControlDatabase = SharedContainer.database,
    coordinatorFactory: (ControlDatabase) -> PolicyCoordinator = coordinator,
    repair: () -> Void = closeForRepair
  ) throws {
    do {
      let database = try databaseFactory()
      try coordinatorFactory(database).callback(activity: activity, event: event, didEnd: didEnd)
    } catch {
      repair()
      throw error
    }
  }
  /// This is the only ManagedSettings writer. Opening requires a durable, monitored lease.
  private static func apply(_ projection: ShieldProjection) throws {
    let tokens = try Set(projection.exceptions.map(TokenCodec.decode))
    guard tokens.count <= 50 else { throw QuietError.invalidPolicy }
    let shields = ManagedSettingsStore(named: .init("quiet.shields"))
    let integrity = ManagedSettingsStore(named: .init("quiet.integrity"))
    integrity.application.denyAppRemoval = true
    integrity.application.denyAppInstallation = true
    if projection.isOpen {
      shields.shield.applicationCategories = nil
      shields.shield.applications = nil
    } else {
      shields.shield.applicationCategories = .all(except: tokens)
      shields.shield.applications = nil
    }
  }
}
