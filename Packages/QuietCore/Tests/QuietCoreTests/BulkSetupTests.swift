import XCTest

@testable import QuietCore

final class BulkSetupTests: XCTestCase {
  private func draft(count: Int = 20) -> BulkSetupDraft {
    var draft = BulkSetupDraft()
    draft.applications = (0..<count).map {
      AppEntry(id: "selected-\($0)", label: "app \($0)", token: "synthetic-\($0)")
    }
    for (index, role) in Policy.quotas.keys.sorted().enumerated() {
      draft.assign(role, to: draft.applications[index].id)
    }
    return draft
  }

  func testBulkSelectionSplitsIntoDisjointAllowAndSixLimits() throws {
    var draft = draft()
    draft.assign("whatsapp", to: "selected-6")
    draft.assign("find-my", to: "selected-7")
    let policy = try draft.policy()
    XCTAssertEqual(policy.allowed.count, 14)
    XCTAssertEqual(policy.limits.count, 6)
    XCTAssertTrue(Set(policy.allowed.map(\.token)).isDisjoint(with: policy.limits.map { $0.app.token }))
    XCTAssertEqual(policy.tokens, Set(draft.applications.map(\.token)))
    XCTAssertEqual(policy.limits.first { $0.app.id == "claude" }?.minutes, 30)
    XCTAssertEqual(policy.allowed.first { $0.id == "find-my" }?.token, "synthetic-7")
  }

  func testExactlyFiftyAppsAreAcceptedAndFiftyOneAreRejected() throws {
    XCTAssertEqual(try draft(count: 50).policy().tokens.count, 50)
    XCTAssertThrowsError(try draft(count: 51).policy()) {
      XCTAssertEqual($0 as? SetupSelectionError, .tooManyApps(51))
    }
  }

  func testMissingLimitIdentifiesTheSpecificRow() {
    var draft = draft()
    draft.assign("weather", to: nil)
    XCTAssertThrowsError(try draft.policy()) {
      XCTAssertEqual($0 as? SetupSelectionError, .missingLimit("weather"))
      XCTAssertTrue($0.localizedDescription.contains("weather"))
    }
  }

  func testMovingAnAllowedAppToALimitRemovesItsAllowIdentity() throws {
    var draft = draft()
    draft.assign("whatsapp", to: "selected-6")
    draft.assign("claude", to: "selected-6")
    let policy = try draft.policy()
    XCTAssertNil(draft.assignments["whatsapp"])
    XCTAssertFalse(policy.allowed.contains { $0.token == "synthetic-6" })
    XCTAssertEqual(policy.limits.first { $0.app.id == "claude" }?.app.token, "synthetic-6")
  }

  func testDuplicateAssignmentsAndInvalidSelectionsCannotProduceAPolicy() {
    var duplicate = draft()
    duplicate.assignments["whatsapp"] = duplicate.assignments["claude"]
    XCTAssertThrowsError(try duplicate.policy()) {
      XCTAssertEqual($0 as? SetupSelectionError, .duplicateAssignment("claude", "whatsapp"))
    }
    var stale = draft()
    stale.assignments["weather"] = "missing"
    XCTAssertThrowsError(try stale.policy()) {
      XCTAssertEqual($0 as? SetupSelectionError, .invalidSelection)
    }
    var sameToken = draft()
    sameToken.applications[7].token = sameToken.applications[6].token
    XCTAssertThrowsError(try sameToken.policy()) {
      XCTAssertEqual($0 as? SetupSelectionError, .invalidSelection)
    }
  }

  func testRemovingAnAppClearsItsMappingAndRequiresReplacementLimit() {
    var draft = draft()
    let removed = draft.assignments["files"]!
    draft.replaceApplications(draft.applications.filter { $0.id != removed })
    XCTAssertNil(draft.assignments["files"])
    XCTAssertThrowsError(try draft.policy()) {
      XCTAssertEqual($0 as? SetupSelectionError, .missingLimit("files"))
    }
  }

  func testSavedNamedPolicyRoundTripsWithoutLosingRoutesNamesOrLimitIDs() throws {
    let previous = Policy(
      allowed: AppCatalog.allow.map {
        AppEntry(id: $0.0, label: $0.1, token: "synthetic-\($0.0)")
      } + [AppEntry(id: "custom-tool", label: "second tool", token: "synthetic-tool-2")],
      limits: Policy.quotas.map {
        LimitRule(
          app: AppEntry(
            id: $0.0, label: $0.0.replacingOccurrences(of: "-", with: " "), token: "synthetic-\($0.0)"),
          minutes: $0.1)
      })
    let restored = try BulkSetupDraft(policy: previous).policy(previous: previous)
    XCTAssertEqual(restored.allowed, previous.allowed)
    XCTAssertEqual(Set(restored.limits.map(\.id)), Set(previous.limits.map(\.id)))
    XCTAssertEqual(restored.tokens, previous.tokens)
    for rule in restored.limits {
      XCTAssertEqual(rule, previous.limits.first { $0.app.id == rule.app.id })
    }
  }

  func testClearingANamedLinkDoesNotSilentlyRetainItsRouteIdentity() throws {
    var initial = draft()
    initial.assign("whatsapp", to: "selected-6")
    let previous = try initial.policy()
    var restored = BulkSetupDraft(policy: previous)
    restored.assign("whatsapp", to: nil)
    let policy = try restored.policy(previous: previous)
    XCTAssertFalse(policy.allowed.contains { $0.id == "whatsapp" })
    XCTAssertTrue(policy.allowed.contains { $0.token == "synthetic-6" })
  }

  func testSearchNamesForBulkAppsSurviveRoundTrip() throws {
    var draft = draft()
    draft.applications[6].label = "custom tool"
    let policy = try draft.policy()
    XCTAssertEqual(policy.allowed.first { $0.token == "synthetic-6" }?.label, "custom tool")
    let restored = try BulkSetupDraft(policy: policy).policy(previous: policy)
    XCTAssertEqual(restored, policy)
  }
}

extension BulkSetupTests {
  func testUnchangedFiftyAppDraftPreservesEveryIdentityLabelTokenLimitUUIDAndGeneration() throws {
    var policy = fixturePolicy()
    policy.allowed = (0..<44).map {
      AppEntry(
        id: $0 == 0 ? "whatsapp" : "saved-\($0)", label: "Saved label \($0)", token: "opaque-fixture-\($0)")
    }
    for i in policy.limits.indices { policy.limits[i].app.label = "Saved limited label \(i)" }
    try policy.validate()
    var draft = BulkSetupDraft(policy: policy)
    XCTAssertEqual(try draft.policy(previous: policy), policy)
    draft.minutes[policy.limits[0].app.id] = policy.limits[0].minutes + 5
    let changed = try draft.policy(previous: policy)
    XCTAssertEqual(changed.allowed, policy.allowed)
    XCTAssertEqual(changed.limits.map(\.id), policy.limits.map(\.id))
    XCTAssertEqual(changed.limits.map(\.app), policy.limits.map(\.app))
    XCTAssertNotEqual(changed.generation, policy.generation)
    XCTAssertEqual(policy.tokens, changed.tokens)
  }
}
