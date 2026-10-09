// Remote unlock. A "remote" is a person whose own phone can unlock this one by sending a link.
// Connecting shares a random key inside a link. Unlock links are signed with that key, work once and
// expire after ten minutes. A valid link becomes the same single-use lease authorisation the PIN creates,
// so the existing grant path, one-active-grant rule and Lock now are reused unchanged.
import CryptoKit
import Foundation

public enum RemoteError: Error, LocalizedError, Equatable {
  case malformed, invalidName, unknownRemote, badSignature, expired, notYetValid, alreadyUsed
  case oldConnectLink, staleConnection, capacity
  public var errorDescription: String? {
    switch self {
    case .malformed: return "This isn’t a Calm Phone link."
    case .invalidName: return "Enter a name of up to 40 characters."
    case .unknownRemote:
      return "No remote on this phone matches this link. Add them again from Unlock methods."
    case .badSignature: return "This link can’t be checked. Ask for a new one."
    case .expired: return "Unlock links work for 10 minutes. Ask for a new one."
    case .notYetValid: return "This link was made on a phone whose clock is ahead. Ask for a new one."
    case .alreadyUsed: return "Each link works once. Ask for a new one."
    case .oldConnectLink:
      return "This connection link is from an older version. Ask the owner for a new link."
    case .staleConnection:
      return "A newer connection for this phone is already saved. Ask the owner for their latest link."
    case .capacity: return "Saved remote data is full. Try again later or use the PIN."
    }
  }
}

enum Base64URL {
  static let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
  static func encode(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
  static func decode(_ text: String) -> Data? {
    guard text.allSatisfy(alphabet.contains) else { return nil }
    var padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while padded.count % 4 != 0 { padded += "=" }
    return Data(base64Encoded: padded)
  }
}

public enum RemoteName {
  public static func validate(_ name: String) throws -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...40).contains(trimmed.count), trimmed.utf8.count <= 2048,
      trimmed.unicodeScalars.allSatisfy({
        !CharacterSet.controlCharacters.contains($0) || $0.value == 0x200D || $0.value == 0x200C
      })
    else { throw RemoteError.invalidName }
    return trimmed
  }
}

public enum RemoteRandom {
  public static func bytes(_ count: Int) -> Data {
    Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
  }
}

// MARK: - Records

/// One person who may unlock this phone. The secret never appears in an unlock link.
public struct Remote: Codable, Equatable, Identifiable {
  public var id: String
  public var name: String
  public var secret: Data
  public var addedAt: Date
  public var generation: UInt64?
  public var lastUnlockAt: Date?
  public init(id: String, name: String, secret: Data, addedAt: Date, lastUnlockAt: Date? = nil) {
    self.id = id
    self.name = name
    self.secret = secret
    self.addedAt = addedAt
    self.lastUnlockAt = lastUnlockAt
  }
}

public struct UsedNonce: Codable, Equatable {
  public var remote: String
  public var nonce: String
  public var issuedAt: Date
  public init(remote: String, nonce: String, issuedAt: Date) {
    self.remote = remote
    self.nonce = nonce
    self.issuedAt = issuedAt
  }
}

/// Everything the restricted phone keeps about its remotes. One Keychain item, this device only.
public struct RemoteRecord: Codable, Equatable {
  public var version = 2
  public var phoneID: String? = Base64URL.encode(RemoteRandom.bytes(16))
  public var generation: UInt64? = 0
  public var ownerName = ""
  /// Never moves backwards, even if the wall clock is corrected.
  public var freshnessFloor: Date?
  public var remotes: [Remote] = []
  public var usedNonces: [UsedNonce] = []
  public init() {}

  @discardableResult
  public mutating func add(
    name: String, ownerName: String, now: Date, random: (Int) -> Data = RemoteRandom.bytes
  ) throws -> Remote {
    self = try migrated()
    guard let current = generation, current < UInt64.max else { throw QuietError.repairRequired }
    var remote = Remote(
      id: Base64URL.encode(random(16)), name: try RemoteName.validate(name), secret: random(32), addedAt: now)
    self.ownerName = try RemoteName.validate(ownerName)
    generation = current + 1
    remote.generation = generation
    remotes.append(remote)
    return remote
  }
  public mutating func remove(id: String) {
    remotes.removeAll { $0.id == id }
    usedNonces.removeAll { $0.remote == id }
  }
  public func connectToken(for remote: Remote) -> ConnectToken {
    ConnectToken(
      phoneID: phoneID ?? "", generation: remote.generation ?? 0, remoteID: remote.id, secret: remote.secret,
      ownerName: ownerName)
  }
}

/// One phone this device may unlock. Stored on the remote's phone, this device only.
public struct Connection: Codable, Equatable, Identifiable {
  public var phoneID: String?
  public var generation: UInt64?
  public var id: String
  public var ownerName: String
  public var secret: Data
  public var connectedAt: Date
  public init(id: String, ownerName: String, secret: Data, connectedAt: Date) {
    self.id = id
    self.ownerName = ownerName
    self.secret = secret
    self.connectedAt = connectedAt
  }
}

public struct ConnectionRecord: Codable, Equatable {
  public var version = 2
  // Keep only the newest credential per known phone, including after disconnect. No secret is retained.
  public var newest: [String: ConnectionRevision]? = [:]
  public var connections: [Connection] = []
  public init() {}

  /// Stores or replaces the connection. Returns false when this exact link was already connected.
  @discardableResult
  public mutating func connect(_ token: ConnectToken, now: Date) throws -> Bool {
    _ = try validated()
    _ = try ConnectToken.decode(token.encode())
    var revisions = newest ?? [:]
    if let seen = revisions[token.phoneID] {
      guard token.generation >= seen.generation,
        token.generation != seen.generation || token.remoteID == seen.remoteID
      else { throw RemoteError.staleConnection }
    } else if revisions.count >= 256 {
      throw RemoteError.capacity
    }
    if let old = connections.first(where: { $0.phoneID == token.phoneID }), old.generation == token.generation
    {
      guard old.id == token.remoteID, old.secret == token.secret else { throw RemoteError.staleConnection }
      if old.ownerName == token.ownerName { return false }
    }
    var fresh = Connection(
      id: token.remoteID, ownerName: token.ownerName, secret: token.secret, connectedAt: now)
    fresh.phoneID = token.phoneID
    fresh.generation = token.generation
    connections.removeAll { $0.phoneID == token.phoneID }
    connections.append(fresh)
    revisions[token.phoneID] = ConnectionRevision(generation: token.generation, remoteID: token.remoteID)
    newest = revisions
    version = 2
    return true
  }
  public mutating func disconnect(id: String) { connections.removeAll { $0.id == id } }
  public func issue(
    for id: String, choice: LeaseChoice, now: Date, random: (Int) -> Data = RemoteRandom.bytes
  ) throws -> UnlockToken {
    guard let connection = connections.first(where: { $0.id == id }) else { throw RemoteError.unknownRemote }
    return UnlockToken.issue(
      remoteID: id, secret: connection.secret, choice: choice, now: now, nonce: random(8))
  }
}

// MARK: - Tokens

public struct ConnectionRevision: Codable, Equatable {
  public var generation: UInt64
  public var remoteID: String
}

/// c2 carries stable issuing-phone identity and a monotonic credential generation, then the bearer key.
/// c1 has no phone identity and is explicitly rejected. Stored legacy connections remain removable.
public struct ConnectToken: Equatable {
  public static let prefix = "c2"
  public let phoneID: String
  public let generation: UInt64
  public let remoteID: String
  public let secret: Data
  public let ownerName: String
  public init(phoneID: String, generation: UInt64, remoteID: String, secret: Data, ownerName: String) {
    self.phoneID = phoneID
    self.generation = generation
    self.remoteID = remoteID
    self.secret = secret
    self.ownerName = ownerName
  }
  public func encode() -> String {
    [
      Self.prefix, phoneID, String(generation), remoteID, Base64URL.encode(secret),
      Base64URL.encode(Data(ownerName.utf8)),
    ]
    .joined(separator: ".")
  }
  public static func decode(_ text: String) throws -> ConnectToken {
    guard text.utf8.count <= 8192 else { throw RemoteError.malformed }
    if text.hasPrefix("c1.") { throw RemoteError.oldConnectLink }
    let parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 6, parts[0] == prefix, UnlockToken.validID(parts[1]),
      let generation = UInt64(parts[2]), generation > 0, String(generation) == parts[2],
      UnlockToken.validID(parts[3]),
      let secret = Base64URL.decode(parts[4]), secret.count == 32,
      let nameData = Base64URL.decode(parts[5]), let name = String(data: nameData, encoding: .utf8),
      (try? RemoteName.validate(name)) == name
    else { throw RemoteError.malformed }
    return ConnectToken(
      phoneID: parts[1], generation: generation, remoteID: parts[3], secret: secret, ownerName: name)
  }
}

/// `u1.<remote id>.<15|60|m>.<issued at, unix seconds>.<nonce>.<mac>`.
/// The mac is HMAC-SHA256 over the first five parts, truncated to 16 bytes.
public struct UnlockToken: Equatable {
  public static let prefix = "u1"
  public let remoteID: String
  public let choice: LeaseChoice
  public let issuedAt: Date
  public let nonce: String
  public let mac: Data

  static func validID(_ id: String) -> Bool { id.count == 22 && id.allSatisfy(Base64URL.alphabet.contains) }
  static func code(_ choice: LeaseChoice) -> String {
    switch choice {
    case .quarterHour: return "15"
    case .hour: return "60"
    case .midnight: return "m"
    }
  }
  static func choice(_ code: String) -> LeaseChoice? {
    switch code {
    case "15": return .quarterHour
    case "60": return .hour
    case "m": return .midnight
    default: return nil
    }
  }
  static func payload(_ remoteID: String, _ choice: LeaseChoice, _ issuedAt: Date, _ nonce: String) -> String
  {
    [prefix, remoteID, code(choice), String(Int(issuedAt.timeIntervalSince1970)), nonce].joined(
      separator: ".")
  }
  static func mac(_ payload: String, secret: Data) -> Data {
    Data(
      HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: SymmetricKey(data: secret)).prefix(16))
  }
  var payload: String { Self.payload(remoteID, choice, issuedAt, nonce) }

  public static func issue(
    remoteID: String, secret: Data, choice: LeaseChoice, now: Date, nonce: Data
  ) -> UnlockToken {
    let issuedAt = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
    let nonceText = Base64URL.encode(nonce)
    let payload = payload(remoteID, choice, issuedAt, nonceText)
    return UnlockToken(
      remoteID: remoteID, choice: choice, issuedAt: issuedAt, nonce: nonceText,
      mac: mac(payload, secret: secret))
  }
  public func encode() -> String { payload + "." + Base64URL.encode(mac) }
  public static func decode(_ text: String) throws -> UnlockToken {
    guard text.utf8.count <= 256 else { throw RemoteError.malformed }
    let parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 6, parts[0] == prefix, validID(parts[1]), let choice = choice(parts[2]),
      parts[3].count <= 12, let seconds = Int(parts[3]), seconds > 0,
      parts[4].count == 11, parts[4].allSatisfy(Base64URL.alphabet.contains),
      let mac = Base64URL.decode(parts[5]), mac.count == 16
    else { throw RemoteError.malformed }
    return UnlockToken(
      remoteID: parts[1], choice: choice, issuedAt: Date(timeIntervalSince1970: TimeInterval(seconds)),
      nonce: parts[4], mac: mac)
  }
  func verifies(with secret: Data) -> Bool { PINVerifier.equal(Self.mac(payload, secret: secret), mac) }
}

// MARK: - Links

/// https on www.ellington.design with the token in the fragment, so it never reaches the server.
/// The apex domain redirects to www, and Apple never follows a redirect for universal links.
/// The custom scheme is the fallback button on the plain web page. Old `quiet://open/...` routes are not remote links.
public enum RemoteLink {
  public static let host = "www.ellington.design"
  public static let scheme = "quiet"
  public enum Kind: String, Equatable { case connect, unlock }
  public static func path(_ kind: Kind) -> String { kind == .connect ? "/calm/c" : "/calm/u" }
  public static func url(_ kind: Kind, token: String) -> URL {
    URL(string: "https://\(host)\(path(kind))#\(token)")!
  }
  public static func parse(_ url: URL) -> (kind: Kind, token: String)? {
    guard url.absoluteString.utf8.count <= 12000,
      let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.user == nil, c.password == nil,
      c.port == nil
    else { return nil }
    if c.scheme == "https", c.host == host, c.query == nil, let token = c.fragment, !token.isEmpty {
      return [Kind.connect, .unlock].first { path($0) == c.path }.map { ($0, token) }
    }
    if c.scheme == scheme, c.fragment == nil, let kind = c.host.flatMap(Kind.init(rawValue:)),
      c.path.isEmpty || c.path == "/", let items = c.queryItems, items.count == 1, items[0].name == "t",
      let token = items[0].value, !token.isEmpty
    {
      return (kind, token)
    }
    return nil
  }
}

// MARK: - Verifier

public protocol RemoteStorage {
  func read() throws -> RemoteRecord?
  func write(_ record: RemoteRecord) throws
}

/// Turns a valid, fresh, unused unlock link from a known remote into the single-use lease authorisation the
/// coordinator already requires. The nonce is written before the capability is returned, so a crash mid-grant
/// can never let the same link work twice.
public final class RemoteVerifier {
  public static let validity: TimeInterval = 600
  public static let skew: TimeInterval = 120
  private let store: RemoteStorage
  private let clock: () -> Date
  private let lock = NSLock()
  public init(store: RemoteStorage, clock: @escaping () -> Date) {
    self.store = store
    self.clock = clock
  }
  public func verify(_ token: UnlockToken) throws -> (authorization: GuardianAuthorization, remote: Remote) {
    lock.lock()
    defer { lock.unlock() }
    let now = clock()
    var record = try (store.read() ?? RemoteRecord()).validated()
    guard let index = record.remotes.firstIndex(where: { $0.id == token.remoteID }) else {
      throw RemoteError.unknownRemote
    }
    guard token.verifies(with: record.remotes[index].secret) else { throw RemoteError.badSignature }
    let reference = max(now, record.freshnessFloor ?? now)
    record.freshnessFloor = reference
    record.usedNonces.removeAll { reference.timeIntervalSince($0.issuedAt) > Self.validity + Self.skew }
    // Persist authenticated observations even on expiry. A forward jump followed by correction
    // cannot revive a token that was already observed expired. No invalid token spends a nonce.
    if reference.timeIntervalSince(token.issuedAt) > Self.validity {
      try store.write(record)
      throw RemoteError.expired
    }
    if now.timeIntervalSince(token.issuedAt) < -Self.skew {
      try store.write(record)
      throw RemoteError.notYetValid
    }
    guard !record.usedNonces.contains(where: { $0.remote == token.remoteID && $0.nonce == token.nonce })
    else {
      throw RemoteError.alreadyUsed
    }
    guard record.usedNonces.count < 4096 else { throw RemoteError.capacity }
    record.usedNonces.append(UsedNonce(remote: token.remoteID, nonce: token.nonce, issuedAt: token.issuedAt))
    try store.write(record)
    return (GuardianAuthorization(operation: .lease, now: now), record.remotes[index])
  }
}

/// Validate before any saved credentials are used or rewritten. Unknown schemas never mean empty.
extension RemoteRecord {
  public func validated() throws -> Self {
    guard version == 1 || version == 2,
      remotes.isEmpty || (try? RemoteName.validate(ownerName)) == ownerName,
      Set(remotes.map(\.id)).count == remotes.count,
      remotes.allSatisfy({
        UnlockToken.validID($0.id) && $0.secret.count == 32
          && (try? RemoteName.validate($0.name)) == $0.name
      }),
      usedNonces.allSatisfy({ item in
        remotes.contains { $0.id == item.remote }
          && item.nonce.count == 11 && Base64URL.decode(item.nonce)?.count == 8
      }),
      Set(usedNonces.map { $0.remote + "." + $0.nonce }).count == usedNonces.count
    else { throw QuietError.repairRequired }
    if version == 2 {
      guard let phoneID, UnlockToken.validID(phoneID), let generation,
        remotes.allSatisfy({ ($0.generation ?? 0) > 0 && ($0.generation ?? 0) <= generation }),
        Set(remotes.compactMap(\.generation)).count == remotes.count
      else { throw QuietError.repairRequired }
    }
    return self
  }
  public func migrated() throws -> Self {
    _ = try validated()
    guard version == 1 else { return self }
    var result = self
    result.version = 2
    result.phoneID = Base64URL.encode(RemoteRandom.bytes(16))
    result.generation = UInt64(remotes.count)
    for i in result.remotes.indices { result.remotes[i].generation = UInt64(i + 1) }
    return result
  }
}
extension ConnectionRecord {
  public func validated() throws -> Self {
    guard version == 1 || version == 2, Set(connections.map(\.id)).count == connections.count,
      connections.allSatisfy({
        UnlockToken.validID($0.id) && $0.secret.count == 32
          && (try? RemoteName.validate($0.ownerName)) == $0.ownerName
      })
    else { throw QuietError.repairRequired }
    if version == 2 {
      guard let newest, newest.count <= 256,
        newest.allSatisfy({
          UnlockToken.validID($0.key) && $0.value.generation > 0 && UnlockToken.validID($0.value.remoteID)
        }),
        Set(connections.compactMap(\.phoneID)).count == connections.compactMap(\.phoneID).count,
        connections.allSatisfy({ c in
          if let phone = c.phoneID {
            return newest[phone]?.generation == c.generation && newest[phone]?.remoteID == c.id
          }
          return c.generation == nil  // Legacy rows are kept, never guessed from a display name.
        })
      else { throw QuietError.repairRequired }
    }
    return self
  }
}
