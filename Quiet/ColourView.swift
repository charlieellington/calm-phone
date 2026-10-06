import QuietCore
import SwiftUI

@MainActor final class ColourSettingsModel: ObservableObject {
  @Published private(set) var decision: ColourDecision?
  @Published private(set) var state = ColourState()
  @Published private(set) var error: String?
  private let readState: () throws -> ColourState
  private let readDecision: () throws -> ColourDecision
  init(
    readState: @escaping () throws -> ColourState = { try ColourBridge.store().load() },
    readDecision: @escaping () throws -> ColourDecision = { try ColourBridge.decision() }
  ) {
    self.readState = readState
    self.readDecision = readDecision
    refresh()
  }
  func refresh() {
    do {
      state = try readState()
      decision = try readDecision()
      error = nil
    } catch {
      decision = nil
      self.error = "Colour settings could not be read. App restrictions are unchanged."
    }
  }
}

struct ColourView: View {
  @StateObject private var model: ColourSettingsModel
  @Environment(\.scenePhase) private var scenePhase
  @MainActor init(model: ColourSettingsModel? = nil) {
    _model = StateObject(wrappedValue: model ?? ColourSettingsModel())
  }
  var body: some View {
    List {
      Section("Schedule · phone local time") {
        LabeledContent("09:00–19:00", value: "Colour")
        LabeledContent("At other times", value: "Black and white")
      }.listRowBackground(QuietDesign.surface)
      Section("Phone setup required") {
        Text("Add Calm Phone Colour in Shortcuts and run it automatically at 09:00 and 19:00.")
        NavigationLink("Set up automatic colour") { ColourSetupView() }
        Text("To apply or check the schedule now, run Calm Phone Colour in Shortcuts.")
        if let application = model.state.lastApplication {
          Text("Last checked \(application.checkedAt.formatted(date: .abbreviated, time: .shortened))")
            .font(.footnote).foregroundStyle(QuietDesign.muted)
          Text(
            application.matched
              ? "Grayscale matched the expected setting at that check."
              : "Grayscale did not match the expected setting at that check."
          )
          .font(.footnote)
        } else {
          Text("No successful phone check recorded.").font(.footnote).foregroundStyle(QuietDesign.muted)
        }
      }.listRowBackground(QuietDesign.surface)
      if let error = model.error {
        Section { Text(error) }.listRowBackground(QuietDesign.surface)
      }
      Section {
        Text("Colour changes do not unlock apps. Your manual Accessibility Shortcut remains available.")
          .font(.footnote).foregroundStyle(QuietDesign.muted)
      }.listRowBackground(Color.clear)
    }.scrollContentBackground(.hidden).background(QuietDesign.paper)
      .navigationTitle("Colour")
      .onAppear { model.refresh() }
      .onChange(of: scenePhase) { _, phase in if phase == .active { model.refresh() } }
  }
}

struct ColourSetupView: View {
  var body: some View {
    List {
      Section("Grayscale") {
        Text(
          "In Settings → Accessibility → Display & Text Size → Colour Filters, select Grayscale. Keep your Accessibility Shortcut."
        )
      }.listRowBackground(QuietDesign.surface)
      Section("Calm Phone Colour shortcut") {
        Text("Add the supplied Calm Phone Colour shortcut. Let it sync to this iPhone.")
      }.listRowBackground(QuietDesign.surface)
      Section("Daily automation") {
        Text(
          "Create Time of Day automations at 09:00 and 19:00. Each runs Calm Phone Colour using Run Immediately, with Notify When Run off."
        )
        Text(
          "Check both while the phone is locked and Shortcuts is restricted. Leave existing app selections, Focus and notifications unchanged."
        )
      }.listRowBackground(QuietDesign.surface)
    }.scrollContentBackground(.hidden).background(QuietDesign.paper)
      .navigationTitle("Set up colour")
  }
}
