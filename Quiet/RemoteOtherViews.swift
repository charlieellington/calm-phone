// Remote unlock screens on the remote's phone: First launch, Connected and Unlock others.
// The same app serves both phones; these show when this phone has no restriction setup of its own.
import QuietCore
import SwiftUI

struct FirstLaunchView: View {
  @EnvironmentObject private var model: QuietModel
  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          Rectangle().fill(QuietDesign.ink).frame(width: 32, height: 3).padding(
            .top, geometry.size.height * 0.19)
          Text("Calm Phone").font(.system(size: 44, weight: .medium))
          Text("Restrict this phone, or unlock someone else’s.").font(.title3)
          Spacer(minLength: 48)
          Button("Restrict this phone") { model.choseRestrict = true }.buttonStyle(CalmPrimaryButtonStyle())
          Text("To unlock another phone, open the link its owner sent you.").font(.footnote)
            .foregroundStyle(QuietDesign.muted).frame(maxWidth: .infinity).padding(.bottom, 24)
        }.frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .leading).padding(
          .horizontal, 24)
      }
    }.navigationTitle("Calm Phone").navigationBarTitleDisplayMode(.inline)
  }
}

struct ConnectedView: View {
  @EnvironmentObject private var model: QuietModel
  let outcome: LinkOutcome
  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          Spacer(minLength: 24)
          Rectangle().fill(QuietDesign.ink).frame(width: 32, height: 3)
          Text(outcome.already ? "Already connected" : "Connected to\n\(outcome.owner)’s phone")
            .font(.largeTitle.weight(.semibold))
          Text(
            outcome.already
              ? "This phone can already unlock \(outcome.owner)’s phone."
              : "This phone can now unlock \(outcome.owner)’s phone."
          ).foregroundStyle(QuietDesign.muted)
          Spacer()
          Button("Continue") { model.linkOutcome = nil }.buttonStyle(CalmPrimaryButtonStyle()).padding(
            .bottom, 24)
        }.padding(.horizontal, 24).frame(
          maxWidth: .infinity, minHeight: geometry.size.height, alignment: .leading)
      }
    }
    .background(QuietDesign.paper.ignoresSafeArea()).foregroundStyle(QuietDesign.ink)
  }
}

struct UnlockOthersView: View {
  @EnvironmentObject private var model: QuietModel
  @State private var selectedID: String? = nil
  private var selected: Connection? { model.connections.connections.first { $0.id == selectedID } }
  @State private var share: ShareItem? = nil
  @State private var message = ""
  @State private var confirming = false
  var body: some View {
    Group {
      if model.connections.connections.count == 1, let only = model.connections.connections.first {
        durations(for: only)
      } else if let selected {
        durations(for: selected)
      } else {
        List(model.connections.connections) { connection in
          Button(connection.ownerName) {
            selectedID = connection.id
            message = ""
            confirming = false
          }.listRowBackground(QuietDesign.surface)
        }.scrollContentBackground(.hidden).background(QuietDesign.paper).navigationTitle("Unlock others")
      }
    }.navigationBarTitleDisplayMode(.inline)
      .onChange(of: model.connections) { _, _ in
        selectedID = nil
        message = ""
        confirming = false
        share = nil
      }
      .sheet(item: $share, onDismiss: finishSharing) { item in
        ActivitySheet(item: item) { completed in
          message =
            completed
            ? "Link shared. It works once, for 10 minutes."
            : "Link not shared. Choose a duration to try again."
          share = nil
        }.ignoresSafeArea()
      }
  }
  private func finishSharing() {
    if message.isEmpty { message = "Link not shared. Choose a duration to try again." }
  }
  private func durations(for connection: Connection) -> some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          Text("Unlock \(connection.ownerName)’s phone").font(.largeTitle.weight(.semibold))
          Text("Choose how long, then send the link.").foregroundStyle(QuietDesign.muted)
          ForEach(LeaseChoice.allCases, id: \.self) { choice in
            Button {
              do {
                message = ""
                confirming = false
                let label =
                  choice == .midnight ? "Unlock until midnight" : "Unlock for \(RemoteCopy.duration(choice))"
                share = ShareItem(message: label, url: try model.unlockURL(for: connection, choice: choice))
              } catch { model.error = error.localizedDescription }
            } label: {
              HStack {
                Text(RemoteCopy.duration(choice)).font(.title3)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(QuietDesign.muted).accessibilityHidden(
                  true)
              }.padding(20).frame(minHeight: 75).contentShape(Rectangle())
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(QuietDesign.separator))
            }.buttonStyle(.plain)
          }
          Text(
            "Each link works once, for 10 minutes. Until midnight ends at midnight on \(connection.ownerName)’s phone."
          ).font(.footnote).foregroundStyle(QuietDesign.muted)
          if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(QuietDesign.muted) }
          Spacer(minLength: 32)
          if confirming {
            Text(
              "Disconnect from \(connection.ownerName)’s phone? You won’t be able to unlock it until you open a new link from its owner."
            ).font(.footnote)
            Button("Disconnect") {
              do {
                try model.disconnect(connection)
                selectedID = nil
                message = ""
                confirming = false
              } catch { model.error = error.localizedDescription }
            }.buttonStyle(CalmPrimaryButtonStyle())
            Button("Cancel") { confirming = false }.frame(maxWidth: .infinity, minHeight: 44)
          } else {
            Button("Disconnect") { confirming = true }.frame(maxWidth: .infinity, minHeight: 44)
          }
        }.padding(24).frame(minHeight: geometry.size.height, alignment: .topLeading)
      }
    }.background(QuietDesign.paper)
      .toolbar {
        if model.connections.connections.count > 1 {
          ToolbarItem(placement: .topBarLeading) {
            Button("Back") {
              selectedID = nil
              message = ""
              confirming = false
            }
          }
        }
      }
  }
}

struct RemoteStorageUnavailableView: View {
  @EnvironmentObject private var model: QuietModel
  var body: some View {
    VStack(spacing: 24) {
      Text("Connections unavailable").font(.title)
      Text(model.connectionReadError ?? "Try reading your saved connections again.")
      Button("Try again") { model.loadRemote() }.buttonStyle(CalmPrimaryButtonStyle())
    }.padding(24)
  }
}
