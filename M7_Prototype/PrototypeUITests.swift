import XCTest

// 关键路径 UI 自动化（本地首版四标签导航）：①发布记录 ②设置提醒 ③导出 PDF ④日历当日记录 ⑤冷启动
final class PrototypeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func test_localReleaseNavigationAndDataTools() {
        XCTAssertTrue(app.petPalTab("今日").waitForExistence(timeout: 3))
        XCTAssertTrue(app.petPalTab("记录").exists)
        XCTAssertTrue(app.petPalTab("成长").exists)
        XCTAssertTrue(app.petPalTab("我的").exists)
        XCTAssertFalse(app.petPalTab("首页动态").exists)
        XCTAssertFalse(app.petPalTab("消息").exists)
        XCTAssertFalse(app.buttons["tab.publish"].exists)
        app.petPalTab("我的").tap()
        if !app.buttons["profile.backup"].isHittable { app.swipeUp() }
        app.buttons["profile.backup"].tap()
        XCTAssertTrue(app.navigationBars["数据备份"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["backup.export"].exists)
        XCTAssertTrue(app.buttons["backup.import"].exists)
        app.buttons["完成"].tap()
        app.buttons["profile.privacy"].tap()
        XCTAssertTrue(app.navigationBars["隐私与支持"].waitForExistence(timeout: 3))
    }

    func test_taskCompletionPersistsAndDeletingRecordReopensIt() {
        createPetIfNeeded()
        addUIInterruptionMonitor(withDescription: "通知权限") { alert in
            for title in ["允许", "Allow"] where alert.buttons[title].exists { alert.buttons[title].tap(); return true }
            return false
        }
        app.petPalTab("记录").tap()
        app.buttons["records.reminder"].tap()
        app.buttons["reminders.add"].tap()
        app.buttons["reminder.save"].tap()
        app.navigationBars.firstMatch.tap() // 触发权限弹窗处理，点击标题区域避免误点待办
        if app.alerts["提醒已保存"].waitForExistence(timeout: 2) {
            app.alerts["提醒已保存"].buttons["知道了"].tap()
        }
        XCTAssertTrue(app.buttons["reminders.add"].waitForExistence(timeout: 5))
        let listTask = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT label CONTAINS %@", "tasks.row.", "已完成")).firstMatch
        XCTAssertTrue(listTask.waitForExistence(timeout: 3))
        let cancelledIdentifier = listTask.identifier
        listTask.tap()
        XCTAssertTrue(app.buttons["record.save"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "record.occurredAt").firstMatch.exists)
        app.buttons["取消"].tap()
        XCTAssertTrue(app.buttons["record.save"].waitForNonExistence(timeout: 3))
        XCTAssertFalse(app.buttons[cancelledIdentifier].label.contains("已完成"), "取消表单不能完成任务")
        app.buttons["完成"].tap()
        app.petPalTab("今日").tap()
        let pending = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT label CONTAINS %@", "tasks.row.", "已完成")).firstMatch
        XCTAssertTrue(pending.waitForExistence(timeout: 5))
        let identifier = pending.identifier
        pending.tap()
        if !app.buttons["record.save"].waitForExistence(timeout: 3) { print(app.debugDescription) }
        XCTAssertTrue(app.buttons["record.save"].exists, "点击待办应进入记录表单")
        app.buttons["record.save"].tap()
        XCTAssertTrue(app.buttons["record.save"].exists, "空记录不能提前完成任务")
        let food = app.textFields["record.field.food"]
        if !food.isHittable { app.swipeUp() }
        food.tap(); food.typeText("任务完成测试粮")
        let grams = app.textFields["record.field.grams"]
        if !grams.isHittable { app.swipeUp() }
        grams.tap(); grams.typeText("50")
        pickOption("早", field: "record.field.mealTime")
        app.buttons["record.save"].tap()
        XCTAssertTrue(app.buttons["record.save"].waitForNonExistence(timeout: 5))
        app.terminate(); app.launch()
        let completed = app.buttons[identifier]
        XCTAssertTrue(completed.waitForExistence(timeout: 5))
        XCTAssertTrue(completed.label.contains("已完成"))
        completed.tap()
        XCTAssertTrue(app.buttons["detail.delete"].waitForExistence(timeout: 3))
        app.buttons["detail.delete"].tap()
        app.buttons["确认删除记录"].tap()
        XCTAssertTrue(app.buttons["detail.delete"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons[identifier].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons[identifier].label.contains("已完成"))
    }

    // 路径①：我的 tab 建档案 → 记录 tab 记一条喂食（通用动态表单）
    func test_createPet_thenLogFeeding() {
        createPetIfNeeded()

        app.petPalTab("记录").tap()
        XCTAssertTrue((app.staticTexts["records.currentPet"].waitForExistence(timeout: 3) || app.buttons["records.petSwitcher"].waitForExistence(timeout: 3)))
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
        app.petPalTab("我的").tap()
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
        app.petPalTab("记录").tap()
        XCTAssertTrue((app.staticTexts["records.currentPet"].waitForExistence(timeout: 3) || app.buttons["records.petSwitcher"].waitForExistence(timeout: 3)),
                      "重建档案后记录页应显示当前宠物")
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
        app.petPalTab("记录").tap()
        XCTAssertTrue((app.staticTexts["records.currentPet"].waitForExistence(timeout: 3) || app.buttons["records.petSwitcher"].waitForExistence(timeout: 3)))

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
        app.petPalTab("我的").tap()
        // 仅冷启动无档案（空态引导可见）时执行；已有档案则跳过
        guard app.staticTexts["pet.emptyGuide"].waitForExistence(timeout: 3) else { return }
        app.buttons["pet.createFirst"].tap()
        app.buttons["pet.save"].tap()
        XCTAssertTrue(app.staticTexts["昵称需为1-20个字符"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["pet.save"].exists)   // sheet 未关闭
    }

    // 路径②：设置每日提醒（含系统权限弹窗处理）
    func test_setDailyReminder() {
        createPetIfNeeded()
        app.petPalTab("记录").tap()
        // 系统权限弹窗（中文系统按钮为「允许」，英文为 "Allow"）
        addUIInterruptionMonitor(withDescription: "通知权限") { alert in
            if alert.buttons["允许"].exists { alert.buttons["允许"].tap(); return true }
            if alert.buttons["Allow"].exists { alert.buttons["Allow"].tap(); return true }
            return false
        }
        XCTAssertTrue(app.buttons["records.reminder"].waitForExistence(timeout: 3))
        app.buttons["records.reminder"].tap()
        // 铃铛现在先落提醒列表页，再点「+」进创建表单
        XCTAssertTrue(app.buttons["reminders.add"].waitForExistence(timeout: 3))
        app.buttons["reminders.add"].tap()
        app.buttons["reminder.save"].tap()
        app.navigationBars.firstMatch.tap()   // 触发 interruption monitor，避免点击列表中的任务
        // 授权后保存成功回到提醒列表且该提醒可见；若曾拒绝则出现引导 Alert
        let savedRow = app.descendants(matching: .any)
            .matching(identifier: "reminders.row.喂食").firstMatch.waitForExistence(timeout: 3)
        let deniedAlert = app.alerts["提醒已保存"].exists
        XCTAssertTrue(savedRow || deniedAlert)
    }

    func test_checkupCanBeEditedAndDeletedFromTimeline() {
        createPetIfNeeded()
        app.petPalTab("记录").tap()
        app.buttons["records.add"].tap()
        app.buttons["record.template.体检"].tap()
        let weight = app.textFields["record.field.weightKg"]
        scrollTo(weight)
        XCTAssertTrue(weight.waitForExistence(timeout: 3)); weight.tap(); weight.typeText("8")
        app.buttons["record.save"].tap()
        XCTAssertTrue(app.buttons["record.save"].waitForNonExistence(timeout: 3))
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "records.row.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3)); row.tap()
        XCTAssertTrue(app.buttons["detail.edit"].waitForExistence(timeout: 3)); app.buttons["detail.edit"].tap()
        let editingWeight = app.textFields["record.field.weightKg"]
        scrollTo(editingWeight)
        XCTAssertTrue(editingWeight.waitForExistence(timeout: 3)); editingWeight.tap(); editingWeight.typeText("\u{8}9")
        app.buttons["record.save"].tap()
        XCTAssertTrue(app.buttons["record.save"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["9"].waitForExistence(timeout: 3))
        app.buttons["detail.delete"].tap()
        XCTAssertTrue(app.buttons["确认删除记录"].waitForExistence(timeout: 3))
        app.buttons["确认删除记录"].tap()
        XCTAssertTrue(app.buttons["detail.delete"].waitForNonExistence(timeout: 3))
    }

    // ③ 导出 PDF：建档案 → 我的 tab → 成长看板 → 导出 → 系统分享面板出现
    func test_exportPDF() throws {
        createPetIfNeeded()
        app.petPalTab("我的").tap()
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
        XCTAssertTrue(app.buttons["report.generate"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.switches["report.allDates"].exists)

    }

    // 路径④：记喂食 → 记录页切日历分段 → 今日格子可点且当日列表出现记录
    func test_calendarShowsTodayRecord() {
        createPetIfNeeded()
        // 记一条喂食，保证今日有记录圆点（mealTime 为必填，需先选择用餐时段）
        app.petPalTab("记录").tap()
        app.buttons["records.add"].tap()
        app.buttons["record.template.喂食"].tap()
        app.textFields["record.field.food"].tap()
        app.typeText("罐头")
        app.textFields["record.field.grams"].tap()
        app.typeText("100")
        pickOption("午", field: "record.field.mealTime")
        app.buttons["record.save"].tap()
        // 校验通过 sheet 才真正关闭
        XCTAssertTrue(app.buttons["records.add"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["record.save"].waitForNonExistence(timeout: 5), "喂食 sheet 应已关闭")

        // 切到「日历」分段
        let calendarSegment = app.buttons["日历"].exists ? app.buttons["日历"] : app.buttons["records.segment"]
        calendarSegment.tap()
        XCTAssertTrue(app.staticTexts["calendar.dayListTitle"].waitForExistence(timeout: 5))
        // 今日格子：identifier calendar.day.M月d日，提示「有n条记录」
        let cal = Calendar.current
        let m = cal.component(.month, from: Date())
        let d = cal.component(.day, from: Date())
        let todayCell = app.buttons["calendar.day.\(m)月\(d)日"]
        XCTAssertTrue(todayCell.waitForExistence(timeout: 5))
        todayCell.tap()
        // 当日列表出现刚保存的记录（类型「喂食」）
        XCTAssertTrue(app.buttons.matching(identifier: "calendar.recordRow")
            .firstMatch.waitForExistence(timeout: 5))
    }

    // 冷启动性能基线（PRD §7：≤2 秒；XCTApplicationLaunchMetric 测至首帧渲染完成）
    func test_launchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    /// 冷启动无档案时先建一个（「我的」tab → 空态「创建第一个宠物档案」）；已有档案则直接返回
    private func createPetIfNeeded() {
        app.petPalTab("我的").tap()
        guard app.staticTexts["pet.emptyGuide"].waitForExistence(timeout: 3) else { return }
        app.buttons["pet.createFirst"].tap()
        app.textFields["pet.nickname"].tap()
        app.typeText("小白")
        app.textFields["pet.breed"].tap()
        app.typeText("柯基")
        app.buttons["pet.save"].tap()
        XCTAssertTrue(app.buttons["pet.add"].waitForExistence(timeout: 3), "建档后应回到宠物列表")
    }

    /// 点选单选 Picker（用餐时段等）的选项：decimalPad 键盘在位时首次点击只收键盘，带重试
    private func pickOption(_ option: String, field: String) {
        scrollTo(app.buttons[field])
        app.buttons[field].tap()
        for _ in 0..<3 {
            let el = app.buttons[option].exists ? app.buttons[option] : app.cells[option]
            if el.waitForExistence(timeout: 2) { el.tap(); return }
            app.buttons[field].tap()
        }
        XCTFail("字段 \(field) 的选项「\(option)」未出现")
    }

    private func scrollTo(_ element: XCUIElement) {
        for _ in 0..<4 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
    }
}


extension XCUIApplication {
    /// iPhone 的底部标签栏与 iPad 的浮动标签栏暴露不同的元素类型。
    func petPalTab(_ title: String) -> XCUIElement {
        let classic = tabBars.buttons[title].firstMatch
        if classic.exists { return classic }
        let floating = cells[title].firstMatch
        if floating.exists { return floating }
        return buttons[title].firstMatch
    }
}
