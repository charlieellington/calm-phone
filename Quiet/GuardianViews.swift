import QuietCore
import SwiftUI

/// Native secure positions and number buttons, matching the reviewed entry layout.
struct PINEntryView: View {
  let title: String
  @Binding var digits: String
  var error = ""
  var lockedUntil: Date?
  let continueAction: () -> Void
  let cancelAction: () -> Void
  private let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "delete"]
  var body: some View {
    NavigationStack {
      GeometryReader { geometry in
        ScrollView {
          VStack(alignment: .leading, spacing: 24) {
            Text(title).font(.largeTitle.weight(.semibold))
            Text("6-digit PIN").foregroundStyle(QuietDesign.muted)
            HStack(spacing: 16) {
              ForEach(0..<6, id: \.self) { index in
                Circle().fill(index < digits.count ? QuietDesign.ink : .clear)
                  .overlay(Circle().stroke(QuietDesign.muted, lineWidth: 1.5)).frame(width: 13, height: 13)
              }
            }.frame(maxWidth: .infinity).padding(.vertical, 24).privacySensitive()
              .accessibilityElement(children: .ignore).accessibilityLabel(
                "\(digits.count) of 6 digits entered")
            if let until = lockedUntil {
              Text(
                "Too many attempts. Try again at \(until.formatted(date: Calendar.current.isDateInToday(until) ? .omitted : .abbreviated, time: .shortened))."
              )
            } else if !error.isEmpty {
              Text(error).accessibilityLabel(error)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 2) {
              ForEach(keys, id: \.self) { key in
                if key.isEmpty {
                  Color.clear.frame(minHeight: 58).accessibilityHidden(true)
                } else {
                  Button {
                    if key == "delete" {
                      if !digits.isEmpty { digits.removeLast() }
                    } else if digits.count < 6 {
                      digits += key
                    }
                  } label: {
                    Group {
                      if key == "delete" { Image(systemName: "delete.left") } else { Text(key) }
                    }.font(.title).frame(maxWidth: .infinity, minHeight: 58)
                  }.buttonStyle(.plain).disabled(lockedUntil != nil)
                    .accessibilityLabel(key == "delete" ? "Delete last digit" : key)
                }
              }
            }
            Spacer(minLength: 32)
            Button("Continue", action: continueAction).buttonStyle(CalmPrimaryButtonStyle())
              .disabled(digits.count != 6 || lockedUntil != nil)
          }.padding(24).frame(minHeight: geometry.size.height, alignment: .topLeading)
        }.background(QuietDesign.paper)
      }.toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancelAction) } }
    }
  }
}

struct PINView: View {
  @EnvironmentObject private var model: QuietModel
  @Environment(\.scenePhase) private var scenePhase
  @State private var pin = ""
  @State private var error = ""
  var body: some View {
    PINEntryView(
      title: "Enter the PIN", digits: $pin, error: error,
      lockedUntil: model.lockoutEndpoint,
      continueAction: {
        let entered = pin
        pin = ""
        do { try model.verify(entered) } catch { self.error = error.localizedDescription }
      }, cancelAction: model.cancelGuardian
    )
    .onChange(of: scenePhase) { _, phase in if phase != .active { pin = "" } }
    .onDisappear { pin = "" }
  }
}

struct DurationView: View {
  @EnvironmentObject private var model: QuietModel
  private var midnightAvailable: Bool { (try? GrantDraft.prepare(.midnight, now: model.now)) != nil }
  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          Text("Unlock for").font(.largeTitle.weight(.semibold))
          ForEach(LeaseChoice.allCases, id: \.self) { choice in
            Button {
              model.prepareGrant(choice)
            } label: {
              HStack {
                Text(label(choice)).font(.title3)
                Spacer()
                Image(systemName: model.grantDraft?.choice == choice ? "largecircle.fill.circle" : "circle")
              }.padding(20).frame(minHeight: 75)
                .background(model.grantDraft?.choice == choice ? QuietDesign.surface : QuietDesign.paper)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                  RoundedRectangle(cornerRadius: 16).stroke(
                    model.grantDraft?.choice == choice ? QuietDesign.ink : QuietDesign.separator))
            }.buttonStyle(.plain).disabled(choice == .midnight && !midnightAvailable)
              .accessibilityAddTraits(model.grantDraft?.choice == choice ? [.isSelected] : [])
          }
          if !midnightAvailable {
            Text("Midnight is less than 15 minutes away.").font(.footnote).foregroundStyle(QuietDesign.muted)
          }
          HStack {
            Text("Access").foregroundStyle(QuietDesign.muted)
            Spacer()
            Text("Everything")
          }
          Divider().overlay(QuietDesign.separator)
          HStack(alignment: .top) {
            Text("Until").foregroundStyle(QuietDesign.muted)
            Spacer()
            if let draft = model.grantDraft {
              VStack(alignment: .trailing, spacing: 4) {
                Text(CalmTime.deadline(draft.expiresAt)).monospacedDigit()
                if !Calendar.current.isDate(draft.expiresAt, inSameDayAs: model.now) {
                  Text(draft.expiresAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                    .font(.footnote).foregroundStyle(QuietDesign.muted)
                }
              }
            }
          }
          Divider().overlay(QuietDesign.separator)
          Spacer(minLength: 32)
          Button(model.granting ? "Unlocking…" : "Unlock") { model.confirmGrant() }
            .buttonStyle(CalmPrimaryButtonStyle()).disabled(model.grantDraft == nil || model.granting)
          Button("Cancel") { model.cancelGuardian() }.frame(maxWidth: .infinity, minHeight: 44)
        }.padding(24).frame(minHeight: geometry.size.height, alignment: .topLeading)
      }.background(QuietDesign.paper)
    }
  }
  private func label(_ choice: LeaseChoice) -> String {
    switch choice {
    case .quarterHour: "15 minutes"
    case .hour: "1 hour"
    case .midnight: "Until midnight"
    }
  }
}

struct NewPINView: View {
  @EnvironmentObject private var model: QuietModel
  @Environment(\.scenePhase) private var scenePhase
  @State private var pin = ""
  @State private var confirmation = ""
  @State private var confirming = false
  @State private var error = ""
  var body: some View {
    PINEntryView(
      title: confirming ? "Confirm new PIN" : "New PIN",
      digits: confirming ? $confirmation : $pin, error: error,
      continueAction: {
        if !confirming {
          confirming = true
          return
        }
        guard pin == confirmation else {
          error = "PINs don’t match. Try again."
          confirmation = ""
          return
        }
        do { try model.savePIN(pin, confirmation: confirmation) } catch {
          self.error = error.localizedDescription
        }
      }, cancelAction: model.cancelGuardian
    )
    .onDisappear { clear() }
    .onChange(of: scenePhase) { _, phase in if phase != .active { clear() } }
  }
  private func clear() {
    pin = ""
    confirmation = ""
  }
}
