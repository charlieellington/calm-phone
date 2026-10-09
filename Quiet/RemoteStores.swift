// Keychain-backed JSON records for remote unlock: who may unlock this phone, and which phones this one may unlock.
// Both stay on this device only and are never synced. Extensions never read them, so no access group is needed.
import Foundation
import QuietCore
import Security

struct KeychainFailure: Error, LocalizedError, Equatable {
  let operation: String
  let status: OSStatus
  var errorDescription: String? {
    "Saved connections could not be accessed (\(operation), \(status)). Try again."
  }
}

/// Injectable Security boundary; tests exercise exact statuses without touching production accounts.
struct KeychainAccess {
  var read: ([String: Any]) -> (OSStatus, Data?) = { query in
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    return (status, result as? Data)
  }
  var update: ([String: Any], [String: Any]) -> OSStatus = {
    SecItemUpdate($0 as CFDictionary, $1 as CFDictionary)
  }
  var add: ([String: Any]) -> OSStatus = { SecItemAdd($0 as CFDictionary, nil) }
  var delete: ([String: Any]) -> OSStatus = { SecItemDelete($0 as CFDictionary) }
}

final class KeychainJSON<Value: Codable> {
  private let account: String
  private let service: String
  private let access: KeychainAccess
  init(
    account: String, service: String = "design.ellington.quiet.remote",
    access: KeychainAccess = KeychainAccess()
  ) {
    self.account = account
    self.service = service
    self.access = access
  }
  private var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false,
    ]
  }
  func read() throws -> Value? {
    var q = query
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    let (status, data) = access.read(q)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw KeychainFailure(operation: "read", status: status) }
    guard let data else { throw KeychainFailure(operation: "read-data", status: errSecDecode) }
    return try JSONDecoder().decode(Value.self, from: data)
  }
  func write(_ value: Value) throws {
    let attributes: [String: Any] = [
      kSecValueData as String: try JSONEncoder().encode(value),
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    var status = access.update(query, attributes)
    if status == errSecItemNotFound {
      status = access.add(query.merging(attributes) { _, new in new })
    }
    guard status == errSecSuccess else { throw KeychainFailure(operation: "write", status: status) }
  }
  func delete() throws {
    let status = access.delete(query)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainFailure(operation: "delete", status: status)
    }
  }
}

protocol ConnectionStoring {
  func read() throws -> ConnectionRecord
  func write(_ record: ConnectionRecord) throws
}

final class RemoteStore: RemoteStorage {
  private let item = KeychainJSON<RemoteRecord>(account: "remotes-v1")
  func read() throws -> RemoteRecord? { try item.read()?.validated() }
  func write(_ record: RemoteRecord) throws { try item.write(record.validated()) }
}

final class ConnectionStore: ConnectionStoring {
  private let item = KeychainJSON<ConnectionRecord>(account: "connections-v1")
  func read() throws -> ConnectionRecord { try (item.read() ?? ConnectionRecord()).validated() }
  func write(_ record: ConnectionRecord) throws { try item.write(record.validated()) }
}
