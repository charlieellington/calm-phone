import Foundation
import QuietCore

enum SharedContainer {
  static let group = "group.design.ellington.quiet"
  static func directory() throws -> URL {
    guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
      throw QuietError.repairRequired
    }
    let directory = root.appendingPathComponent("Library/Application Support", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    return directory
  }
  static func database() throws -> ControlDatabase {
    let directory = try directory()
    let database = try ControlDatabase(directory: directory)
    for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: url.path)
    }
    return database
  }
  static func snapshot() -> WidgetSnapshot? {
    guard let directory = try? directory() else { return nil }
    return try? ControlDatabase.readSnapshot(directory: directory)
  }
}
