import XCTest

// 关键路径 UI 自动化（五标签栏新导航）：①发布记录 ②设置提醒 ③导出 PDF ④日历当日记录 ⑤冷启动
final class PrototypeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["PETPAL_UI_TEST_STORE_ID"] = UUID().uuidString
        app.launch()
    }

    // 路径①：我的 tab 建档案 → 记录 tab 记一条喂食（通用动态表单）
    func test_createPet_thenLogFeeding() {
        createPetIfNeeded()

        app.tabBars.buttons["记录"].tap()
        assertHasCurrentPet()
        app.buttons["records.add"].tap()
        XCTAssertTrue(app.buttons["record.template.喂食"].waitForExistence(timeout: 3))
        app.buttons["record.template.喂食"].tap()
        app.textFields["record.field.food"].tap()
        app.typeText("处方粮")
        app.textFields["record.field.grams"].tap()
        app.typeText("80")
        // 「用餐时段」为必填：必须真正选中，否则校验拦截、保存并未发生（修复假绿）
        pickOption("早", field: "record.field.mealTime")
        app.buttons["record.save"].tap()
        // 保存成功 = sheet 真正关闭（record.save 消失），而非背后层级可查到记录页按钮
        XCTAssertTrue(app.buttons["record.save"].waitForNonExistence(timeout: 2))
        XCTAssertTrue(app.buttons["records.add"].waitForExistence(timeout: 2))
    }

    // 回归：删除全部档案 → 重新建档 → 应能正常记一条（用户报告：重建后无法记录）
    func test_deleteAllPets_thenRecreate_canLogRecord() {
        createPetIfNeeded()
        // 删除全部档案（可能有多只）：详情页删除按钮在屏外，需先上滑
        app.tabBars.buttons["我的"].tap()
        let petRows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "pet.row."))
        for _ in 0..<5 {
            guard petRows.firstMatch.waitForExistence(timeout: 2) else { break }
            petRows.firstMatch.tap()
            app.swipeUp()   // 「删除该宠物档案」在表单底部，离屏单元格不会实例化
            XCTAssertTrue(app.buttons["pet.delete"].waitForExistence(timeout: 3))
            app.buttons["pet.delete"].tap()
            let confirm = app.buttons["删除（含全部记录与提醒）"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 3))
            confirm.tap()
            XCTAssertTrue(app.buttons["pet.add"].waitForExistence(timeout: 3))
        }
        XCTAssertTrue(app.staticTexts["pet.emptyGuide"].waitForExistence(timeout: 3),
                      "删除后应回到空态引导")

        // 重新建档
        createPetIfNeeded()

        // 直接记一条：按钮应可用，保存后时间轴原地出现
        app.tabBars.buttons["记录"].tap()
        assertHasCurrentPet()
        app.buttons["records.add"].tap()
        XCTAssertTrue(app.buttons["record.template.训练"].waitForExistence(timeout: 3))
        app.buttons["record.template.训练"].tap()
        app.textFields["record.field.subject"].tap()
        app.typeText("召回")
        app.buttons["record.save"].tap()
        XCTAssertTrue(app.buttons["record.save"].waitForNonExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["召回"].waitForExistence(timeout: 3),
                      "重建档案后应能正常保存并显示记录")
    }

    // 回归：保存记录后时间轴应「原地」出现新行，无需切换界面（跨实例广播修复的 UI 级验证）
    func test_timelineShowsNewRecordWithoutSwitchingTabs() {
        createPetIfNeeded()
        app.tabBars.buttons["记录"].tap()
        assertHasCurrentPet()

        app.buttons["records.add"].tap()
        XCTAssertTrue(app.buttons["record.template.训练"].waitForExistence(timeout: 3))
        app.buttons["record.template.训练"].tap()
        app.textFields["record.field.subject"].tap()
        app.typeText("随行")
        app.buttons["record.save"].tap()
        XCTAssertTrue(app.buttons["record.save"].waitForNonExistence(timeout: 2))

        // 不切 tab、不滚动：新记录的摘要文案应直接出现在时间轴上
        // （不能用行数断言：屏幕外的行会被无障碍树裁剪，计数不可靠）
        XCTAssertTrue(app.staticTexts["随行"].waitForExistence(timeout: 3),
                      "保存后时间轴应立即显示新记录，无需切换界面")
    }

    // 校验拦截：昵称为空时保存失败，错误文案出现且表单 sheet 保持打开
    func test_emptyNickname_blocksSave() {
        app.tabBars.buttons["我的"].tap()
        // 独立数据库保证空态，不能因为已有档案而跳过校验。
        XCTAssertTrue(app.staticTexts["pet.emptyGuide"].waitForExistence(timeout: 5))
        app.buttons["pet.createFirst"].tap()
        app.buttons["pet.save"].tap()
        XCTAssertTrue(app.staticTexts["昵称需为1-20个字符"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["pet.save"].exists)   // sheet 未关闭
    }

    // 路径②：设置每日提醒（含系统权限弹窗处理）
    func test_setDailyReminder() {
        createPetIfNeeded()
        app.tabBars.buttons["记录"].tap()
        // 系统权限弹窗（中文系统按钮为「允许」，英文为 "Allow"）
        addUIInterruptionMonitor(withDescription: "通知权限") { alert in
            if alert.buttons["允许"].exists { alert.buttons["允许"].tap(); return true }
            if alert.buttons["Allow"].exists { alert.buttons["Allow"].tap(); return true }
            return false
        }
        XCTAssertTrue(app.buttons["records.reminder"].waitForExistence(timeout: 3))
        app.buttons["records.reminder"].tap()
        app.buttons["reminders.add"].tap()
        app.buttons["reminder.save"].tap()
        app.tap()   // 触发 interruption monitor 消费弹窗
        // 授权后保存成功回记录页；若曾拒绝则出现引导 Alert
        let backRecords = app.buttons["reminder.save"].waitForNonExistence(timeout: 5)
        let deniedAlert = app.alerts["通知权限未开启"].exists
        XCTAssertTrue(backRecords || deniedAlert)
        if deniedAlert { app.alerts["通知权限未开启"].buttons["稍后"].tap() }
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "reminders.edit.")).count, 1)
        app.terminate(); app.launch()
        app.tabBars.buttons["记录"].tap(); app.buttons["records.reminder"].tap()
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "reminders.edit.")).count, 1, "重新启动后提醒应仍存在")
    }

    // 无效重复规则不能触发保存或关闭表单，用户可以原地修改后重试。
    func test_emptyWeeklySelection_keepsReminderFormOpen() {
        createPetIfNeeded()
        app.tabBars.buttons["记录"].tap()
        app.buttons["records.reminder"].tap()
        app.buttons["reminders.add"].tap()
        app.buttons["reminder.repeat"].tap()
        app.buttons["每周"].tap()
        let monday = app.switches["reminder.weekday.2"]
        XCTAssertTrue(monday.waitForExistence(timeout: 3))
        toggleWeekday(monday)
        XCTAssertEqual(monday.value as? String, "0")
        app.buttons["reminder.save"].tap()
        XCTAssertTrue(app.staticTexts["reminder.error"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["reminder.save"].exists, "校验失败后应保留表单")
        XCTAssertEqual(monday.value as? String, "0", "不能把空星期改为默认重复规则")
        toggleWeekday(monday)
        XCTAssertEqual(monday.value as? String, "1", "校验失败后应仍可编辑")
    }

    // ③ 导出 PDF：建档案 → 我的 tab → 成长看板 → 导出 → 系统分享面板出现
    func test_exportPDF() throws {
        createPetIfNeeded()
        app.tabBars.buttons["我的"].tap()
        XCTAssertTrue(app.buttons["profile.dashboard"].waitForExistence(timeout: 3))
        app.buttons["profile.dashboard"].tap()
        // 看板出现：导出按钮 + 三大区块锚点。体重图表区两种状态皆可：
        // 无体重数据 → 占位文案；本容器已有体重数据（如体重录入用例跑过）→ 折线图
        let exportButton = app.buttons["dashboard.exportPDF"]
        XCTAssertTrue(exportButton.waitForExistence(timeout: 3))
        let chartEmpty = app.staticTexts["dashboard.chartEmpty"].waitForExistence(timeout: 3)
        let chartShown = app.descendants(matching: .any).matching(identifier: "dashboard.chart").firstMatch.exists
        XCTAssertTrue(chartEmpty || chartShown, "看板应展示体重图表区（空态占位或折线图）")
        XCTAssertTrue(app.staticTexts["dashboard.heatmap"].exists)
        XCTAssertTrue(app.staticTexts["dashboard.timeline"].exists)
        exportButton.tap()
        XCTAssertTrue(app.staticTexts["dashboard.pdfPageCount"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["dashboard.pdfPageCount"].label, "3 页")
        XCTAssertTrue(app.buttons["dashboard.sharePDF"].exists)

    }

    // 路径④：记喂食 → 记录页切日历分段 → 今日格子可点且当日列表出现记录
    func test_calendarShowsTodayRecord() {
        createPetIfNeeded()
        // 记一条喂食，保证今日有记录圆点（mealTime 为必填，需先选择用餐时段）
        app.tabBars.buttons["记录"].tap()
        app.buttons["records.add"].tap()
        app.buttons["record.template.喂食"].tap()
        app.textFields["record.field.food"].tap()
        app.typeText("罐头")
        app.textFields["record.field.grams"].tap()
        app.typeText("100")
        pickOption("午", field: "record.field.mealTime")
        app.buttons["record.save"].tap()
        // 校验通过 sheet 才真正关闭
        XCTAssertTrue(app.buttons["records.add"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["record.save"].exists, "喂食 sheet 应已关闭")

        // 切到「日历」分段
        let calendarSegment = app.buttons["日历"].exists ? app.buttons["日历"] : app.buttons["records.segment"]
        calendarSegment.tap()
        XCTAssertTrue(app.staticTexts["calendar.dayListTitle"].waitForExistence(timeout: 3))
        // 今日格子：identifier calendar.day.M月d日，提示「有n条记录」
        let cal = Calendar.current
        let m = cal.component(.month, from: Date())
        let d = cal.component(.day, from: Date())
        let todayCell = app.buttons["calendar.day.\(m)月\(d)日"]
        XCTAssertTrue(todayCell.waitForExistence(timeout: 3))
        todayCell.tap()
        // 当日列表出现刚保存的记录（类型「喂食」）
        XCTAssertTrue(app.buttons.matching(identifier: "calendar.recordRow")
            .firstMatch.waitForExistence(timeout: 3))
    }

    // 冷启动性能基线（PRD §7：≤2 秒；XCTApplicationLaunchMetric 测至首帧渲染完成）
    func test_launchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            app.terminate(); app.launch()
        }
    }

    func test_recordEditAndDelete_refreshTimelineAndCalendar() {
        createPetIfNeeded()
        app.tabBars.buttons["记录"].tap()
        app.buttons["records.add"].tap(); app.buttons["record.template.训练"].tap()
        app.textFields["record.field.subject"].tap(); app.typeText("编辑前")
        app.buttons["record.save"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "records.row.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        XCTAssertTrue(app.buttons["record.edit"].waitForExistence(timeout: 5)); app.buttons["record.edit"].tap()
        let field = app.textFields["record.field.subject"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap()
        app.typeText(String(repeating: "\u{8}", count: 3) + "编辑后")
        app.buttons["record.save"].tap()
        XCTAssertTrue(app.staticTexts["编辑后"].waitForExistence(timeout: 5))
        app.buttons["record.detailDone"].tap()
        XCTAssertTrue(app.staticTexts["编辑后"].waitForExistence(timeout: 5))
        app.terminate(); app.launch(); app.tabBars.buttons["记录"].tap()
        XCTAssertTrue(app.staticTexts["编辑后"].waitForExistence(timeout: 5), "重新启动后编辑结果应持久化")
        app.buttons["日历"].tap()
        let calendarRow = app.buttons["calendar.recordRow"].firstMatch
        XCTAssertTrue(calendarRow.waitForExistence(timeout: 5)); calendarRow.tap()
        XCTAssertTrue(app.staticTexts["编辑后"].waitForExistence(timeout: 5))
        app.swipeUp(); app.buttons["record.delete"].tap(); app.buttons["确认删除记录"].tap()
        XCTAssertTrue(app.staticTexts["calendar.dayListEmpty"].waitForExistence(timeout: 5))
        app.buttons["时间轴"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "records.timelineEmpty").firstMatch.waitForExistence(timeout: 5))
    }

    func test_reminderEditPauseResumeAndDelete() {
        createPetIfNeeded(); app.tabBars.buttons["记录"].tap()
        app.buttons["records.reminder"].tap(); app.buttons["reminders.add"].tap()
        app.buttons["reminder.save"].tap()
        XCTAssertTrue(app.buttons["reminder.save"].waitForNonExistence(timeout: 5))
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "reminders.edit.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        XCTAssertTrue(app.buttons["reminder.repeat"].waitForExistence(timeout: 5))
        app.buttons["reminder.repeat"].tap(); app.buttons["每周"].tap()
        app.buttons["reminder.save"].tap()
        XCTAssertTrue(app.buttons["reminder.save"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["周一 · 准时"].waitForExistence(timeout: 5))
        let enabled = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH %@", "reminders.enabled.")).firstMatch
        toggleWeekday(enabled)
        XCTAssertEqual(enabled.value as? String, "0")
        app.terminate(); app.launch(); app.tabBars.buttons["记录"].tap(); app.buttons["records.reminder"].tap()
        XCTAssertTrue(enabled.waitForExistence(timeout: 5)); XCTAssertEqual(enabled.value as? String, "0")
        toggleWeekday(enabled); XCTAssertEqual(enabled.value as? String, "1")
        row.swipeLeft()
        let remove = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "reminders.delete.")).firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5)); remove.tap(); app.buttons["删除提醒"].tap()
        XCTAssertTrue(app.staticTexts["reminders.empty"].waitForExistence(timeout: 5))
    }

    func test_customTemplateSnapshot_survivesTemplateDeletion() {
        createPetIfNeeded(); app.tabBars.buttons["记录"].tap(); app.buttons["records.add"].tap()
        app.buttons["record.template.manage"].tap(); app.buttons["template.add"].tap()
        app.textFields["template.name"].tap(); app.typeText("用药档案")
        let title = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@", "template.fieldTitle.")).firstMatch
        title.tap(); app.typeText("药品名称")
        app.buttons["template.save"].tap()
        XCTAssertTrue(app.buttons["template.row.用药档案"].waitForExistence(timeout: 5))
        app.buttons["template.done"].tap()
        let custom = app.buttons["record.template.custom.用药档案"]
        XCTAssertTrue(custom.waitForExistence(timeout: 5)); custom.tap()
        let answer = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@", "custom.field.")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 5)); answer.tap(); app.typeText("益生菌")
        app.buttons["custom.save"].tap()
        XCTAssertTrue(app.buttons["custom.save"].waitForNonExistence(timeout: 5))
        app.buttons["records.add"].tap(); app.buttons["record.template.manage"].tap()
        app.buttons["template.row.用药档案"].swipeLeft()
        (app.buttons["删除"].exists ? app.buttons["删除"] : app.buttons["Delete"]).tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "template.empty").firstMatch.waitForExistence(timeout: 5))
        app.buttons["template.done"].tap(); app.buttons["record.template.close"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "records.row.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        XCTAssertTrue(app.staticTexts["药品名称"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["益生菌"].exists)
        app.buttons["record.edit"].tap()
        XCTAssertEqual(answer.value as? String, "益生菌")
    }

    /// 冷启动无档案时先建一个（「我的」tab → 空态「创建第一个宠物档案」）；已有档案则直接返回
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

    private func assertHasCurrentPet() {
        let hasPet = NSPredicate { [app] _, _ in
            app!.staticTexts["records.currentPet"].exists || app!.buttons["records.petSwitcher"].exists
        }
        let expectation = XCTNSPredicateExpectation(predicate: hasPet, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 3), .completed,
                       "单宠或多宠模式都应显示当前宠物")
    }

    private func toggleWeekday(_ row: XCUIElement) {
        let control = row.switches.firstMatch
        if control.exists {
            control.tap()
        } else {
            // SwiftUI 可把整行暴露为 Switch；真正的拨动控件在行的右侧。
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
    }

    /// 点选单选 Picker（用餐时段等）的选项：decimalPad 键盘在位时首次点击只收键盘，带重试
    private func pickOption(_ option: String, field: String) {
        app.buttons[field].tap()
        for _ in 0..<3 {
            let el = app.buttons[option].exists ? app.buttons[option] : app.cells[option]
            if el.waitForExistence(timeout: 2) { el.tap(); return }
            app.buttons[field].tap()
        }
        XCTFail("字段 \(field) 的选项「\(option)」未出现")
    }
}
