import Foundation
import QuietCore
import XCTest

final class DailyHistoryTests: XCTestCase {
  private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
  private func interval(_ start: Date, seconds: Double = 900, early: Double? = nil) -> Lease {
    var lease = Lease(now: start, expiresAt: start + seconds)
    lease.activatedAt = start
    lease.state = .active
    lease.endedAt = early.map { start + $0 }
    lease.relockedAt = start + seconds + 600
    return lease
  }
  func testCrossMidnightCountsOneStartAndSplitsAuthorisedTime() {
    let now = date("2026-10-05T23:00:00Z")
    let grant = interval(date("2026-10-05T21:50:00Z"), seconds: 1800)
    let window = DailyHistoryWindow(leases: [grant], now: now)
    XCTAssertEqual(window.unlocks, 1)
    XCTAssertEqual(window.seconds, 1800)
    XCTAssertEqual(window.days.last?.unlocks, 0)
    XCTAssertEqual(window.days.last?.seconds, 1200)
    XCTAssertEqual(window.days[5].unlocks, 1)
    XCTAssertEqual(window.days[5].seconds, 600)
  }
  func testOverlapDuplicatesEarlyEndActiveAndFailedGrants() {
    let now = date("2026-10-05T18:00:00Z")
    let start = now - 600
    let a = interval(start, seconds: 1800, early: 300)
    let b = interval(start + 200)
    var pending = interval(start)
    pending.state = .pending
    var failed = interval(start)
    failed.state = .failed
    let window = DailyHistoryWindow(leases: [a, a, b, pending, failed], now: now)
    XCTAssertEqual(window.unlocks, 2)
    XCTAssertEqual(window.seconds, 600)
    XCTAssertEqual(window.days.last!.records.count, 2)
    XCTAssertEqual(window.days.dropLast().reduce(0) { $0 + $1.unlocks }, 0)
  }
  func testPagingKeepsExactlyThirtyDaysWithZeroDaysAndNoFutureDays() {
    let now = date("2026-10-05T18:00:00Z")
    let latest = DailyHistoryWindow(leases: [], now: now)
    XCTAssertEqual(latest.days.count, 7)
    XCTAssertFalse(latest.canGoNewer)
    XCTAssertTrue(latest.canGoOlder)
    let pages = stride(from: 0, through: 28, by: 7).map {
      DailyHistoryWindow(leases: [], now: now, offset: $0)
    }
    XCTAssertEqual(pages.flatMap(\.days).count, 30)
    XCTAssertEqual(Set(pages.flatMap(\.days).map(\.id)).count, 30)
    XCTAssertEqual(pages.last!.days.count, 2)
    XCTAssertFalse(pages.last!.canGoOlder)
    XCTAssertTrue(pages.last!.canGoNewer)
    XCTAssertEqual(DailyHistoryWindow(leases: [], now: now, offset: 999).offset, 28)
    XCTAssertEqual(DailyHistoryWindow(leases: [], now: now, offset: -7).offset, 0)
    XCTAssertTrue(pages.flatMap(\.days).allSatisfy { $0.id <= now && $0.seconds == 0 && $0.unlocks == 0 })
  }
  func testOldestClippedIntervalAddsDurationWithoutInventingStart() {
    let now = date("2026-10-05T18:00:00Z")
    let oldest = CivilTime.calendar.date(
      byAdding: .day, value: -29, to: CivilTime.calendar.startOfDay(for: now))!
    let grant = interval(oldest - 600, seconds: 1800)
    let page = DailyHistoryWindow(leases: [grant], now: now, offset: 28)
    XCTAssertEqual(page.unlocks, 0)
    XCTAssertEqual(page.seconds, 1200)
    XCTAssertEqual(page.days.first!.records.count, 1)
  }
  func testDSTAndSubMinuteTotalsUseRecordedSecondsBeforeFormatting() {
    for (start, hours) in [("2026-03-28T23:00:00Z", 23.0), ("2026-10-24T22:00:00Z", 25.0)] {
      let grant = interval(date(start), seconds: hours * 3600)
      let window = DailyHistoryWindow(leases: [grant], now: grant.expiresAt - 1)
      XCTAssertEqual(window.seconds, hours * 3600 - 1)
      XCTAssertEqual(window.days.last!.interval.duration, hours * 3600)
    }
    let now = date("2026-10-05T18:00:00Z")
    let window = DailyHistoryWindow(
      leases: [interval(now - 100, seconds: 40), interval(now - 40, seconds: 40)], now: now)
    XCTAssertEqual(window.seconds, 80)
    XCTAssertEqual(DailyHistoryWindow.duration(window.seconds), "1 min")
    XCTAssertEqual(DailyHistoryWindow.duration(40), "Less than 1 min")
    XCTAssertEqual(DailyHistoryWindow.duration(0), "0 min")
  }
}
