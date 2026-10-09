// Remote unlock screens on the restricted phone: Unlock methods, Add remote and a remote's detail.
// Share sheets use UIActivityViewController so completion is known.
import QuietCore
import SwiftUI
import UIKit

struct ShareItem: Identifiable {
  let id = UUID()
  let message: String
  let url: URL
}

struct ActivitySheet: UIViewControllerRepresentable {
  let item: ShareItem
  let completion: (Bool) -> Void
  func makeUIViewController(context: Context) -> UIViewController {
    #if DEBUG && targetEnvironment(simulator)
      if ProcessInfo.processInfo.environment["CALM_UI_FIXTURE"] != nil {
        let controller = UIViewController()
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 24
        for (title, result) in [
          ("Complete test share", true), ("Cancel test share", false), ("Fail test share", false),
        ] {
          let button = UIButton(type: .system)
          button.setTitle(title, for: .normal)
          button.addAction(UIAction { _ in completion(result) }, for: .touchUpInside)
          stack.addArrangedSubview(button)
        }
        controller.view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
          stack.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
          stack.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor),
        ])
        return controller
      }
    #endif
    let controller = UIActivityViewController(
      activityItems: [item.message, item.url], applicationActivities: nil)
    controller.completionWithItemsHandler = { _, completed, _, error in completion(completed && error == nil)
    }
    return controller
  }
  func updateUIViewController(_ controller: UIViewController, context: Context) {}
}

enum RemoteCopy {
  static func connectMessage(owner: String) -> String {
    "Install Calm Phone, then open this link to connect to \(owner)’s phone"
  }
  static func when(_ date: Date) -> String {
    date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
  }
  static func duration(_ choice: LeaseChoice) -> String {
    switch choice {
    case .quarterHour: return "15 minutes"
    case .hour: return "1 hour"
    case .midnight: return "Until midnight"
    }
  }
}

struct UnlockMethodsView: View {
  @EnvironmentObject private var model: QuietModel
  @State private var message = ""
  var body: some View {
    List {
      if let error = model.remoteReadError {
        Section {
          Text(error)
          Button("Try again") { model.loadRemote() }
        }
      }
      if let warning = model.remoteMetadataError { Text(warning).font(.footnote) }
      Section {
        Button {
          model.replacePIN()
        } label: {
          row("PIN", "The PIN holder enters it on this phone")
        }
        ForEach(model.remotes.remotes) { remote in
          NavigationLink {
            RemoteDetailView(remote: remote, message: $message)
          } label: {
            row(
              remote.name,
              remote.lastUnlockAt.map { "Remote · last unlock \(RemoteCopy.when($0))" }
                ?? "Remote · link sent · not opened yet")
          }
        }
        NavigationLink {
          AddRemoteView(message: $message)
        } label: {
          Label("Add remote", systemImage: "plus")
        }
      }.listRowBackground(QuietDesign.surface)
      Section {
        Text(
          "A remote unlocks this phone by sending you a link from their own phone. They need Calm Phone installed."
        )
        .font(.footnote).foregroundStyle(QuietDesign.muted)
        if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(QuietDesign.muted) }
      }.listRowBackground(Color.clear)
    }.scrollContentBackground(.hidden).background(QuietDesign.paper).navigationTitle("Unlock methods")
  }
  private func row(_ title: String, _ detail: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
      Text(detail).font(.footnote).foregroundStyle(QuietDesign.muted)
    }.accessibilityElement(children: .combine)
  }
}

struct AddRemoteView: View {
  @EnvironmentObject private var model: QuietModel
  @Environment(\.dismiss) private var dismiss
  @Binding var message: String
  @State private var name = ""
  @State private var owner = ""
  @State private var share: ShareItem? = nil
  @State private var shared = false
  @State private var created: Remote? = nil
  @FocusState private var focusedField: String?
  private var valid: Bool {
    (try? RemoteName.validate(name)) != nil && (try? RemoteName.validate(owner)) != nil
  }
  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          Text("Add remote").font(.largeTitle.weight(.semibold))
          Text("They unlock this phone by sending you a link from their phone.").foregroundStyle(
            QuietDesign.muted)
          field("Their name", $name, "Their name")
          field("Your name", $owner, "Your name", hint: "Shown on their phone.")
          Text("They need Calm Phone installed on their phone.").font(.footnote).foregroundStyle(
            QuietDesign.muted)
          Spacer(minLength: 32)
          Button("Share link") {
            do {
              shared = false
              message = ""
              // Created on tap; a cancelled sheet leaves it listed so the link can be shared again.
              let remote = try created ?? model.addRemote(name: name, ownerName: owner)
              created = remote
              share = ShareItem(
                message: RemoteCopy.connectMessage(owner: model.remotes.ownerName),
                url: model.connectURL(for: remote))
            } catch { model.error = error.localizedDescription }
          }.buttonStyle(CalmPrimaryButtonStyle()).disabled(!valid)
        }.padding(24).frame(minHeight: geometry.size.height, alignment: .topLeading)
      }
      .scrollDismissesKeyboard(.interactively)
    }.background(QuietDesign.paper).navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItemGroup(placement: .keyboard) {
          Spacer()
          Button("Done") { focusedField = nil }.accessibilityIdentifier("remote-name-done")
        }
      }
      .onAppear { if owner.isEmpty { owner = model.remotes.ownerName } }
      .sheet(item: $share, onDismiss: finishSharing) { item in
        ActivitySheet(item: item) { completed in
          shared = completed
          share = nil
        }.ignoresSafeArea()
      }
  }
  /// Back to Unlock methods with what happened. A cancelled sheet still leaves the remote listed.
  private func finishSharing() {
    let who = created?.name ?? ""
    message =
      shared
      ? "Link shared. \(who) can unlock this phone once the link is opened on their phone."
      : "Link not shared. Share it again from \(who)’s row."
    dismiss()
  }
  private func field(_ label: String, _ text: Binding<String>, _ placeholder: String, hint: String? = nil)
    -> some View
  {
    VStack(alignment: .leading, spacing: 6) {
      Text(label).font(.footnote).foregroundStyle(QuietDesign.muted)
      TextField(placeholder, text: text).textInputAutocapitalization(.words).autocorrectionDisabled().padding(
        12
      )
      .background(QuietDesign.surface).clipShape(RoundedRectangle(cornerRadius: 12))
      .accessibilityLabel(label)
      .focused($focusedField, equals: label)
      .submitLabel(.done)
      .onSubmit { focusedField = nil }
      if let hint { Text(hint).font(.caption).foregroundStyle(QuietDesign.muted) }
    }
  }
}

struct RemoteDetailView: View {
  @EnvironmentObject private var model: QuietModel
  @Environment(\.dismiss) private var dismiss
  let remote: Remote
  @Binding var message: String
  @State private var confirming = false
  @State private var share: ShareItem? = nil
  private var current: Remote { model.remotes.remotes.first { $0.id == remote.id } ?? remote }
  var body: some View {
    List {
      Section {
        Text("Remote").foregroundStyle(QuietDesign.muted)
        LabeledContent(
          "Added", value: current.addedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        )
        LabeledContent("Last unlock", value: current.lastUnlockAt.map(RemoteCopy.when) ?? "Not yet")
      }.listRowBackground(QuietDesign.surface)
      Section {
        if confirming {
          Text("Remove \(remote.name)? Links from \(remote.name) will stop working.")
          Button("Remove", role: .destructive) {
            do {
              try model.removeRemote(remote)
              message = "\(remote.name) removed. Links from \(remote.name) no longer work."
              dismiss()
            } catch { model.error = error.localizedDescription }
          }
          Button("Cancel") { confirming = false }
        } else {
          Button("Share link again") {
            message = ""
            share = ShareItem(
              message: RemoteCopy.connectMessage(owner: model.remotes.ownerName),
              url: model.connectURL(for: remote))
          }
          Button("Remove") { confirming = true }
        }
      }.listRowBackground(QuietDesign.surface)
    }.scrollContentBackground(.hidden).background(QuietDesign.paper).navigationTitle(remote.name)
      .sheet(item: $share, onDismiss: finishSharing) { item in
        ActivitySheet(item: item) { completed in
          message =
            completed
            ? "Link shared again. The earlier link still works." : "Link not shared. You can try again."
          share = nil
        }.ignoresSafeArea()
      }
  }
  private func finishSharing() {
    if message.isEmpty { message = "Link not shared. You can try again." }
  }
}
