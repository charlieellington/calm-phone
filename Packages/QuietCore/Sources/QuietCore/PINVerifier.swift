import Foundation

public struct Credential: Codable {
  public var version = 1
  public var salt: Data
  public var derivedKey: Data
  public var rounds: UInt32 = 600_000
  public var failedAttempts = 0
  public var lockedUntil: Date?
  public var lastObservedAt: Date
  public init(salt: Data, derivedKey: Data, now: Date) {
    self.salt = salt
    self.derivedKey = derivedKey
    lastObservedAt = now
  }
}
public protocol CredentialStorage {
  func read() throws -> Credential?
  func write(_ credential: Credential, enrolling: Bool) throws
}

public final class PINVerifier {
  private let store: CredentialStorage
  private let derive: (String, Data, UInt32) throws -> Data
  private let salt: () throws -> Data
  private let clock: () -> Date
  private let lock = NSLock()
  public init(
    store: CredentialStorage, clock: @escaping () -> Date,
    salt: @escaping () throws -> Data, derive: @escaping (String, Data, UInt32) throws -> Data
  ) {
    self.store = store
    self.clock = clock
    self.salt = salt
    self.derive = derive
  }
  public static func validate(_ pin: String) throws {
    guard pin.utf8.count == 6, pin.utf8.allSatisfy({ (48...57).contains($0) }) else {
      throw QuietError.wrongPIN
    }
  }
  public static func equal(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    var difference: UInt8 = 0
    for (left, right) in zip(a, b) { difference |= left ^ right }
    return difference == 0
  }
  private func checked() throws -> Credential {
    guard let c = try store.read(), c.version == 1, c.salt.count == 32, c.derivedKey.count == 32,
      c.rounds >= 100_000, c.rounds <= 2_000_000, (0...5).contains(c.failedAttempts),
      c.failedAttempts < 5 || c.lockedUntil != nil
    else { throw QuietError.repairRequired }
    return c
  }
  public func hasCredential() throws -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard try store.read() != nil else { return false }
    _ = try checked()
    return true
  }
  public func lockoutEndpoint() throws -> Date? {
    lock.lock()
    defer { lock.unlock() }
    let credential = try checked()
    guard let end = credential.lockedUntil, max(clock(), credential.lastObservedAt) < end else { return nil }
    return end
  }
  public func enroll(_ pin: String, confirmation: String, setupComplete: Bool) throws -> GuardianAuthorization
  {
    lock.lock()
    defer { lock.unlock() }
    guard !setupComplete, try store.read() == nil else { throw QuietError.repairRequired }
    try Self.validate(pin)
    guard pin == confirmation else { throw QuietError.wrongPIN }
    let random = try salt()
    let c = Credential(salt: random, derivedKey: try derive(pin, random, 600_000), now: clock())
    try store.write(c, enrolling: true)
    return GuardianAuthorization(operation: .policy, now: clock())
  }
  public func verify(_ pin: String, operation: GuardianOperation) throws -> GuardianAuthorization {
    lock.lock()
    defer { lock.unlock() }
    var c = try checked()
    let now = max(clock(), c.lastObservedAt)
    if let until = c.lockedUntil {
      guard now >= until else { throw QuietError.lockedOut }
      c.failedAttempts = 0
      c.lockedUntil = nil
    }
    let validSyntax = (try? Self.validate(pin)) != nil
    let matches = try validSyntax && Self.equal(derive(pin, c.salt, c.rounds), c.derivedKey)
    c.lastObservedAt = now
    if matches {
      c.failedAttempts = 0
      c.lockedUntil = nil
    } else {
      c.failedAttempts += 1
      if c.failedAttempts >= 5 { c.lockedUntil = now.addingTimeInterval(900) }
    }
    try store.write(c, enrolling: false)
    guard matches else { throw c.lockedUntil == nil ? QuietError.wrongPIN : QuietError.lockedOut }
    return GuardianAuthorization(operation: operation, now: clock())
  }
  public func replace(_ pin: String, confirmation: String, authorization: GuardianAuthorization) throws {
    lock.lock()
    defer { lock.unlock() }
    try Self.validate(pin)
    guard pin == confirmation else { throw QuietError.wrongPIN }
    try authorization.consume(.replacePIN, now: clock())
    _ = try checked()
    let random = try salt()
    try store.write(
      Credential(salt: random, derivedKey: try derive(pin, random, 600_000), now: clock()), enrolling: false)
  }
}
