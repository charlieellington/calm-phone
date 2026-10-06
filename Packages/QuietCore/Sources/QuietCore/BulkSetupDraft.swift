import Foundation

public enum SetupSelectionError: Error, LocalizedError, Equatable {
  case tooManyApps(Int)
  case missingLimit(String)
  case duplicateAssignment(String, String)
  case invalidSelection

  public var errorDescription: String? {
    switch self {
    case .tooManyApps(let count):
      return "50 apps selected. Remove an app before adding another. (\(count) selected.)"
    case .missingLimit(let id):
      return "Choose the app for the \(id.replacingOccurrences(of: "-", with: " ")) daily limit."
    case .duplicateAssignment(let first, let second):
      return "\(first) and \(second) use the same app. Choose a different app for each."
    case .invalidSelection:
      return "An app selection is unavailable. Select your useful apps again."
    }
  }
}

/// The picker selects one pool. Named links and limits refer to entries in that pool.
/// Building a policy splits it into disjoint Allow and Limit sets; enforcement is unchanged.
public struct BulkSetupDraft {
  public static let unnamedLabel = "allowed app"
  public static let linkIDs = AppCatalog.home + AppCatalog.more + ["messages"]
  public var applications: [AppEntry] = []
  public var assignments: [String: String] = [:]
  public var minutes = Policy.quotas

  private static var namedIDs: Set<String> {
    Set(AppCatalog.allow.map(\.0)).union(Policy.quotas.keys)
  }

  public init() {}

  public init(policy: Policy) {
    minutes = Dictionary(uniqueKeysWithValues: policy.limits.map { ($0.app.id, $0.minutes) })
    for app in policy.allowed + policy.limits.map(\.app) {
      let id = Self.namedIDs.contains(app.id) ? "selected-\(UUID().uuidString)" : app.id
      applications.append(AppEntry(id: id, label: app.label, token: app.token))
      if Self.namedIDs.contains(app.id) { assignments[app.id] = id }
    }
  }

  public mutating func replaceApplications(_ apps: [AppEntry]) {
    applications = apps
    let ids = Set(apps.map(\.id))
    assignments = assignments.filter { ids.contains($0.value) }
  }

  public mutating func assign(_ role: String, to applicationID: String?) {
    assignments.removeValue(forKey: role)
    guard let applicationID else { return }
    // An app can have one named identity. Moving it to a limit removes its Allow identity.
    assignments = assignments.filter { $0.value != applicationID }
    assignments[role] = applicationID
  }

  public func policy(previous: Policy? = nil) throws -> Policy {
    guard applications.count <= 50 else {
      throw SetupSelectionError.tooManyApps(applications.count)
    }
    let ids = Set(applications.map(\.id))
    guard ids.count == applications.count,
      Set(applications.map(\.token)).count == applications.count,
      applications.allSatisfy({ !$0.id.isEmpty && !$0.token.isEmpty && !$0.label.isEmpty }),
      assignments.allSatisfy({ Self.namedIDs.contains($0.key) && ids.contains($0.value) })
    else { throw SetupSelectionError.invalidSelection }
    var used: [String: String] = [:]
    for (role, id) in assignments.sorted(by: { $0.key < $1.key }) {
      if let first = used[id] { throw SetupSelectionError.duplicateAssignment(first, role) }
      used[id] = role
    }
    var limits: [LimitRule] = []
    for role in Policy.quotas.keys.sorted() {
      guard let id = assignments[role], let app = applications.first(where: { $0.id == id }) else {
        throw SetupSelectionError.missingLimit(role)
      }
      guard let quota = minutes[role], (1...1440).contains(quota) else {
        throw QuietError.invalidPolicy
      }
      let previousRule = previous?.limits.first { $0.app.token == app.token }
      limits.append(
        LimitRule(
          id: previousRule?.id ?? UUID(),
          app: AppEntry(
            id: role,
            label: previousRule?.app.id == role
              ? previousRule!.app.label : role.replacingOccurrences(of: "-", with: " "), token: app.token),
          minutes: quota))
    }
    let limited = Set(limits.map { $0.app.token })
    let allowed = applications.filter { !limited.contains($0.token) }.map { app in
      let role = used[app.id]
      let prior = previous?.allowed.first { $0.token == app.token && $0.id == (role ?? app.id) }
      return AppEntry(id: role ?? app.id, label: prior?.label ?? app.label, token: app.token)
    }
    if let previous,
      Set(allowed.map(\.id)) == Set(previous.allowed.map(\.id)),
      allowed.allSatisfy({ app in previous.allowed.contains(app) }),
      limits.allSatisfy({ rule in previous.limits.contains(rule) })
    {
      return previous
    }
    let orderedAllowed = allowed.sorted { first, second in
      let old = previous?.allowed.map(\.id) ?? []
      return (old.firstIndex(of: first.id) ?? Int.max) < (old.firstIndex(of: second.id) ?? Int.max)
    }
    let policy = Policy(allowed: orderedAllowed, limits: limits)
    try policy.validate()
    return policy
  }
}
