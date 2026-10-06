import XCTest

// M7 体重录入关键路径：我的 tab「记体重」→ 调整 Stepper → 保存 → 成长看板折线图出现（空态消失）
final class WeightUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["PETPAL_UI_TEST_STORE_ID"] = UUID().uuidString
        app.launch()
    }

    /// 万能 identifier 查询（Chart 等自定义视图元素类型随 iOS 版本漂移，按 identifier 收敛）
    private func a11y(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    // 路径：记体重（调一次 Stepper）→ 保存回我的页 → 看板出现该宠物折线、空态占位消失
    func test_logWeight_thenVisibleOnDashboard() {
        createPetIfNeeded()
        app.tabBars.buttons["我的"].tap()
        XCTAssertTrue(app.buttons["profile.addWeight"].waitForExistence(timeout: 3))

        app.buttons["profile.addWeight"].tap()
        let stepper = app.steppers["weight.kg"]
        XCTAssertTrue(stepper.waitForExistence(timeout: 3), "应打开体重录入表单")
        XCTAssertTrue(app.buttons["weight.save"].exists)
        // Stepper +0.1kg；无增量子按钮（无障碍实现差异）时退化为直接用默认值保存
        if stepper.buttons["Increment"].exists {
            stepper.buttons["Increment"].tap()
        }

        app.buttons["weight.save"].tap()
        // 保存成功 = sheet 真正关闭（weight.save 消失），而非背后层级可查到我的页按钮
        XCTAssertTrue(app.buttons["weight.save"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["profile.dashboard"].waitForExistence(timeout: 3))

        app.buttons["profile.dashboard"].tap()
        // 有体重数据 → Swift Charts 折线图挂载 dashboard.chart；空态占位 dashboard.chartEmpty 消失
        XCTAssertTrue(a11y("dashboard.chart").waitForExistence(timeout: 5), "看板应展示体重折线图")
        XCTAssertTrue(app.staticTexts["dashboard.chartEmpty"].waitForNonExistence(timeout: 3),
                      "有空数据时不应再显示空态占位")
    }

    // 直输通道：TextField 直接输入 12.5（不点 Stepper）→ 保存 → sheet 关闭
    func test_logWeight_viaDirectTextInput() {
        createPetIfNeeded()
        app.tabBars.buttons["我的"].tap()
        XCTAssertTrue(app.buttons["profile.addWeight"].waitForExistence(timeout: 3))

        app.buttons["profile.addWeight"].tap()
        let field = app.textFields["weight.kgInput"]
        XCTAssertTrue(field.waitForExistence(timeout: 3), "应支持直接输入体重数值")
        field.tap()
        field.typeText("\u{8}12.5")   // 先退格清掉默认值，再直接输入

        app.buttons["weight.save"].tap()
        XCTAssertTrue(app.buttons["weight.save"].waitForNonExistence(timeout: 3),
                      "合法的直输值应保存成功并关闭表单")
    }

    /// 冷启动无档案时先建一个（与 PrototypeUITests.createPetIfNeeded 等效，私有方法故自持一份）
    private func createPetIfNeeded() {
        app.tabBars.buttons["我的"].tap()
        guard app.staticTexts["pet.emptyGuide"].waitForExistence(timeout: 3) else { return }
        app.buttons["pet.createFirst"].tap()
        app.textFields["pet.nickname"].tap()
        app.typeText("小白")
        app.textFields["pet.breed"].tap()
        app.typeText("柯基")
        app.buttons["pet.save"].tap()
        XCTAssertTrue(app.buttons["pet.add"].waitForExistence(timeout: 3), "建档后应回到宠物列表")
    }
}
