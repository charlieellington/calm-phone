import Foundation
import XCTest

@testable import QuietCore

final class GrantDraftTests: XCTestCase {
  private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
  private func calendar(_ zone: String) -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: zone)!
    return c
  }
  private func coordinator(
    _ h: Harness, calendar: @escaping () -> Calendar = { CivilTime.calendar },
    uptime: @escaping () -> TimeInterval
  ) -> PolicyCoordinator {
    PolicyCoordinator(
      database: h.database, scheduler: h.scheduler, clock: { h.clock.now },
      approved: { h.isApproved }, apply: { h.projections.append($0) }, localCalendar: calendar, uptime: uptime
    )
  }
  func testDelayedConfirmationAndRegistrationPreservePreviewDeadlineAndOriginalInterval() throws {
    for choice in [LeaseChoice.quarterHour, .hour] {
      let h = try Harness()
      try h.setup()
      var uptime = 100.0
      let c = coordinator(h, uptime: { uptime })
      let auth = try h.authorization()
      let draft = try GrantDraft.prepare(
        choice, now: h.clock.now, calendar: CivilTime.calendar, uptime: uptime)
      h.clock.now += 20
      uptime += 20
      h.scheduler.beforeLease = {
        h.clock.now += 10
        uptime += 10
      }
      try c.grant(draft, authorization: auth)
      let lease = try XCTUnwrap(h.database.load().openLease)
      XCTAssertEqual(lease.requestedAt, draft.requestedAt)
      XCTAssertEqual(lease.expiresAt, draft.expiresAt)
      XCTAssertEqual(lease.activatedAt, h.clock.now)
      XCTAssertEqual(lease.expiresAt.timeIntervalSince(lease.requestedAt), choice == .hour ? 3600 : 900)
      XCTAssertTrue(h.scheduler.isRegistered(lease.activityName))
      XCTAssertThrowsError(try c.grant(draft, authorization: auth))
      let day = CivilTime.calendar.dateInterval(of: .day, for: h.clock.now)!
      XCTAssertEqual(CivilTime.seconds([lease], day: day, now: h.clock.now), 0)
    }
  }
  func testDraftClockChangeTimeZoneChangeExpiryAndCancellationFailClosed() throws {
    for scenario in 0..<5 {
      let h = try Harness()
      try h.setup()
      var uptime = 100.0
      var local = CivilTime.calendar
      let c = coordinator(h, calendar: { local }, uptime: { uptime })
      let auth = try h.authorization()
      let draft = try GrantDraft.prepare(.quarterHour, now: h.clock.now, calendar: local, uptime: uptime)
      switch scenario {
      case 0: h.clock.now += 5  // Wall time jumped, monotonic time did not.
      case 1: local = calendar("America/New_York")
      case 2:
        h.clock.now += 61
        uptime += 61
      case 3: auth.invalidate()
      default: h.clock.now -= 5
      }
      XCTAssertThrowsError(try c.grant(draft, authorization: auth))
      XCTAssertNil(try h.database.load().openLease)
      XCTAssertFalse(h.projections.last!.isOpen)
    }
  }
  func testMidnightBoundaryMinimumAndMonthYearBoundariesUseLocalCalendar() throws {
    let c = calendar("America/New_York")
    let exact = date("2026-10-06T03:45:00Z")
    let draft = try GrantDraft.prepare(.midnight, now: exact, calendar: c, uptime: 100)
    XCTAssertEqual(draft.expiresAt, date("2026-10-06T04:00:00Z"))
    try draft.validate(now: exact, calendar: c, uptime: 100)
    XCTAssertThrowsError(try draft.validate(now: exact + 1, calendar: c, uptime: 101))
    XCTAssertThrowsError(try GrantDraft.prepare(.midnight, now: exact + 0.01, calendar: c))
    XCTAssertThrowsError(try GrantDraft.prepare(.midnight, now: exact + 600, calendar: c))
    for (start, end) in [
      ("2026-10-06T04:00:00Z", "2026-10-07T04:00:00Z"),
      ("2026-11-01T04:00:01Z", "2026-11-02T05:00:00Z"),
      ("2026-12-31T12:00:00Z", "2027-01-01T05:00:00Z"),
    ] {
      XCTAssertEqual(try GrantDraft.prepare(.midnight, now: date(start), calendar: c).expiresAt, date(end))
    }
  }
  func testMidnightDSTDaysAreCalendarDaysAndNeverTwentyFourHourOffsets() throws {
    let c = CivilTime.calendar
    for (start, end, hours) in [
      ("2026-03-28T23:00:00Z", "2026-03-29T22:00:00Z", 23.0),
      ("2026-10-24T22:00:00Z", "2026-10-25T23:00:00Z", 25.0),
    ] {
      let draft = try GrantDraft.prepare(.midnight, now: date(start), calendar: c)
      XCTAssertEqual(draft.expiresAt, date(end))
      XCTAssertEqual(draft.expiresAt.timeIntervalSince(draft.requestedAt), hours * 3600)
    }
  }
  func testMidnightMinimumIsRecheckedAtConfirmationAndAfterRegistration() throws {
    for atRegistration in [false, true] {
      let h = try Harness()
      h.clock.now = date("2026-10-05T21:45:00Z")
      try h.setup()
      var uptime = 100.0
      let c = coordinator(h, uptime: { uptime })
      let auth = try h.authorization()
      let draft = try GrantDraft.prepare(
        .midnight, now: h.clock.now, calendar: CivilTime.calendar, uptime: uptime)
      if atRegistration {
        h.scheduler.beforeLease = {
          h.clock.now += 1
          uptime += 1
        }
      } else {
        h.clock.now += 1
        uptime += 1
      }
      XCTAssertThrowsError(try c.grant(draft, authorization: auth))
      XCTAssertNil(try h.database.load().openLease)
      XCTAssertFalse(h.projections.last!.isOpen)
      XCTAssertTrue(h.scheduler.names.allSatisfy { !$0.hasPrefix("quiet.lease.") })
    }
  }
  func testFailureAndExpiredRegistrationDoNotActivateOrExtendDraft() throws {
    for expires in [false, true] {
      let h = try Harness()
      try h.setup()
      var uptime = 100.0
      let c = coordinator(h, uptime: { uptime })
      let auth = try h.authorization()
      let draft = try GrantDraft.prepare(
        .quarterHour, now: h.clock.now, calendar: CivilTime.calendar, uptime: uptime)
      if expires {
        h.scheduler.beforeLease = {
          h.clock.now += 61
          uptime += 61
        }
      } else {
        h.scheduler.fail = true
      }
      XCTAssertThrowsError(try c.grant(draft, authorization: auth))
      XCTAssertNil(try h.database.load().openLease)
      XCTAssertNil(try h.database.load().leases.last?.activatedAt)
      XCTAssertEqual(try h.database.load().leases.last?.expiresAt, draft.expiresAt)
      XCTAssertFalse(h.projections.last!.isOpen)
    }
  }
  func testDraftPromotionIsBoundToRemainingPINCapabilityRatherThanPreviewAge() throws {
    let h = try Harness()
    try h.setup()
    var uptime = 100.0
    let c = coordinator(h, uptime: { uptime })
    let auth = try h.authorization()
    h.clock.now += 50
    uptime += 50
    let draft = try GrantDraft.prepare(
      .quarterHour, now: h.clock.now, calendar: CivilTime.calendar, uptime: uptime)
    h.clock.now += 5
    uptime += 5
    h.scheduler.beforeLease = {
      h.clock.now += 6
      uptime += 6
    }
    XCTAssertThrowsError(try c.grant(draft, authorization: auth)) {
      XCTAssertEqual($0 as? QuietError, .expiredAuthorization)
    }
    XCTAssertNil(try h.database.load().openLease)
    XCTAssertNil(try h.database.load().leases.last?.activatedAt)
  }
  func testFailedLeaseRegistrationCanReconfirmPermanentRestrictionsWithoutChangingPolicy() throws {
    let h = try Harness()
    try h.setup()
    let before = try h.database.load().policy
    h.scheduler.fail = true
    XCTAssertThrowsError(try h.coordinator.grant(.quarterHour, authorization: h.authorization()))
    XCTAssertTrue(try h.database.load().monitorFailed)
    h.scheduler.fail = false
    try h.coordinator.reconcile()
    XCTAssertFalse(try h.database.load().monitorFailed)
    XCTAssertEqual(try h.database.load().policy, before)
    XCTAssertFalse(h.projections.last!.isOpen)
  }
  func testPINMismatchKeepsOldCredentialAndReplacementCapabilityForCorrection() throws {
    let h = try Harness()
    try h.setup()
    let auth = try h.authorization(.replacePIN)
    let before = h.credentials.value!.derivedKey
    XCTAssertThrowsError(
      try h.pin.replace(TestPIN.replacement, confirmation: TestPIN.wrong, authorization: auth))
    XCTAssertEqual(h.credentials.value!.derivedKey, before)
    try h.pin.replace(TestPIN.replacement, confirmation: TestPIN.replacement, authorization: auth)
    XCTAssertNotEqual(h.credentials.value!.derivedKey, before)
    XCTAssertThrowsError(
      try h.pin.replace(TestPIN.primary, confirmation: TestPIN.primary, authorization: auth))
  }
  func testLockoutEndpointIsPersistedAndDoesNotExposeCredential() throws {
    let h = try Harness()
    try h.setup()
    for _ in 0..<5 { XCTAssertThrowsError(try h.pin.verify(TestPIN.wrong, operation: .lease)) }
    XCTAssertEqual(try h.newVerifier().lockoutEndpoint(), h.clock.now + 900)
    h.clock.now += 899
    XCTAssertNotNil(try h.pin.lockoutEndpoint())
    h.clock.now += 1
    XCTAssertNil(try h.pin.lockoutEndpoint())
    XCTAssertNoThrow(try h.authorization())
  }
}
