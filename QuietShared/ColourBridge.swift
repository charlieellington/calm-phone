import Foundation
import QuietCore
import UIKit

enum ColourBridge {
  // Daily phone automations cannot guarantee a run at an arbitrary unlock deadline.
  // Keep every timed entry point closed until that separate actuator exists.
  static let supportsTimedReturn = false
  static func store() throws -> ColourStore { try ColourStore(directory: SharedContainer.directory()) }
  static func decision(now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) throws -> ColourDecision
  {
    // Daily runs use only the local clock while timed return is unavailable. A control-store
    // read error must not prevent the fixed schedule from being applied.
    guard supportsTimedReturn else { return try ColourDecision.evaluate(now: now, calendar: calendar) }
    let control = try SharedContainer.database().load()
    let colour = try store().load()
    return try supportedDecision(control: control, colour: colour, now: now, calendar: calendar)
  }
  static func supportedDecision(
    control: ControlState, colour: ColourState, now: Date, calendar: Calendar
  ) throws -> ColourDecision {
    guard supportsTimedReturn else {
      return try ColourDecision.evaluate(now: now, calendar: calendar)
    }
    return try ColourDecision.evaluate(
      control: control, colour: colour, now: now, calendar: calendar)
  }
  static func startColourOnly(now: Date = Date()) throws -> Date {
    guard supportsTimedReturn else { throw ColourAutomationError.timedReturnUnavailable }
    return try store().start(now: now).expiresAt
  }
  @MainActor static func recordApplication(now: Date = Date()) throws -> Bool {
    let decision = try decision(now: now)
    let actual = UIAccessibility.isGrayscaleEnabled
    try store().update {
      $0.lastApplication = ColourApplication(
        checkedAt: now, filtersOn: actual, matched: actual == decision.filtersOn)
    }
    return actual == decision.filtersOn
  }
}

enum ColourAutomationError: LocalizedError {
  case timedReturnUnavailable
  var errorDescription: String? {
    "Timed colour is unavailable because automatic return at its deadline is not supported."
  }
}
