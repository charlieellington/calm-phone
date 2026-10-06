import Foundation

public enum ColourReason: String, Codable, Equatable {
  case daytime, appAccess, colourOnly, night
}

/// Display policy only. This type never changes app access, quotas or history.
public struct ColourDecision: Codable, Equatable {
  public let filtersOn: Bool
  public let reason: ColourReason
  public let nextEvaluation: Date
  public let colourOnlyEnd: Date?

  public static func evaluate(
    control: ControlState, colour: ColourState, now: Date,
    calendar: Calendar = .autoupdatingCurrent
  ) throws -> Self {
    let healthy =
      control.setupComplete && control.authorizationApproved && !control.needsReselection
      && control.pendingPolicy == nil && control.dailyRegistered && !control.monitorFailed
    let end = healthy ? control.openLease.flatMap { $0.isActive(at: now) ? $0.expiresAt : nil } : nil
    return try evaluate(now: now, calendar: calendar, appAccessEnd: end, colourOnly: colour.interval)
  }

  public static func evaluate(
    now: Date, calendar: Calendar = .autoupdatingCurrent,
    appAccessEnd: Date? = nil, colourOnly: ColourInterval? = nil
  ) throws -> Self {
    guard let day = calendar.dateInterval(of: .day, for: now),
      let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day.start),
      let evening = calendar.date(bySettingHour: 19, minute: 0, second: 0, of: day.start),
      let nextMorning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day.end)
    else { throw QuietError.unavailable }
    let daytime = now >= morning && now < evening
    let access = appAccessEnd.flatMap { $0 > now ? $0 : nil }
    let colourEnd = colourOnly.flatMap { $0.isActive(at: now) ? $0.expiresAt : nil }
    let reason: ColourReason =
      access != nil ? .appAccess : colourEnd != nil ? .colourOnly : daytime ? .daytime : .night
    let boundary = now < morning ? morning : now < evening ? evening : nextMorning
    let evaluations = [boundary, access, colourEnd].compactMap { $0 }.filter { $0 > now }
    return Self(
      filtersOn: reason == .night, reason: reason, nextEvaluation: evaluations.min() ?? boundary,
      colourOnlyEnd: colourEnd)
  }
}

public struct ColourInterval: Codable, Equatable {
  public let id: UUID
  public let startedAt: Date
  public let expiresAt: Date
  public init(now: Date) {
    id = UUID()
    startedAt = now
    expiresAt = now.addingTimeInterval(900)
  }
  public func isActive(at now: Date) -> Bool { now >= startedAt && now < expiresAt }
}

public struct ColourApplication: Codable, Equatable {
  public let checkedAt: Date
  public let filtersOn: Bool
  public let matched: Bool
  public init(checkedAt: Date, filtersOn: Bool, matched: Bool) {
    self.checkedAt = checkedAt
    self.filtersOn = filtersOn
    self.matched = matched
  }
}

public struct ColourState: Codable, Equatable {
  public var version = 1
  public var revision = 0
  public var interval: ColourInterval?
  public var lastApplication: ColourApplication?
  public init() {}
}
