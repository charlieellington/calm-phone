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
