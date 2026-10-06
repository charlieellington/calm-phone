import XCTest

final class QuietUITests: XCTestCase {
  func testGivenFreshLaunch_WhenUnconfigured_ThenNeverClaimsProtectionActive() {
    let app = XCUIApplication()
    app.launch()
    let intro = app.staticTexts["Set up Calm Phone"]
    let repair = app.staticTexts["Setup unavailable"]
    XCTAssertTrue(intro.waitForExistence(timeout: 10) || repair.waitForExistence(timeout: 2))
    XCTAssertFalse(app.buttons["Lock now"].exists)
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "unconfigured-or-repair-state"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
