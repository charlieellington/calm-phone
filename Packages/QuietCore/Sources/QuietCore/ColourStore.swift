import Darwin
import Foundation

/// Separate storage keeps installed control.sqlite, PIN and SwiftData history unchanged.
public final class ColourStore {
  private let directory: URL
  private let file: URL
  private let lockFD: Int32
  private let localLock = NSLock()
  public init(directory: URL) throws {
    self.directory = directory
    file = directory.appendingPathComponent("colour-v1.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    lockFD = open(directory.appendingPathComponent("colour-writer.lock").path, O_CREAT | O_RDWR, 0o600)
    guard lockFD >= 0 else { throw QuietError.unavailable }
    #if os(iOS)
      do {
        try FileManager.default.setAttributes(
          [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
          ofItemAtPath: directory.appendingPathComponent("colour-writer.lock").path)
      } catch {
        close(lockFD)
        throw error
      }
    #endif
  }
  deinit { close(lockFD) }
  private func withLock<T>(_ body: () throws -> T) throws -> T {
    localLock.lock()
    defer { localLock.unlock() }
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    while flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
      guard errno == EWOULDBLOCK, ProcessInfo.processInfo.systemUptime < deadline else {
        throw QuietError.busy
      }
      usleep(10_000)
    }
    defer { flock(lockFD, LOCK_UN) }
    return try body()
  }
  private func read() throws -> ColourState {
    guard FileManager.default.fileExists(atPath: file.path) else { return ColourState() }
    do {
      let state = try JSONDecoder().decode(ColourState.self, from: Data(contentsOf: file))
      guard state.version == 1, state.revision >= 0,
        state.interval.map({ $0.expiresAt.timeIntervalSince($0.startedAt) == 900 }) ?? true
      else { throw QuietError.repairRequired }
      return state
    } catch { throw QuietError.repairRequired }
  }
  public func load() throws -> ColourState { try withLock { try read() } }
  @discardableResult public func update<T>(_ change: (inout ColourState) throws -> T) throws -> T {
    try withLock {
      var state = try read()
      let result = try change(&state)
      state.revision += 1
      try JSONEncoder().encode(state).write(to: file, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      #if os(iOS)
        try FileManager.default.setAttributes(
          [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
      #endif
      let fd = open(file.path, O_RDONLY)
      guard fd >= 0 else { throw QuietError.unavailable }
      defer { close(fd) }
      guard fsync(fd) == 0 else { throw QuietError.unavailable }
      let parent = open(directory.path, O_RDONLY)
      guard parent >= 0 else { throw QuietError.unavailable }
      defer { close(parent) }
      guard fsync(parent) == 0 else { throw QuietError.unavailable }
      return result
    }
  }
  /// Repeat taps retain the original endpoint rather than silently granting another 15 minutes.
  public func start(now: Date) throws -> ColourInterval {
    try update { state in
      if let interval = state.interval, interval.isActive(at: now) { return interval }
      let interval = ColourInterval(now: now)
      state.interval = interval
      state.lastApplication = nil
      return interval
    }
  }
  public func end() throws { try update { $0.interval = nil } }
}
