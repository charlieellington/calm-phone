import CryptoKit
import XCTest

final class QuietUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }
  private func launch(_ mode: String, large: Bool = false, remoteName: String? = nil) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["CALM_UI_FIXTURE"] = mode
    if let remoteName { app.launchEnvironment["CALM_UI_REMOTE_NAME"] = remoteName }
    if large {
      app.launchArguments += [
        "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
      ]
    }
    app.launch()
    return app
  }
  private func capture(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  /// XCUIApplication.open relaunches the fixture. The host bridge uses simctl openurl and verifies
  /// the process marker is unchanged, exercising the actual warm onOpenURL/navigation path.
  private func deliver(_ url: URL) {
    let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("CalmUITestURLs")
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let request = directory.appendingPathComponent(UUID().uuidString)
      try JSONEncoder().encode(["url": url.absoluteString]).write(
        to: request.appendingPathExtension("json"), options: .atomic)
      let ack = request.appendingPathExtension("ack").path
      let delivered = XCTNSPredicateExpectation(
        predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: ack) }, object: nil)
      XCTAssertEqual(XCTWaiter.wait(for: [delivered], timeout: 20), .completed)
      let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
      if open.waitForExistence(timeout: 3) { open.tap() }
      try Data().write(to: request.appendingPathExtension("confirmed"))
      let done = request.appendingPathExtension("done").path
      let unchanged = XCTNSPredicateExpectation(
        predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: done) }, object: nil)
      XCTAssertEqual(XCTWaiter.wait(for: [unchanged], timeout: 20), .completed)
    } catch { XCTFail("URL delivery request: \(error)") }
  }
  private func base64(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(
      of: "/", with: "_"
    ).replacingOccurrences(of: "=", with: "")
  }
  private var unlockURL: URL { makeUnlockURL() }
  private func makeUnlockURL(seconds: Int = 1_800_000_000, id: String = String(repeating: "A", count: 22))
    -> URL
  {
    let payload =
      "u1." + id + ".60." + String(seconds) + "." + base64(Data(repeating: 2, count: 8))
    let mac = HMAC<SHA256>.authenticationCode(
      for: Data(payload.utf8), using: SymmetricKey(data: Data(repeating: 1, count: 32)))
    return URL(string: "quiet://unlock?t=" + payload + "." + base64(Data(mac.prefix(16))))!
  }
  private func tap(_ app: XCUIApplication, _ name: String) {
    let exact = app.buttons[name].firstMatch
    let button =
      exact.exists ? exact : app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    for _ in 0..<6 where !button.isHittable { app.swipeUp() }
    XCTAssertTrue(button.waitForExistence(timeout: 5), name)
    XCTAssertTrue(button.isHittable, name)
    button.tap()
  }

  func testStrictFreshLaunch() {
    let app = launch("fresh")
    XCTAssertTrue(app.buttons["Restrict this phone"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.staticTexts["Setup unavailable"].exists)
    XCTAssertFalse(app.buttons["Lock now"].exists)
    capture(app, "ui-fresh-launch")
    tap(app, "Restrict this phone")
    XCTAssertTrue(app.staticTexts["Set up Calm Phone"].waitForExistence(timeout: 5))
    capture(app, "ui-fresh-setup")
  }

  func testWarmURLRevealsActiveStatusFromSettingsMethodsAndModals() {
    for destination in ["Settings", "Unlock methods", "PIN", "Add remote", "Duration", "Connected"] {
      let app = launch("dual")
      if destination == "PIN" || destination == "Duration" {
        tap(app, "Unlock")
        if destination == "Duration" {
          for digit in String(repeating: "7", count: 6) { tap(app, String(digit)) }
          tap(app, "Continue")
        }
      } else if destination == "Connected" {
        let token =
          "c2." + String(repeating: "E", count: 22) + ".1." + String(repeating: "F", count: 22) + "."
          + base64(Data(repeating: 9, count: 32)) + "." + base64(Data("Friend".utf8))
        deliver(URL(string: "quiet://connect?t=" + token)!)
        XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 5))
      } else {
        tap(app, "Settings")
        if destination != "Settings" { tap(app, "Unlock methods") }
        if destination == "Add remote" { tap(app, "Add remote") }
      }
      deliver(unlockURL)
      XCTAssertTrue(app.buttons["Lock now"].waitForExistence(timeout: 10), destination)
      XCTAssertTrue(
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Unlocked by Helper")).firstMatch
          .exists)
      capture(app, "ui-url-from-" + destination.replacingOccurrences(of: " ", with: "-").lowercased())
      tap(app, "Lock now")
      XCTAssertTrue(app.buttons["Unlock"].waitForExistence(timeout: 5))
      deliver(unlockURL)
      XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
      capture(app, "ui-used-from-" + destination.replacingOccurrences(of: " ", with: "-").lowercased())
      app.terminate()
    }
  }

  func testHelperMultipleConnectionsBackShareCancellationAndDisconnect() {
    let app = launch("helper")
    tap(app, "Owner")
    tap(app, "15 minutes")
    tap(app, "Complete test share")
    XCTAssertTrue(app.staticTexts["Link shared. It works once, for 10 minutes."].waitForExistence(timeout: 5))
    tap(app, "1 hour")
    tap(app, "Cancel test share")
    XCTAssertTrue(
      app.staticTexts["Link not shared. Choose a duration to try again."].waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["Link shared. It works once, for 10 minutes."].exists)
    capture(app, "ui-share-cancel-after-success")
    tap(app, "15 minutes")
    tap(app, "Fail test share")
    XCTAssertTrue(
      app.staticTexts["Link not shared. Choose a duration to try again."].waitForExistence(timeout: 5))
    tap(app, "15 minutes")
    for _ in 0..<3 where app.buttons["Cancel test share"].exists {
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.10)).press(
        forDuration: 0.1,
        thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
    }
    XCTAssertTrue(
      app.staticTexts["Link not shared. Choose a duration to try again."].waitForExistence(timeout: 5))
    capture(app, "ui-share-dismissed")
    tap(app, "Back")
    tap(app, String(repeating: "W", count: 40))
    XCTAssertFalse(app.staticTexts["Link not shared. Choose a duration to try again."].exists)
    capture(app, "ui-multiple-long-name")
    tap(app, "Disconnect")
    capture(app, "ui-disconnect-confirmation")
    tap(app, "Disconnect")
    tap(app, "Disconnect")
    tap(app, "Disconnect")
    XCTAssertTrue(app.buttons["Restrict this phone"].waitForExistence(timeout: 5))
    capture(app, "ui-helper-disconnected")
  }

  func testReplacementWhileSelectedResetsToCurrentConnection() {
    let app = launch("helper")
    tap(app, "Owner")
    tap(app, "15 minutes")
    tap(app, "Complete test share")
    let token =
      "c2." + String(repeating: "C", count: 22) + ".2." + String(repeating: "H", count: 22) + "."
      + base64(Data(repeating: 9, count: 32)) + "." + base64(Data("Owner new".utf8))
    deliver(URL(string: "quiet://connect?t=" + token)!)
    tap(app, "Continue")
    XCTAssertTrue(app.buttons["Owner new"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Owner"].exists)
    tap(app, "Owner new")
    XCTAssertFalse(app.staticTexts["Link shared. It works once, for 10 minutes."].exists)
    capture(app, "ui-replaced-current-selection")
    tap(app, "1 hour")
    tap(app, "Complete test share")
  }

  func testInvalidExpiredUnknownAndActiveFeedback() {
    let app = launch("restricted")
    for (name, url) in [
      ("invalid", URL(string: "quiet://unlock?t=invalid")!),
      ("expired", makeUnlockURL(seconds: 1_799_999_399)),
      ("unknown", makeUnlockURL(id: String(repeating: "G", count: 22))),
    ] {
      deliver(url)
      XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
      capture(app, "ui-link-error-" + name)
      tap(app, "OK")
      XCTAssertFalse(app.buttons["Lock now"].exists)
    }
    deliver(unlockURL)
    XCTAssertTrue(app.buttons["Lock now"].waitForExistence(timeout: 5))
    deliver(unlockURL)
    XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
    capture(app, "ui-already-active-precedence")
    tap(app, "OK")
    XCTAssertTrue(app.buttons["Lock now"].exists)
  }

  func testAddRemoteCancellationRetainsReshareableRowAndRemoval() {
    let app = launch("restricted", large: true)
    tap(app, "Settings")
    tap(app, "Unlock methods")
    tap(app, "Add remote")
    let name = String(repeating: "N", count: 40)
    let field = app.textFields["Their name"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.tap()
    field.typeText(name)
    capture(app, "ui-add-remote-keyboard-accessibility")
    tap(app, "remote-name-done")
    XCTAssertFalse(app.keyboards.firstMatch.exists)
    capture(app, "ui-add-remote-keyboard-dismissed")
    tap(app, "Share link")
    tap(app, "Cancel test share")
    XCTAssertTrue(app.navigationBars["Unlock methods"].waitForExistence(timeout: 5))
    capture(app, "ui-add-cancel-retains-row")
    tap(app, name)
    tap(app, "Share link again")
    tap(app, "Complete test share")
    tap(app, "Remove")
    capture(app, "ui-remove-remote-confirmation")
    tap(app, "Remove")
    XCTAssertTrue(app.navigationBars["Unlock methods"].waitForExistence(timeout: 5))
  }

  func testActiveStatusAndLockNowAtLargestText() {
    let app = launch("restricted", large: true, remoteName: String(repeating: "N", count: 40))
    deliver(unlockURL)
    XCTAssertTrue(app.buttons["Lock now"].waitForExistence(timeout: 10))
    capture(app, "ui-active-long-accessibility-top")
    for _ in 0..<6 where !app.buttons["Lock now"].isHittable { app.swipeUp() }
    capture(app, "ui-active-long-accessibility-bottom")
    tap(app, "Lock now")
    XCTAssertTrue(app.buttons["Unlock"].waitForExistence(timeout: 5))
  }

  func testSetupDeclinesURLWithoutDismissingDraft() {
    let app = launch("fresh")
    tap(app, "Restrict this phone")
    tap(app, "Set up with the PIN holder")
    XCTAssertTrue(app.navigationBars["Set up Calm Phone"].waitForExistence(timeout: 5))
    deliver(unlockURL)
    XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
    capture(app, "ui-setup-link-declined")
    tap(app, "OK")
    XCTAssertTrue(app.navigationBars["Set up Calm Phone"].waitForExistence(timeout: 5))
    capture(app, "ui-setup-draft-preserved")
    XCTAssertFalse(app.buttons["Lock now"].exists)
  }

  func testConnectedAndUnlockControlsAtLargestText() {
    let app = launch("fresh", large: true)
    let name = String(repeating: "W", count: 40)
    let token =
      "c2." + String(repeating: "E", count: 22) + ".1." + String(repeating: "F", count: 22) + "."
      + base64(Data(repeating: 9, count: 32)) + "." + base64(Data(name.utf8))
    deliver(URL(string: "quiet://connect?t=" + token)!)
    XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 5))
    capture(app, "ui-connected-long-accessibility-top")
    app.swipeUp()
    capture(app, "ui-connected-long-accessibility-bottom")
    tap(app, "Continue")
    tap(app, "Until midnight")
    tap(app, "Cancel test share")
    tap(app, "Disconnect")
    capture(app, "ui-unlock-long-accessibility-bottom")
  }
}
