import Foundation
import XCTest

@testable import QuietCore

final class ColourTests: XCTestCase {
  private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
  private func calendar(_ zone: String = "Europe/Brussels") -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
  }
  func testExactLocalDaytimeBoundaries() throws {
    for (instant, on) in [
      ("2026-10-05T06:59:59Z", true), ("2026-10-05T07:00:00Z", false),
      ("2026-10-05T16:59:59Z", false), ("2026-10-05T17:00:00Z", true),
    ] {
      XCTAssertEqual(try ColourDecision.evaluate(now: date(instant), calendar: calendar()).filtersOn, on)
    }
  }
  func testLocalTravelScheduleDoesNotUseBrusselsAllowanceClock() throws {
    let now = date("2026-10-05T17:30:00Z")
    XCTAssertTrue(try ColourDecision.evaluate(now: now, calendar: calendar()).filtersOn)
    XCTAssertFalse(try ColourDecision.evaluate(now: now, calendar: calendar("America/New_York")).filtersOn)
    XCTAssertEqual(CivilTime.day(now), "2026-10-05")
  }
  func testDSTNextMorningIsLocalCalendarBoundary() throws {
    for instant in ["2026-03-28T20:00:00Z", "2026-10-24T20:00:00Z"] {
      let c = calendar()
      let result = try ColourDecision.evaluate(now: date(instant), calendar: c)
      XCTAssertTrue(result.filtersOn)
      XCTAssertEqual(c.component(.hour, from: result.nextEvaluation), 9)
      XCTAssertEqual(
        c.component(.day, from: result.nextEvaluation), c.component(.day, from: date(instant)) + 1)
    }
  }
  func testAppAccessCrossesEveningAndExpiryReevaluatesSchedule() throws {
    let end = date("2026-10-05T17:20:00Z")
    let before = try ColourDecision.evaluate(
      now: date("2026-10-05T17:00:00Z"), calendar: calendar(), appAccessEnd: end)
    XCTAssertFalse(before.filtersOn)
    XCTAssertEqual(before.reason, .appAccess)
    XCTAssertEqual(before.nextEvaluation, end)
    XCTAssertTrue(try ColourDecision.evaluate(now: end, calendar: calendar(), appAccessEnd: end).filtersOn)
    XCTAssertFalse(
      try ColourDecision.evaluate(
        now: date("2026-10-05T08:00:00Z"), calendar: calendar(), appAccessEnd: date("2026-10-05T07:59:59Z")
      ).filtersOn)
  }
  func testLockAndReturnScheduleKeepOtherColourReason() throws {
    let now = date("2026-10-05T18:00:00Z")
    let interval = ColourInterval(now: now)
    let afterLock = try ColourDecision.evaluate(now: now, calendar: calendar(), colourOnly: interval)
    XCTAssertEqual(afterLock.reason, .colourOnly)
    XCTAssertFalse(afterLock.filtersOn)
    let afterReturn = try ColourDecision.evaluate(
      now: now, calendar: calendar(), appAccessEnd: now.addingTimeInterval(3600))
    XCTAssertEqual(afterReturn.reason, .appAccess)
    XCTAssertFalse(afterReturn.filtersOn)
    XCTAssertTrue(
      try ColourDecision.evaluate(now: interval.expiresAt, calendar: calendar(), colourOnly: interval)
        .filtersOn)
  }
  func testPendingFailedExpiredAndUnhealthyAppGrantsNeverCountAsColourOverrides() throws {
    let now = date("2026-10-05T18:00:00Z")
    var control = ControlState()
    control.setupComplete = true
    control.authorizationApproved = true
    control.dailyRegistered = true
    var lease = Lease(now: now, expiresAt: now.addingTimeInterval(900))
    lease.activatedAt = now
    for state in [LeaseState.pending, .failed, .ended] {
      lease.state = state
      control.leases = [lease]
      XCTAssertTrue(
        try ColourDecision.evaluate(control: control, colour: ColourState(), now: now, calendar: calendar())
          .filtersOn)
    }
    lease.state = .active
    control.leases = [lease]
    XCTAssertFalse(
      try ColourDecision.evaluate(control: control, colour: ColourState(), now: now, calendar: calendar())
        .filtersOn)
    control.monitorFailed = true
    XCTAssertTrue(
      try ColourDecision.evaluate(control: control, colour: ColourState(), now: now, calendar: calendar())
        .filtersOn)
  }
  func testRepeatedColourRequestAndRestartPreserveEndpointWithoutTouchingAppState() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let control = try ControlDatabase(directory: root)
    let before = try control.load()
    let store = try ColourStore(directory: root)
    let now = date("2026-10-05T18:00:00Z")
    let first = try store.start(now: now)
    let second = try ColourStore(directory: root).start(now: now.addingTimeInterval(60))
    XCTAssertEqual(first, second)
    XCTAssertEqual(first.expiresAt.timeIntervalSince(now), 900)
    try store.end()
    XCTAssertNil(try ColourStore(directory: root).load().interval)
    XCTAssertEqual(try control.load(), before)
    XCTAssertEqual(try store.load().revision, 3)
  }
  func testUnreadableOrFutureColourFormatDoesNotResetSavedState() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ColourStore(directory: root)
    let file = root.appendingPathComponent("colour-v1.json")
    for bytes in [Data("broken".utf8), Data("{\"version\":2,\"revision\":0}".utf8)] {
      try bytes.write(to: file)
      XCTAssertThrowsError(try store.start(now: Date()))
      XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
  }
  func testIndependentWritersDoNotLoseUpdates() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let writers = try (0..<4).map { _ in try ColourStore(directory: root) }
    let errors = NSLock()
    var failures = 0
    DispatchQueue.concurrentPerform(iterations: 4) { index in
      do { for _ in 0..<50 { try writers[index].update { _ in } } } catch {
        errors.lock()
        failures += 1
        errors.unlock()
      }
    }
    XCTAssertEqual(failures, 0)
    XCTAssertEqual(try writers[0].load().revision, 200)
  }
}
