import FamilyControls
import QuietCore
import SwiftUI

struct SetupView: View {
  @EnvironmentObject private var model: QuietModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @State private var draft = BulkSetupDraft()
  @State private var selection = FamilyActivitySelection()
  @State private var showingPicker = false
  @State private var pin = ""
  @State private var confirmation = ""
  @State private var error = ""
  @State private var reviewed = false
  @State private var loadedDraft = false
  private var savedPolicy: Policy? {
    model.state.setupComplete ? model.state.policy : model.state.pendingPolicy
  }
  private var otherApps: [AppEntry] {
    draft.applications.filter { !draft.assignments.values.contains($0.id) }
  }
  private var selectionError: String? {
    if !selection.categoryTokens.isEmpty || !selection.webDomainTokens.isEmpty {
      return "Choose individual apps. Deselect whole categories and websites in the picker."
    }
    do {
      let tokens = try Set(draft.applications.map { try TokenCodec.decode($0.token) })
      guard tokens == selection.applicationTokens else {
        return "Couldn’t read all selected apps. Open the app picker again."
      }
      _ = try draft.policy(previous: savedPolicy)
      return nil
    } catch { return error.localizedDescription }
  }
  var body: some View {
    NavigationStack {
      Form {
        Section("Apps and limits") {
          Text("Choose allowed apps and the six apps with daily limits.")
          Text("Changes apply when you save.")
          Button(model.state.authorizationApproved ? "Screen Time approved" : "approve Screen Time") {
            Task {
              do {
                try await model.approveScreenTime()
              } catch { self.error = "Screen Time access was not approved." }
            }
          }
        }
        Section("Selected apps") {
          Button {
            showingPicker = true
          } label: {
            HStack {
              Text("Selected apps")
              Spacer()
              Text("\(draft.applications.count) selected").font(.caption)
            }
          }
          .disabled(!model.state.authorizationApproved)
          .accessibilityIdentifier("setup-select-apps")
          Text("Pick apps, not entire categories or websites. Choose at most 50 apps in total.")
            .font(.footnote)
        }
        Section("Daily limits") {
          Text("Choose each app from your selection above. All other selected apps stay allowed.")
            .font(.footnote)
          ForEach(Policy.quotas.keys.sorted(), id: \.self) { id in
            assignmentRow(
              id, label: "\(id.replacingOccurrences(of: "-", with: " ")) · \(draft.minutes[id]!) min / day")
            if model.state.setupComplete {
              Stepper(
                "\(draft.minutes[id]!) minutes",
                value: Binding(
                  get: { draft.minutes[id]! },
                  set: {
                    draft.minutes[id] = $0
                    changed()
                  }), in: 1...1440)
            }
          }
        }
        Section("Review") {
          ForEach(draft.applications) { app in
            HStack {
              if let token = try? TokenCodec.decode(app.token) { Label(token).labelStyle(.titleOnly) }
              Spacer()
              let role = draft.assignments.first { $0.value == app.id }?.key
              if let role, let minutes = draft.minutes[role] {
                Text("\(minutes) min / day").font(.caption)
              } else {
                Text("Allowed").font(.caption)
              }
            }
          }
          if let selectionError { Text(selectionError).foregroundStyle(QuietDesign.amber) }
          Toggle("The PIN holder reviewed allowed apps and all six limits", isOn: $reviewed)
            .disabled(selectionError != nil)
          Text(
            "Removal and installation restrictions stay on during temporary access. The PIN holder’s iOS Screen Time code is separate from this app PIN."
          )
        }
        if !model.hasCredential {
          Section("Set the private PIN") {
            SecureField("six digits", text: $pin).keyboardType(.numberPad).privacySensitive()
            SecureField("confirm six digits", text: $confirmation).keyboardType(.numberPad).privacySensitive()
          }
        }
        Section {
          if !error.isEmpty { Text(error).foregroundStyle(QuietDesign.amber) }
          Button(model.state.setupComplete ? "Save changes" : "Activate restrictions") { activate() }
            .disabled(!model.state.authorizationApproved || !reviewed || selectionError != nil)
        }
      }
      .navigationTitle(model.state.setupComplete ? "Edit apps and limits" : "Set up Calm Phone")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            model.cancelGuardian()
            dismiss()
          }
        }
      }
      .scrollContentBackground(.hidden)
      .background(QuietDesign.paper)
      .familyActivityPicker(
        isPresented: $showingPicker,
        selection: Binding(
          get: { selection },
          set: {
            guard $0.categoryTokens.isEmpty, $0.webDomainTokens.isEmpty else {
              error = "Choose individual apps. Deselect whole categories and websites in the picker."
              return
            }
            guard $0.applicationTokens.count <= 50 else {
              error = "50 apps selected. Remove an app before adding another."
              return
            }
            selection = $0
            syncSelection()
          })
      )
      .task { loadDraft() }
      .onChange(of: model.state.authorizationApproved) { _, approved in
        if !approved { discardSelections() } else { loadDraft() }
      }
      .onChange(of: model.state.pendingPolicy?.generation) { _, _ in loadDraft() }
      .onChange(of: model.state.policy?.generation) { _, _ in loadDraft() }
      .onChange(of: model.state.invalidatedSelectionTokens) { _, _ in discardSelections() }
      .onDisappear {
        pin = ""
        confirmation = ""
      }
      .onChange(of: scenePhase) { _, phase in
        if phase != .active {
          pin = ""
          confirmation = ""
        }
      }
    }.tint(QuietDesign.sage)
  }
  private func assignmentRow(_ id: String, label: String) -> some View {
    Picker(
      selection: Binding(
        get: { draft.assignments[id] ?? "" },
        set: { value in
          draft.assign(id, to: value.isEmpty ? nil : value)
          changed()
        })
    ) {
      Text("not selected").tag("")
      ForEach(draft.applications) { app in
        if let token = try? TokenCodec.decode(app.token) {
          Label(token).labelStyle(.titleOnly).tag(app.id)
        }
      }
    } label: {
      Text(label)
    }
    .pickerStyle(.navigationLink)
    .disabled(!model.state.authorizationApproved || draft.applications.isEmpty)
    .accessibilityIdentifier("setup-match-\(id)")
  }
  private func changed() {
    reviewed = false
    error = ""
  }
  private func syncSelection() {
    do {
      var apps: [AppEntry] = []
      for token in selection.applicationTokens {
        if let existing = draft.applications.first(where: { (try? TokenCodec.decode($0.token)) == token }) {
          apps.append(existing)
        } else {
          apps.append(
            AppEntry(
              id: "selected-\(UUID().uuidString)", label: BulkSetupDraft.unnamedLabel,
              token: try TokenCodec.encode(token)))
        }
      }
      let oldOrder = Dictionary(
        uniqueKeysWithValues: draft.applications.enumerated().map { ($0.element.id, $0.offset) })
      apps.sort {
        let first = oldOrder[$0.id] ?? Int.max
        let second = oldOrder[$1.id] ?? Int.max
        return first == second ? $0.token < $1.token : first < second
      }
      draft.replaceApplications(apps)
      changed()
    } catch { self.error = "Couldn’t read the selected apps. Open the app picker again." }
  }
  private func loadDraft() {
    guard !loadedDraft else { return }
    if draft.applications.isEmpty, let policy = savedPolicy {
      draft.minutes = Dictionary(uniqueKeysWithValues: policy.limits.map { ($0.app.id, $0.minutes) })
    }
    guard draft.applications.isEmpty, model.state.authorizationApproved, let policy = savedPolicy,
      !model.state.requiresFreshSelection(for: policy)
    else { return }
    do {
      selection.applicationTokens = try Set(
        (policy.allowed + policy.limits.map(\.app)).map { try TokenCodec.decode($0.token) })
      draft = BulkSetupDraft(policy: policy)
      loadedDraft = true
    } catch { self.error = "Couldn’t read the saved apps. Cancel and try again." }
  }
  private func discardSelections() {
    loadedDraft = false
    draft = BulkSetupDraft()
    selection = FamilyActivitySelection()
    changed()
    showingPicker = false
  }
  private func activate() {
    do {
      guard selectionError == nil else {
        error = selectionError ?? "Check your selections."
        return
      }
      let policy = try draft.policy(previous: savedPolicy)
      try TokenCodec.validate(policy)
      if model.hasCredential {
        try model.savePolicy(policy)
      } else {
        let entered = pin
        let repeated = confirmation
        pin = ""
        confirmation = ""
        try model.enroll(policy, pin: entered, confirmation: repeated)
      }
    } catch {
      self.error = error.localizedDescription
      model.refresh()
    }
  }
}
