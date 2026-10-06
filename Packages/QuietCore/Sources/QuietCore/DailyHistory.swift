import Foundation

public struct HistoryDay: Identifiable {
  public var id: Date { interval.start }
  public let interval: DateInterval
  public let unlocks: Int
  public let seconds: Double
  public let records: [Lease]
}

public struct DailyHistoryWindow {
  public let offset: Int
  public let days: [HistoryDay]
  public var canGoOlder: Bool { offset < 28 }
  public var canGoNewer: Bool { offset > 0 }
  public var unlocks: Int { days.reduce(0) { $0 + $1.unlocks } }
  public var seconds: Double { days.reduce(0) { $0 + $1.seconds } }
  public init(leases: [Lease], now: Date, offset: Int = 0) {
    self.offset = min(28, max(0, offset / 7 * 7))
    let today = CivilTime.calendar.startOfDay(for: now)
    var unique: [UUID: Lease] = [:]
    for lease in leases where lease.activatedAt != nil && (lease.state == .active || lease.state == .ended) {
      unique[lease.id] = lease
    }
    let records = Array(unique.values)
    days = (self.offset..<min(30, self.offset + 7)).reversed().map { dayOffset in
      let date = CivilTime.calendar.date(byAdding: .day, value: -dayOffset, to: today)!
      let interval = CivilTime.calendar.dateInterval(of: .day, for: date)!
      let starts = records.filter {
        let start = $0.activatedAt!
        return start >= interval.start && start < interval.end && start <= now
      }
      let intersecting = records.filter {
        min($0.endedAt ?? $0.expiresAt, $0.expiresAt, interval.end, now)
          > max($0.activatedAt!, interval.start)
          || ($0.activatedAt == now && now >= interval.start && now < interval.end)
      }.sorted { $0.activatedAt! < $1.activatedAt! }
      return HistoryDay(
        interval: interval, unlocks: starts.count,
        seconds: CivilTime.seconds(records, day: interval, now: now), records: intersecting)
    }
  }
  public static func duration(_ seconds: Double) -> String {
    guard seconds > 0 else { return "0 min" }
    guard seconds >= 60 else { return "Less than 1 min" }
    let minutes = Int(seconds / 60)
    return minutes < 60
      ? "\(minutes) min" : "\(minutes / 60) h" + (minutes % 60 > 0 ? " \(minutes % 60) min" : "")
  }
}
