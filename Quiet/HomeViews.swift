import FamilyControls
import QuietCore
import SwiftUI

enum RestrictionPresentation: Equatable {
  case setupUnavailable, checking, finishSetup, permissionNeeded, checkRestrictions, freshSetup
  case firstLaunch, unlockOthers, remoteUnavailable
  case locked
  case active(Date)
}

struct StatusView: View {
  @EnvironmentObject private var model: QuietModel
  @ScaledMetric(relativeTo: .largeTitle) private var heroSize = 58
  @ScaledMetric(relativeTo: .largeTitle) private var deadlineSize = 70
  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          VStack(alignment: .leading, spacing: 20) {
            Rectangle().fill(QuietDesign.ink).frame(width: 32, height: 3)
            if case .active(let end) = model.presentation {
              Text("Unlocked until").font(.title3)
              Text(CalmTime.deadline(end))
                .font(.system(size: deadlineSize, weight: .regular)).monospacedDigit()
                .minimumScaleFactor(0.6)
              if !Calendar.current.isDate(end, inSameDayAs: model.now) {
                Text(end.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                  .foregroundStyle(QuietDesign.muted)
              }
              Text("Everything").font(.title3)
              if let name = model.activeLease?.remoteName {
                Text("Unlocked by \(name).").foregroundStyle(QuietDesign.muted)
              }
            } else {
              Text("Locked").font(.system(size: heroSize, weight: .medium))
              Text("App restrictions on.").font(.title3)
              Text("Allowed apps stay available.").foregroundStyle(QuietDesign.muted)
            }
          }
          .accessibilityElement(children: .combine)
          .padding(.top, geometry.size.height * 0.19)
          Spacer(minLength: 48)
          Button(model.activeLease == nil ? "Unlock" : "Lock now") {
            if model.activeLease == nil { model.askGuardian() } else { model.lockNow() }
          }.buttonStyle(CalmPrimaryButtonStyle()).padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .leading)
        .padding(.horizontal, 24)
      }
    }
    .navigationTitle("Calm Phone").navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        NavigationLink("Settings") { SettingsView() }
      }
    }
  }
}

struct RecoveryView: View {
  @EnvironmentObject private var model: QuietModel
  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          Spacer(minLength: geometry.size.height * 0.14)
          if model.presentation == .checking { ProgressView() }
          Text(title).font(.largeTitle).fontWeight(.semibold)
          Text(detail).foregroundStyle(QuietDesign.muted)
          Spacer(minLength: 48)
          if model.presentation != .checking {
            Button(actionTitle) {
              switch model.presentation {
              case .finishSetup: model.resumeEnrollment()
              case .freshSetup: model.showingSetup = true
              case .permissionNeeded:
                Task {
                  do { try await model.approveScreenTime() } catch {
                    model.error = "Screen Time access was not approved. Try again."
                  }
                }
              default: model.refresh()
              }
            }.buttonStyle(CalmPrimaryButtonStyle())
          }
        }.frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .leading)
          .padding(.horizontal, 24)
      }
    }.navigationTitle("Calm Phone").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        if model.state.setupComplete, model.hasCredential, !model.needsControlRepair {
          ToolbarItem(placement: .topBarTrailing) {
            NavigationLink("Settings") { SettingsView() }
          }
        }
      }
  }
  private var title: String {
    switch model.presentation {
    case .checking: return "Checking restrictions…"
    case .finishSetup: return "Finish setup"
    case .permissionNeeded: return "Screen Time access needed"
    case .checkRestrictions: return "Check restrictions"
    case .freshSetup: return "Set up Calm Phone"
    default: return "Setup unavailable"
    }
  }
  private var detail: String {
    switch model.presentation {
    case .checking: return "Checking Screen Time access."
    case .finishSetup: return "Your saved apps and limits are here."
    case .permissionNeeded: return "Continue to approve Screen Time access."
    case .checkRestrictions: return "App restrictions could not be confirmed. Try again."
    case .freshSetup:
      return "Choose allowed apps and daily limits with the PIN holder. Restrictions start after setup."
    default: return "Your saved setup could not be read."
    }
  }
  private var actionTitle: String {
    switch model.presentation {
    case .finishSetup: return "Continue with the PIN holder"
    case .permissionNeeded: return "Continue"
    case .freshSetup: return "Set up with the PIN holder"
    default: return "Try again"
    }
  }
}

struct SettingsView: View {
  @EnvironmentObject private var model: QuietModel
  var body: some View {
    List {
      Section {
        NavigationLink("Apps and limits") { AppsAndLimitsView() }
        NavigationLink("History") { HistoryDestinationView() }
        NavigationLink("Colour") { ColourView() }
        NavigationLink {
          UnlockMethodsView()
        } label: {
          LabeledContent(
            "Unlock methods", value: (["PIN"] + model.remotes.remotes.map(\.name)).joined(separator: " · "))
        }
        if !model.connections.connections.isEmpty {
          NavigationLink("Unlock others") { UnlockOthersView() }
        }
      }.listRowBackground(QuietDesign.surface)
      Section {
        Text(
          "Calm Phone \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""))"
        )
        .font(.footnote).foregroundStyle(QuietDesign.muted).frame(maxWidth: .infinity)
      }.listRowBackground(Color.clear)
    }.scrollContentBackground(.hidden).background(QuietDesign.paper)
      .navigationTitle("Settings")
  }
}

struct AppsAndLimitsView: View {
  @EnvironmentObject private var model: QuietModel
  var body: some View {
    List {
      if let policy = model.state.policy {
        Section {
          Text("\(policy.tokens.count) apps selected").foregroundStyle(QuietDesign.muted)
        }.listRowBackground(Color.clear)
        Section("Daily limits") {
          ForEach(policy.limits) { rule in
            HStack {
              SavedAppLabel(app: rule.app)
              Spacer()
              Text("\(rule.minutes) min/day").foregroundStyle(QuietDesign.muted)
            }
          }
        }.listRowBackground(QuietDesign.surface)
        Section("Always available") {
          NavigationLink {
            AllowedAppsView()
          } label: {
            HStack {
              Text("Allowed apps")
              Spacer()
              Text("\(policy.allowed.count)").foregroundStyle(QuietDesign.muted)
            }
          }
        }.listRowBackground(QuietDesign.surface)
        Section { Text("Editing needs the PIN.").font(.footnote).foregroundStyle(QuietDesign.muted) }
          .listRowBackground(Color.clear)
      } else {
        Text("Your saved setup could not be read.")
      }
    }.scrollContentBackground(.hidden).background(QuietDesign.paper)
      .navigationTitle("Apps and limits")
      .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Edit") { model.editPolicy() } } }
  }
}

struct AllowedAppsView: View {
  @EnvironmentObject private var model: QuietModel
  var body: some View {
    List(model.state.policy?.allowed ?? []) { app in
      SavedAppLabel(app: app).listRowBackground(QuietDesign.surface)
    }
    .scrollContentBackground(.hidden).background(QuietDesign.paper).navigationTitle("Allowed apps")
  }
}

struct SavedAppLabel: View {
  let app: AppEntry
  var body: some View {
    if let token = try? TokenCodec.decode(app.token) {
      Label(token)
    } else {
      Label(
        app.label == BulkSetupDraft.unnamedLabel ? "App label unavailable" : app.label,
        systemImage: "app")
    }
  }
}
