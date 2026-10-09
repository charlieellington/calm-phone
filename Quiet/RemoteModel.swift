// Remote unlock behaviour for QuietModel: routing links, connecting, redeeming, and the Unlock methods /
// Unlock others actions. A redeemed link takes the same lease path as the PIN.
import Foundation
import QuietCore

/// The Connected screen on the remote's phone. Every other link outcome is the standard alert.
struct LinkOutcome: Equatable, Identifiable {
  let owner: String
  let already: Bool
  var id: String { "\(owner)-\(already)" }
}

/// A RemoteError with the remote's name in the words the alert shows.
struct RemoteMessage: LocalizedError {
  let error: RemoteError
  let name: String
  var errorDescription: String? {
    switch error {
    case .expired: return "Link expired. Unlock links work for 10 minutes. Ask \(name) for a new one."
    case .alreadyUsed: return "Link already used. Each link works once. Ask \(name) for a new one."
    case .unknownRemote:
      return
        "Link not recognised. No remote on this phone matches this link. Add them again from Unlock methods."
    case .badSignature, .notYetValid: return "Link not recognised. Ask \(name) for a new one."
    case .malformed, .invalidName, .oldConnectLink, .staleConnection, .capacity:
      return error.localizedDescription
    }
  }
}

extension QuietModel {
  func loadRemote() {
    do {
      remotes = try readRemotes()
      remoteReadError = nil
    } catch { remoteReadError = "Remotes could not be read. Try again." }
    do {
      connections = try readConnections()
      connectionReadError = nil
    } catch { connectionReadError = "Connections could not be read. Try again." }
  }

  func readRemotes() throws -> RemoteRecord {
    let original = try (remoteStore.read() ?? RemoteRecord()).validated()
    let migrated = try original.migrated()
    if original != migrated { try remoteStore.write(migrated) }
    return migrated
  }
  func readConnections() throws -> ConnectionRecord {
    try connectionStore.read().validated()
  }

  /// Entry for onOpenURL and the universal-link user activity.
  func open(_ url: URL) {
    // Old widget links only ever open status.
    if let route = HomeRoute.parse(url) {
      self.route(route)
      return
    }
    guard let link = RemoteLink.parse(url) else { return }
    switch link.kind {
    case .connect: connect(token: link.token)
    case .unlock: redeem(token: link.token)
    }
  }

  func connect(token text: String) {
    do {
      let token = try ConnectToken.decode(text)
      let issuing = try readRemotes()
      guard issuing.phoneID != token.phoneID, !issuing.remotes.contains(where: { $0.id == token.remoteID })
      else {
        error =
          "This link is for the other phone. Send it to the person you added. They open it on their phone."
        return
      }
      var record = try readConnections()
      let changed = try record.connect(token, now: clock())
      try connectionStore.write(record)
      connections = record
      connectionReadError = nil
      remoteReadError = nil
      linkOutcome = LinkOutcome(owner: token.ownerName, already: !changed)
    } catch { self.error = error.localizedDescription }
  }

  func redeem(token text: String) {
    guard let token = try? UnlockToken.decode(text) else {
      error = RemoteError.malformed.localizedDescription
      return
    }
    if let other = connections.connections.first(where: { $0.id == token.remoteID }),
      !remotes.remotes.contains(where: { $0.id == token.remoteID })
    {
      error = "This link unlocks \(other.ownerName)’s phone. Open it there, not on this phone."
      return
    }
    refresh()
    let name = remotes.remotes.first { $0.id == token.remoteID }?.name ?? "them"
    // Refusals before verification leave the link unspent; only a locked, healthy phone redeems it.
    switch presentation {
    case .locked: break
    case .checking:
      pendingLink = text
      return
    case .active(let end):
      error =
        "Already unlocked. Access is active until \(CalmTime.deadline(end)). Lock now first to start a new unlock."
      return
    default:
      error = "Couldn’t unlock. Check restrictions first."
      return
    }
    perform(
      failureMessage:
        "Couldn’t unlock. Ask \(name) for a new link. If it keeps failing, check restrictions in Calm Phone."
    ) {
      let verified: (authorization: GuardianAuthorization, remote: Remote)
      do { verified = try verifier.verify(token) } catch let e as RemoteError {
        throw RemoteMessage(error: e, name: name)
      }
      let draft = try GrantDraft.prepare(token.choice, now: clock())
      try openLease(
        draft, authorization: verified.authorization, remoteName: verified.remote.name,
        remoteID: verified.remote.id)
      // Rebuild the root stack to dismiss all pushed destinations and their local presentations.
      cancelGuardian()
      linkOutcome = nil
      page = .status
      error = nil
      navigationEpoch = UUID()
    }
  }

  /// The journal records activation in the grant transaction. Replaying this metadata never grants.
  /// Keep the successful timestamp visible even if the secondary Keychain update needs a retry.
  func reconcileRemoteSuccess() {
    guard state.leases.contains(where: { $0.remoteID != nil && $0.activatedAt != nil }) else {
      remoteMetadataError = nil
      return
    }
    do {
      var record = try readRemotes()
      let original = record
      for lease in state.leases {
        guard let id = lease.remoteID, let activated = lease.activatedAt,
          let i = record.remotes.firstIndex(where: { $0.id == id })
        else { continue }
        record.remotes[i].lastUnlockAt = max(record.remotes[i].lastUnlockAt ?? activated, activated)
      }
      remotes = record
      if record != original { try remoteStore.write(record) }
      remoteMetadataError = nil
    } catch {
      remoteMetadataError =
        "Unlock history is saved. The remote’s last unlock will be saved again when storage is available."
    }
  }

  /// A link that arrived while Screen Time status was unresolved, retried once the check finishes.
  func redeemPendingLink() {
    guard let link = pendingLink else { return }
    pendingLink = nil
    redeem(token: link)
  }

  // Unlock methods (no PIN)
  func addRemote(name: String, ownerName: String) throws -> Remote {
    var record = try readRemotes()
    let remote = try record.add(name: name, ownerName: ownerName, now: clock())
    try remoteStore.write(record)
    remotes = record
    return remote
  }
  func connectURL(for remote: Remote) -> URL {
    RemoteLink.url(.connect, token: remotes.connectToken(for: remote).encode())
  }
  func removeRemote(_ remote: Remote) throws {
    var record = try readRemotes()
    record.remove(id: remote.id)
    try remoteStore.write(record)
    remotes = record
  }

  // Unlock others
  func unlockURL(for connection: Connection, choice: LeaseChoice) throws -> URL {
    RemoteLink.url(
      .unlock, token: try readConnections().issue(for: connection.id, choice: choice, now: clock()).encode())
  }
  func disconnect(_ connection: Connection) throws {
    var record = try readConnections()
    record.disconnect(id: connection.id)
    try connectionStore.write(record)
    connections = record
  }
}
