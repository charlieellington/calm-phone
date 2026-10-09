import Foundation

/// Memory-only confirmation. Whole-second endpoints match DeviceActivity's schedule components.
public struct GrantDraft: Equatable {
  public let choice: LeaseChoice
  public let requestedAt: Date
  public let expiresAt: Date
  let observedAt: Date
  private let uptime: TimeInterval
  private let calendar: Calendar

  public static func prepare(
    _ choice: LeaseChoice, now: Date, calendar: Calendar = .current,
    uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) throws -> GrantDraft {
    let start = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
    let end: Date
    switch choice {
    case .quarterHour: end = start.addingTimeInterval(900)
    case .hour: end = start.addingTimeInterval(3600)
    case .midnight:
      guard let boundary = calendar.dateInterval(of: .day, for: now)?.end,
        boundary.timeIntervalSince(now) >= 900
      else { throw QuietError.invalidDuration }
      end = boundary
    }
    return GrantDraft(
      choice: choice, requestedAt: start, expiresAt: end, observedAt: now,
      uptime: uptime, calendar: calendar)
  }

  func validate(now: Date, calendar: Calendar, uptime: TimeInterval) throws {
    let elapsed = now.timeIntervalSince(observedAt)
    guard elapsed >= 0, elapsed < 60,
      abs(elapsed - (uptime - self.uptime)) < 2,
      self.calendar.identifier == calendar.identifier,
      self.calendar.timeZone == calendar.timeZone,
      try Self.prepare(choice, now: observedAt, calendar: self.calendar, uptime: self.uptime).expiresAt
        == expiresAt
    else { throw QuietError.staleDraft }
    if choice == .midnight {
      guard calendar.dateInterval(of: .day, for: now)?.end == expiresAt,
        expiresAt.timeIntervalSince(now) >= 900
      else { throw QuietError.invalidDuration }
    }
  }
}
