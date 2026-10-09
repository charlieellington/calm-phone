// Appended to the unchanged build-6 UnlockInterval entity, compiled in module Quiet.
@main struct Build6Fixture {
  @MainActor static func main() throws {
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let policy = Policy(allowed: (0..<44).map { AppEntry(id: "allowed-\($0)", label: "Allowed \($0)", token: "synthetic-\($0)") },
      limits: Policy.quotas.sorted { $0.key < $1.key }.map { LimitRule(app: AppEntry(id: $0.key, label: $0.key, token: $0.key), minutes: $0.value) })
    var ended = Lease(now: now - 3600, expiresAt: now)
    ended.state = .ended; ended.activatedAt = now - 3600; ended.endedAt = now - 2700; ended.relockedAt = now - 2700
    var active = Lease(now: now - 100, expiresAt: now + 900)
    active.state = .active; active.activatedAt = now - 100
    var old = Lease(now: now - 40 * 86400, expiresAt: now - 40 * 86400 + 900)
    old.state = .ended; old.activatedAt = old.requestedAt; old.endedAt = old.expiresAt
    for pending in [false, true] {
      let directory = root.appendingPathComponent(pending ? "pending" : "control")
      let database = try ControlDatabase(directory: directory)
      try database.update { state in
        state.setupComplete = true; state.policy = policy; state.authorizationApproved = true
        state.dailyRegistered = true; state.exhaustedDay = CivilTime.day(now)
        state.exhausted = [policy.limits[0].id]; state.leases = [ended, active]
        if pending { state.pendingPolicy = policy; state.pendingExhausted = state.exhausted }
      }
      try JSONEncoder().encode(database.load()).write(to: directory.appendingPathComponent("expected.json"))
    }
    let credential = Credential(salt: Data(repeating: 7, count: 32), derivedKey: Data(repeating: 1, count: 32), now: now)
    try JSONEncoder().encode(credential).write(to: root.appendingPathComponent("credential.json"))
    let schema = Schema([UnlockInterval.self])
    let configuration = ModelConfiguration("QuietHistory", schema: schema, url: root.appendingPathComponent("history.store"), cloudKitDatabase: .none)
    let container = try ModelContainer(for: schema, configurations: configuration)
    for lease in [ended, active, old] { container.mainContext.insert(UnlockInterval(lease: lease)) }
    try container.mainContext.save()
    try JSONEncoder().encode([ended, active, old]).write(to: root.appendingPathComponent("history-expected.json"))
  }
}
