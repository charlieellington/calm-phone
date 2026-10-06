import CommonCrypto
import Foundation
import QuietCore
import Security

final class PINStore: CredentialStorage {
  private var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "design.ellington.quiet.guardian",
      kSecAttrAccount as String: "pin-v1",
      kSecAttrSynchronizable as String: false,
    ]
  }
  func read() throws -> Credential? {
    var q = query
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else { throw QuietError.repairRequired }
    do { return try JSONDecoder().decode(Credential.self, from: data) } catch {
      throw QuietError.repairRequired
    }
  }
  func write(_ credential: Credential, enrolling: Bool) throws {
    let data = try JSONEncoder().encode(credential)
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    let status: OSStatus
    if enrolling {
      let item = query.merging(attributes) { _, new in new }
      status = SecItemAdd(item as CFDictionary, nil)
    } else {
      status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    guard status == errSecSuccess else { throw QuietError.repairRequired }
  }
  static func salt() throws -> Data {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw QuietError.unavailable
    }
    return Data(bytes)
  }
  static func derive(_ pin: String, salt: Data, rounds: UInt32) throws -> Data {
    try PINVerifier.validate(pin)
    guard salt.count == 32, rounds >= 100_000 else { throw QuietError.repairRequired }
    let password = Array(pin.utf8)
    var key = [UInt8](repeating: 0, count: 32)
    let status = password.withUnsafeBytes { p in
      salt.withUnsafeBytes { s in
        key.withUnsafeMutableBytes { k in
          CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2), p.baseAddress!.assumingMemoryBound(to: CChar.self), p.count,
            s.baseAddress!.assumingMemoryBound(to: UInt8.self), s.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            rounds, k.baseAddress!.assumingMemoryBound(to: UInt8.self), k.count)
        }
      }
    }
    guard status == kCCSuccess else { throw QuietError.unavailable }
    return Data(key)
  }
}
