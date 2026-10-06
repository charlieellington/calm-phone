import AppIntents
import QuietCore

struct ColourFiltersRequiredIntent: AppIntent {
  static let title: LocalizedStringResource = "Get Calm Phone colour setting"
  static let description = IntentDescription(
    "Returns on or off for Grayscale Colour Filters now. Does not unlock apps.")
  static let openAppWhenRun = false
  static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    .result(value: try ColourBridge.decision().filtersOn ? "on" : "off")
  }
}

struct CheckColourApplicationIntent: AppIntent {
  static let title: LocalizedStringResource = "Check Calm Phone colour"
  static let description = IntentDescription(
    "Checks the actual Grayscale setting after the shortcut applies it. Does not grant app access.")
  static let openAppWhenRun = false
  static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
  @MainActor func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
    .result(value: try ColourBridge.recordApplication())
  }
}

struct StartColourOnlyIntent: AppIntent {
  static let title: LocalizedStringResource = "Request colour for 15 minutes"
  static let description = IntentDescription(
    "Sets a display-only endpoint. Follow with Calm Phone Colour; does not change app restrictions.")
  static let openAppWhenRun = false
  static var isDiscoverable: Bool { ColourBridge.supportsTimedReturn }
  func perform() async throws -> some IntentResult & ReturnsValue<Date> {
    .result(value: try ColourBridge.startColourOnly())
  }
}

struct ReturnColourScheduleIntent: AppIntent {
  static let title: LocalizedStringResource = "Return colour to schedule"
  static let description = IntentDescription(
    "Ends only display-only colour. Follow with Calm Phone Colour. PIN-authorised app access remains unchanged."
  )
  static let openAppWhenRun = false
  static var isDiscoverable: Bool { ColourBridge.supportsTimedReturn }
  func perform() async throws -> some IntentResult {
    try ColourBridge.store().end()
    return .result()
  }
}

struct CalmColourShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: ColourFiltersRequiredIntent(), phrases: ["Get colour setting from \(.applicationName)"],
      shortTitle: "Get colour setting", systemImageName: "circle.lefthalf.filled")
  }
}
