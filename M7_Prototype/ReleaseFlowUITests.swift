import XCTest

final class ReleaseFlowUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUp() { continueAfterFailure = false; app = XCUIApplication() }
    private func launch(_ scenario: String) {
        app.launchArguments = ["--petpal-preview", scenario, "--reset-onboarding", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
    }
    func test_skipPersistsAndCanBeReopened() {
        launch("empty")
        XCTAssertTrue(app.buttons["onboarding.continue"].waitForExistence(timeout: 5))
        app.buttons["onboarding.skip"].tap()
        XCTAssertTrue(app.buttons["onboarding.skip"].waitForNonExistence(timeout: 3))
        app.terminate(); app.launchArguments.removeAll { $0 == "--reset-onboarding" }; app.launch()
        XCTAssertTrue(app.buttons["today.createPet"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["onboarding.skip"].exists)
        app.petPalTab("我的").tap()
        app.buttons["profile.onboarding"].tap()
        XCTAssertTrue(app.buttons["onboarding.continue"].waitForExistence(timeout: 3))
        app.buttons["onboarding.continue"].tap()
        XCTAssertTrue(app.buttons["pet.save"].waitForExistence(timeout: 3))
        app.buttons["pet.save"].tap()
        XCTAssertTrue(app.buttons["pet.save"].exists, "空档案不能推进引导")
        app.textFields["pet.nickname"].tap(); app.typeText("引导宠物")
        app.textFields["pet.breed"].tap(); app.typeText("柯基")
        app.buttons["pet.save"].tap()
        XCTAssertTrue(app.buttons["pet.save"].waitForNonExistence(timeout: 5))
        let next = app.buttons["onboarding.continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 3)); XCTAssertEqual(next.label, "记第一条日常")
        next.tap(); app.buttons["record.template.训练"].tap()
        let subject = app.textFields["record.field.subject"]
        XCTAssertTrue(subject.waitForExistence(timeout: 3)); subject.tap(); subject.typeText("随行")
        app.buttons["record.save"].tap()
        XCTAssertTrue(app.buttons["record.save"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(next.label, "设置第一个提醒")
        next.tap(); XCTAssertTrue(app.buttons["reminder.save"].waitForExistence(timeout: 3))
        app.buttons["reminder.save"].tap()
        if app.alerts["提醒已保存"].waitForExistence(timeout: 3) { app.alerts["提醒已保存"].buttons["知道了"].tap() }
        XCTAssertTrue(app.buttons["reminder.save"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["onboarding.finish"].waitForExistence(timeout: 3))
        app.buttons["onboarding.finish"].tap()
        XCTAssertTrue(app.buttons["onboarding.skip"].waitForNonExistence(timeout: 3))
    }
    func test_reportRangeAndSystemShare() {
        launch("demo"); app.petPalTab("成长").tap()
        app.buttons["dashboard.exportPDF"].tap()
        XCTAssertTrue(app.buttons["report.generate"].waitForExistence(timeout: 3))
        app.switches["report.allDates"].switches.firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "report.start").firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "report.end").firstMatch.exists)
        let generate = app.buttons["report.generate"]
        if !generate.isHittable { app.swipeUp() }
        generate.tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 5), "应打开系统分享面板")
    }
    func test_feedbackCopyShowsConfirmation() {
        launch("empty"); app.petPalTab("我的").tap(); app.buttons["profile.privacy"].tap()
        let copy = app.buttons["support.copyFeedback"]
        for _ in 0..<8 { if copy.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(copy.isHittable); copy.tap()
        if !app.staticTexts["support.copied"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["support.copied"].exists)
    }
    /// 真实 SwiftUI 页面 + 合成演示资料；同一测试可在 iPhone / iPad 生成原生分辨率截图。
    func test_storeScreenshots() {
        launch("demo")
        XCTAssertTrue(app.buttons["today.addRecord"].waitForExistence(timeout: 5))
        capture("01-today")
        app.petPalTab("记录").tap(); XCTAssertTrue(app.buttons["records.add"].waitForExistence(timeout: 3)); capture("02-records")
        app.petPalTab("成长").tap(); XCTAssertTrue(app.buttons["dashboard.exportPDF"].waitForExistence(timeout: 3)); capture("03-growth")
        app.buttons["dashboard.exportPDF"].tap(); XCTAssertTrue(app.buttons["report.generate"].waitForExistence(timeout: 3)); capture("04-medical-report")
        app.buttons["取消"].tap(); app.petPalTab("我的").tap(); XCTAssertTrue(app.buttons["pet.row.奶糖"].waitForExistence(timeout: 3)); capture("05-profile")
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "store-" + name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
