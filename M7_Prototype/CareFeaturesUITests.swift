import XCTest

/// Each flow uses an isolated, in-memory demo store and the real SwiftUI screens.
final class CareFeaturesUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--petpal-preview", "demo", "--reset-onboarding",
                               "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["today.addRecord"].waitForExistence(timeout: 5))
    }

    func test_namedWalkingFavorite_cancelDoesNotCreateRecord_thenSaveAndSearch() {
        let name = "傍晚公园快捷"
        let place = "UI快捷核对湖畔路线"
        tap(app.buttons["today.manageQuickActions"])
        tap(app.buttons["quickActions.add.遛弯"])
        replaceText("quickActions.name", with: name)
        replaceText("quickActions.field.minutes", with: "27")
        replaceText("quickActions.field.place", with: place)
        dismissKeyboard()
        tap(app.buttons["quickActions.save"])
        XCTAssertTrue(app.buttons["quickActions.save"].waitForNonExistence(timeout: 3))
        tap(app.navigationBars["常用快捷"].buttons["完成"])

        let favorite = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "today.quick.", name)).firstMatch
        tap(favorite)
        XCTAssertTrue(app.buttons["record.save"].waitForExistence(timeout: 3))
        assertText("record.field.minutes", equals: "27")
        assertText("record.field.place", equals: place)
        capture("01-prefilled-walking-draft")
        tap(app.buttons["取消"])
        XCTAssertTrue(app.buttons["record.save"].waitForNonExistence(timeout: 3))

        app.petPalTab("记录").tap()
        replaceText("records.search", with: place)
        dismissKeyboard()
        XCTAssertTrue(app.staticTexts["records.search.count"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["records.search.count"].label, "0条结果 · 奶糖", "取消预填草稿不能创建事件")
        XCTAssertTrue(element("records.search.empty").exists)
        tap(app.buttons["records.filter.reset"])

        app.petPalTab("今日").tap()
        tap(favorite)
        assertText("record.field.place", equals: place)
        tap(app.buttons["record.save"])
        XCTAssertTrue(app.buttons["record.save"].waitForNonExistence(timeout: 5), "只有显式保存才提交新记录")
        app.petPalTab("记录").tap()
        replaceText("records.search", with: place)
        dismissKeyboard()
        XCTAssertTrue(app.staticTexts["records.search.count"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["records.search.count"].label, "1条结果 · 奶糖")
        let result = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "records.row.")).firstMatch
        XCTAssertTrue(result.exists)
        XCTAssertTrue(result.label.contains(place), "结果摘要应包含已保存的快捷内容")
        capture("02-saved-walking-search-result")
        tap(app.buttons["records.filter.reset"])
        XCTAssertTrue(app.buttons["records.filter.reset"].waitForNonExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["records.search.count"].exists)
        let searchValue = element("records.search").value as? String ?? ""
        XCTAssertTrue(searchValue.isEmpty || searchValue == "搜索类型、模板、内容或备注")
    }

    func test_medicalFolderImportCancel_andSelectiveCareCardPDFShare() {
        app.petPalTab("我的").tap()
        tap(app.buttons["profile.medicalDocuments"])
        XCTAssertTrue(app.navigationBars["医疗资料 · 奶糖"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["还没有医疗资料，点右上角 + 从文件导入。"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "仅显示 奶糖 的资料")).firstMatch.exists)
        capture("03-current-pet-medical-folder-empty")
        tap(app.buttons["medical.import"])
        // Exercise the real document picker. Real-file validation belongs to importer unit tests;
        // UI automation cannot provision a Files/iCloud provider document reliably on every device.
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 20), "应打开系统文件选择器并允许取消")
        cancel.tap()
        XCTAssertTrue(app.buttons["medical.import"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["medical.save"].exists)
        XCTAssertTrue(app.staticTexts["还没有医疗资料，点右上角 + 从文件导入。"].exists)
        tap(app.navigationBars["医疗资料 · 奶糖"].buttons["完成"])

        tap(app.buttons["profile.careInstructions"])
        replaceText("care.diet", with: "UI交接早餐：按主人准备的份量喂食")
        replaceText("care.daily", with: "UI交接日常：傍晚牵绳遛弯")
        replaceText("care.contacts", with: "UI紧急联系人：主人")
        dismissKeyboard()
        tap(app.buttons["care.save"])
        XCTAssertTrue(app.staticTexts["已保存"].waitForExistence(timeout: 3))
        tap(app.navigationBars["照护交接卡"].buttons["完成"])
        tap(app.buttons["profile.careInstructions"])
        assertText("care.diet", equals: "UI交接早餐：按主人准备的份量喂食")
        tap(app.buttons["care.export"])
        XCTAssertTrue(app.navigationBars["预览交接卡范围"].waitForExistence(timeout: 3))
        setSwitch("care.includeAllergies", on: true)
        setSwitch("care.includeMedication", on: false)
        setSwitch("care.includeVet", on: false)
        reveal(app.staticTexts["鸡肉、花粉"])
        XCTAssertTrue(app.staticTexts["鸡肉、花粉"].exists, "主动选择的当前宠物过敏信息应出现在范围预览")
        XCTAssertFalse(app.staticTexts["用药安排（主人记录）"].exists)
        XCTAssertFalse(app.staticTexts["当前没有进行中的用药疗程。"].exists)
        capture("04-selected-care-card-export-scope")
        tap(app.buttons["care.generate"])
        XCTAssertTrue(app.navigationBars["照护交接卡 · 奶糖"].waitForExistence(timeout: 8), "生成后应先打开 PDF 原件预览")
        XCTAssertTrue(element("care.document.pdf").waitForExistence(timeout: 5), "PDF 应加载为可阅读的原件预览")
        XCTAssertTrue(app.buttons["care.document.share"].exists)
        capture("05-generated-care-card-pdf-preview")
        tap(app.buttons["care.document.share"])
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 5), "预览页应打开系统分享面板")
        capture("06-care-card-system-share")
    }

    func test_medicationCourse_pauseResumeAndExplicitSkippedDose() {
        let drug = "UI日常照护疗程"
        let instructions = "按主人已有安排填写单次用量；随餐记录"
        app.petPalTab("记录").tap()
        tap(app.buttons["records.reminder"])
        tap(app.buttons["reminders.courses"])
        XCTAssertTrue(app.navigationBars["奶糖的用药疗程"].waitForExistence(timeout: 3))
        tap(app.buttons["courses.add"])
        replaceText("course.drug", with: drug)
        replaceText("course.instructions", with: instructions)
        dismissKeyboard()
        tap(app.buttons["course.save"])
        XCTAssertTrue(app.buttons["course.save"].waitForNonExistence(timeout: 8))
        tap(courseRow(drug))
        XCTAssertTrue(app.navigationBars[drug].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", instructions)).firstMatch.exists)
        tap(app.buttons["暂停疗程"])
        XCTAssertTrue(app.buttons["恢复疗程"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["已暂停"].exists)
        capture("07-paused-medication-course")
        tap(app.buttons["恢复疗程"])
        XCTAssertTrue(app.buttons["暂停疗程"].waitForExistence(timeout: 5))
        tap(app.navigationBars[drug].buttons["完成"])
        tap(app.navigationBars["奶糖的用药疗程"].buttons["完成"])

        let task = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "tasks.row.", drug)).firstMatch
        reveal(task)
        let taskIdentifier = task.identifier
        tap(task)
        XCTAssertTrue(app.buttons["course.skipDose"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", instructions)).firstMatch.exists)
        tap(app.buttons["course.skipDose"])
        XCTAssertTrue(app.buttons["course.skipDose"].waitForNonExistence(timeout: 5))
        let skipped = app.buttons[taskIdentifier]
        reveal(skipped)
        XCTAssertTrue(skipped.label.contains("已跳过（未服药）"), "跳过应明确标明未服药，不能当作实际服药完成")
        capture("08-explicitly-skipped-medication-task")
        tap(app.buttons["reminders.courses"])
        tap(courseRow(drug))
        let history = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "已跳过（未服药）", "未服药（已跳过）")).firstMatch
        reveal(history)
        XCTAssertTrue(history.exists)
        XCTAssertFalse(app.staticTexts["实际服药记录"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "skipped")).firstMatch.exists,
                       "记录摘要不应显示内部英文状态")
        capture("09-medication-course-skipped-history")
    }

    func test_medicationCourse_actualDoseCancelThenSaveCompletesTaskAndHistory() {
        let courseDrug = "UI实际服药疗程"
        let actualDrug = "UI实际服药药品"
        let actualDose = "0.5片（测试记录）"
        app.petPalTab("记录").tap()
        tap(app.buttons["records.reminder"])
        tap(app.buttons["reminders.courses"])
        tap(app.buttons["courses.add"])
        replaceText("course.drug", with: courseDrug)
        replaceText("course.instructions", with: "按主人已确认的安排记录本次实际服药")
        dismissKeyboard()
        tap(app.buttons["course.save"])
        XCTAssertTrue(app.buttons["course.save"].waitForNonExistence(timeout: 8))
        XCTAssertTrue(courseRow(courseDrug).waitForExistence(timeout: 3))
        tap(app.navigationBars["奶糖的用药疗程"].buttons["完成"])

        let task = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "tasks.row.", courseDrug)).firstMatch
        reveal(task)
        let taskIdentifier = task.identifier
        XCTAssertFalse(task.label.contains("已完成"))
        tap(task)
        tap(app.buttons["course.recordDose"])
        XCTAssertTrue(app.buttons["record.save"].waitForExistence(timeout: 3))
        tap(app.buttons["取消"])
        XCTAssertTrue(app.buttons["record.save"].waitForNonExistence(timeout: 5), "取消实际服药表单应关闭本次待办 sheet")
        XCTAssertFalse(app.buttons["course.recordDose"].exists)
        let cancelledTask = app.buttons[taskIdentifier]
        reveal(cancelledTask)
        XCTAssertFalse(cancelledTask.label.contains("已完成"), "取消表单不能提前完成服药待办")
        XCTAssertFalse(cancelledTask.label.contains("已跳过"), "取消表单也不能生成跳过记录")

        tap(cancelledTask)
        tap(app.buttons["course.recordDose"])
        XCTAssertTrue(app.buttons["record.save"].waitForExistence(timeout: 3))
        replaceText("record.field.drug", with: actualDrug)
        replaceText("record.field.dose", with: actualDose)
        dismissKeyboard()
        capture("10-actual-medication-dose-before-save")
        tap(app.buttons["record.save"])
        XCTAssertTrue(app.buttons["record.save"].waitForNonExistence(timeout: 5), "保存实际服药应关闭表单及本次待办 sheet")
        XCTAssertFalse(app.buttons["course.recordDose"].exists)
        let completedTask = app.buttons[taskIdentifier]
        reveal(completedTask)
        let completion = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "已完成"), object: completedTask)
        XCTAssertEqual(XCTWaiter.wait(for: [completion], timeout: 5), .completed, "显式保存后同一待办应显示已完成")
        XCTAssertFalse(completedTask.label.contains("已跳过"))
        capture("11-actual-medication-task-completed")

        tap(app.buttons["reminders.courses"])
        tap(courseRow(courseDrug))
        reveal(app.staticTexts["实际服药记录"])
        XCTAssertTrue(app.staticTexts["实际服药记录"].exists)
        XCTAssertTrue(app.staticTexts[actualDose].exists, "疗程历史应保留主人填写的实际用量")
        XCTAssertFalse(app.staticTexts["已跳过（未服药）"].exists)
        capture("12-actual-medication-course-history")
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func courseRow(_ drug: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "courses.row.", drug)).firstMatch
    }

    private func replaceText(_ identifier: String, with text: String, file: StaticString = #filePath, line: UInt = #line) {
        let field = element(identifier)
        reveal(field, file: file, line: line)
        field.tap()
        // Empty fields expose their placeholder as value; only erase actual text.
        let existing = field.value as? String ?? ""
        let placeholder = field.placeholderValue ?? ""
        if !existing.isEmpty && existing != placeholder {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        field.typeText(text)
    }

    private func assertText(_ identifier: String, equals text: String, file: StaticString = #filePath, line: UInt = #line) {
        let field = element(identifier)
        reveal(field, file: file, line: line)
        XCTAssertEqual(field.value as? String, text, file: file, line: line)
    }

    private func dismissKeyboard() {
        guard app.keyboards.firstMatch.exists, app.keyboards.firstMatch.frame.height > 0 else { return }
        // Tapping the navigation title avoids activating a form's Save/Cancel button.
        let bar = app.navigationBars.allElementsBoundByIndex.last(where: { $0.isHittable })
        if let bar { bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        if app.keyboards.firstMatch.exists {
            let done = app.keyboards.buttons.matching(NSPredicate(format: "label IN %@", ["完成", "Done", "搜索", "Search", "return"])).firstMatch
            if done.exists && done.isHittable { done.tap() }
        }
    }

    private func setSwitch(_ identifier: String, on expected: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let wrapper = app.switches[identifier]
        reveal(wrapper, file: file, line: line)
        let control = wrapper.switches.firstMatch.exists ? wrapper.switches.firstMatch : wrapper
        if (control.value as? String == "1") != expected { control.tap() }
        XCTAssertEqual(control.value as? String, expected ? "1" : "0", file: file, line: line)
    }

    private func tap(_ target: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        reveal(target, file: file, line: line)
        XCTAssertTrue(target.isEnabled, file: file, line: line)
        target.tap()
    }

    /// Scroll the active content in small steps until the requested element is visible.
    /// Bounded by the element, the navigation bar and keyboard, on iPhone and iPad alike.
    private func reveal(_ target: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<18 {
            if target.exists && target.isHittable { return }
            let surfaces = app.collectionViews.allElementsBoundByIndex + app.tables.allElementsBoundByIndex + app.scrollViews.allElementsBoundByIndex
            guard let surface = surfaces.last(where: { $0.isHittable && $0.frame.height > 100 }) else {
                if target.waitForExistence(timeout: 3) && target.isHittable { return }
                break
            }
            let navBottom = app.navigationBars.allElementsBoundByIndex.filter { $0.isHittable }.map { $0.frame.maxY }.max() ?? surface.frame.minY
            let top = max(surface.frame.minY, navBottom) + 16
            let keyboard = app.keyboards.firstMatch
            let bottom = min(surface.frame.maxY - 40, keyboard.exists ? keyboard.frame.minY - 80 : surface.frame.maxY - 40)
            guard bottom - top > 80 else { dismissKeyboard(); continue }
            let downward = target.exists && target.frame.midY < top
            let startY = top + (bottom - top) * (downward ? 0.3 : 0.75)
            let distance = min(160, (bottom - top) * 0.35)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: surface.frame.maxX - 24, dy: startY))
            let end = origin.withOffset(CGVector(dx: surface.frame.maxX - 24, dy: startY + (downward ? distance : -distance)))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(target.waitForExistence(timeout: 3) && target.isHittable, "限定滚动后应能操作目标：\(target)", file: file, line: line)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "care-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
