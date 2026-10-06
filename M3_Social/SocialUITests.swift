import XCTest

// M3 信息流关键路径（信息流现为「首页动态」tab，冷启动即达）：
// ①首屏列表出现 → 点赞第一条 → 点赞数精确 +1 ②评论两级树 ③发布默认值与回显
final class SocialUITests: XCTestCase {
    private var app: XCUIApplication!
    private var interruptionToken: NSObjectProtocol?

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["PETPAL_UI_TEST_STORE_ID"] = UUID().uuidString
        // Springboard 残留弹窗兜底（如 Safari「添加到阅读列表」）：点取消类按钮消掉，避免遮挡后续事件
        interruptionToken = addUIInterruptionMonitor(withDescription: "Springboard 弹窗兜底") { alert in
            for title in ["不添加", "稍后", "取消", "Cancel", "Close"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
                return true
            }
            return false
        }
        dismissStaleSpringboardAlerts()
        app.launch()
    }

    override func tearDown() {
        if let interruptionToken { removeUIInterruptionMonitor(interruptionToken) }
    }

    /// 清掉模拟器上残留的 springboard 弹窗（跨测试运行会驻留，遮挡输入框命中）
    private func dismissStaleSpringboardAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for alert in springboard.alerts.allElementsBoundByIndex {
            for title in ["不添加", "稍后", "取消", "Cancel", "Close"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
            }
        }
    }

    /// 带重试的聚焦输入：新推入页面的 TextEditor 首点可能落到 push 动画瞬态或
    /// 被弹窗遮挡（hit point 失效），以「键盘真正弹出」为准重试
    private func typeInto(_ element: XCUIElement, text: String) {
        var focused = false
        for _ in 0..<5 where !focused {
            element.tap()
            focused = app.keyboards.firstMatch.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(focused, "输入框应获得键盘焦点")
        app.typeText(text)
    }

    /// 点赞数以按钮 a11y label「点赞，当前N次赞」暴露（iOS 27 下父 Button 的
    /// accessibilityIdentifier 会覆盖子 StaticText 的 identifier，故不单独锚定计数文本）
    private func likeCount(_ index: Int) -> Int? {
        let digits = app.buttons["feed.like.\(index)"].label.filter { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// 万能 identifier 查询：SwiftUI 自定义视图（Chart、TextEditor、Picker 等）的无障碍
    /// 元素类型随 iOS 版本漂移，统一走 descendants 按 identifier 收敛，避免猜元素类型
    private func a11y(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// 导航返回按钮：identifier 随 iOS 版本/系统语言漂移（"Back"/"BackButton"/"返回"），
    /// 统一按位置锚定导航栏第一个按钮（本地 iOS 26 与 CI runner 实测不一致，2026-09）
    private var navBackButton: XCUIElement {
        app.navigationBars.firstMatch.buttons.firstMatch
    }

    /// 冷启动无档案时先建一个（「我的」tab → 空态创建），建完回到首页动态 tab
    private func createPetIfNeeded() {
        app.tabBars.buttons["我的"].tap()
        guard app.staticTexts["pet.emptyGuide"].waitForExistence(timeout: 3) else {
            app.tabBars.buttons["首页动态"].tap()
            return
        }
        app.buttons["pet.createFirst"].tap()
        app.textFields["pet.nickname"].tap()
        app.typeText("小白")
        app.textFields["pet.breed"].tap()
        app.typeText("柯基")
        app.buttons["pet.save"].tap()
        XCTAssertTrue(app.buttons["pet.add"].waitForExistence(timeout: 3), "建档后应回到宠物列表")
        app.tabBars.buttons["首页动态"].tap()
    }

    /// 信息流即首页 tab，冷启动首帧后首条动态应已加载（Mock 无网络延迟）
    private func openFeed() {
        XCTAssertTrue(app.buttons["feed.like.0"].waitForExistence(timeout: 5), "信息流应打开且首条动态可见")
    }

    func test_feed_likeFirstPost_incrementsCount() {
        createPetIfNeeded()
        openFeed()
        // 首条动态作者锚点可见（List 懒加载，离屏行不进无障碍树，故断言可见首行而非全量 20 条）
        XCTAssertTrue(app.staticTexts["feed.author.0"].waitForExistence(timeout: 3))

        guard let before = likeCount(0) else { XCTFail("无法解析首条点赞数"); return }
        app.buttons["feed.like.0"].tap()
        // toggleLike 无网络延迟、同步发射；轮询等待计数变化（Mock 150ms 内必达）
        var after = before
        for _ in 0..<30 where after == before {
            usleep(100_000)
            after = likeCount(0) ?? before
        }
        XCTAssertEqual(after, before + 1, "点赞后计数应精确 +1")
    }

    // 评论页关键路径：种子评论可见 → 超长截断(510→500)并发一级评论 → 回复一级发二级 → 二级无回复按钮
    func test_comment_firstAndSecondLevel_flow() {
        createPetIfNeeded()
        openFeed()

        XCTAssertTrue(app.buttons["feed.comment.0"].waitForExistence(timeout: 5))
        app.buttons["feed.comment.0"].tap()
        let input = a11y("comment.input")
        XCTAssertTrue(input.waitForExistence(timeout: 5), "应进入评论页")

        // Mock 种子：前 3 条动态各 2 条一级 + 1 条二级（挂在「好可爱！」下）
        XCTAssertTrue(app.staticTexts["好可爱！"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["求同款粮"].exists)
        XCTAssertTrue(app.staticTexts["谢谢喜欢～"].exists)

        // ① 发一条普通一级评论；发送后返回信息流再进评论页（顺带验证评论跨页持久），
        // 此时键盘收起、列表在顶部，新行在首屏内可直接断言
        typeInto(input, text: "UI自动化一级评论")
        app.buttons["comment.send"].tap()
        XCTAssertTrue(navBackButton.waitForExistence(timeout: 3))
        navBackButton.tap()
        XCTAssertTrue(app.buttons["feed.comment.0"].waitForExistence(timeout: 5))
        app.buttons["feed.comment.0"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["UI自动化一级评论"].waitForExistence(timeout: 3),
                      "新一级评论应出现在评论列表")

        // ② ≤500 字拦截：510 字被截到 500 并给出提示；截断后（恰好 500 字）可成功提交。
        // 注：500 字单行极高，落在新行列表底部，其单元格不在首屏内（List 懒加载），
        // 故只断言提交被接受（草稿清空），可见性不在此断言
        let longText = "截" + String(repeating: "字", count: 509)   // 510 字
        typeInto(input, text: longText)
        XCTAssertTrue(app.staticTexts["comment.lengthHint"].waitForExistence(timeout: 3),
                      "超长输入应出现截断提示")
        XCTAssertEqual(app.staticTexts["comment.length"].label, "500/500")
        app.buttons["comment.send"].tap()
        // 发送成功 = 草稿被清空（仅成功路径会清 draft）；Mock 无延迟，轮询一次即可
        var lengthLabel = ""
        for _ in 0..<30 where lengthLabel != "0/500" {
            usleep(100_000)
            lengthLabel = app.staticTexts["comment.length"].label
        }
        XCTAssertEqual(lengthLabel, "0/500", "恰好 500 字应能提交成功（输入框被清空）")

        // ③ 对一级评论「好可爱！」（comment.reply.0）点回复，发一条二级
        XCTAssertTrue(app.buttons["comment.reply.0"].waitForExistence(timeout: 3))
        app.buttons["comment.reply.0"].tap()
        XCTAssertTrue(app.buttons["comment.cancelReply"].waitForExistence(timeout: 2),
                      "选中回复目标后应出现「取消回复」")
        typeInto(input, text: "UI自动化二级回复")
        app.buttons["comment.send"].tap()
        XCTAssertTrue(app.staticTexts["UI自动化二级回复"].waitForExistence(timeout: 3),
                      "二级评论应出现在列表")

        // ④ 二级评论行内不应有回复按钮（逐行断言，不依赖离屏行的懒加载渲染）；
        // 一级评论有回复按钮作对照
        for childText in ["谢谢喜欢～", "UI自动化二级回复"] {
            let cell = app.cells.containing(NSPredicate(format: "label CONTAINS %@", childText)).firstMatch
            XCTAssertTrue(cell.waitForExistence(timeout: 3), "二级评论「\(childText)」应在列表中")
            XCTAssertFalse(cell.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'comment.reply.'")).firstMatch.exists,
                           "二级评论「\(childText)」不应出现回复按钮")
        }
        XCTAssertTrue(app.buttons["comment.reply.0"].exists, "一级评论应有回复按钮（对照）")
    }

    // 消息跳转：评论/回复类消息 → 评论区并定位目标评论；动态类消息 → 该动态评论区
    func test_tapMessage_opensLinkedPostAndComment() {
        app.tabBars.buttons["消息"].tap()

        // 回复类消息（宠友7 回复了你的评论「求同款粮」）→ 评论区定位到该评论
        let replyRow = a11y("message.row.4")
        XCTAssertTrue(replyRow.waitForExistence(timeout: 3), "消息列表应展示演示消息")
        replyRow.tap()
        XCTAssertTrue(a11y("comment.input").waitForExistence(timeout: 5), "应进入对应动态的评论区")
        XCTAssertTrue(app.staticTexts["求同款粮"].waitForExistence(timeout: 3),
                      "回复目标评论应定位可见")

        // 动态类消息（宠友12 赞了你的动态）→ 该动态的评论区
        navBackButton.tap()
        let likeRow = a11y("message.row.0")
        XCTAssertTrue(likeRow.waitForExistence(timeout: 3))
        likeRow.tap()
        XCTAssertTrue(a11y("comment.input").waitForExistence(timeout: 5),
                      "动态类消息应进入该动态的评论区")
        XCTAssertTrue(app.staticTexts["好可爱！"].waitForExistence(timeout: 3))
    }

    // 发布关键路径：信息流 → feed.publish → 填文本（宠物默认当前宠物、可见性默认仅粉丝）→ 发布后顶部可见
    func test_publish_appearsOnTopOfFeed() {
        createPetIfNeeded()
        // 当前宠物昵称从记录页头部读取，用于断言发布表单的默认选中
        app.tabBars.buttons["记录"].tap()
        let currentPetText = app.staticTexts["records.currentPet"]
        XCTAssertTrue(currentPetText.waitForExistence(timeout: 3))
        let nickname = currentPetText.label.components(separatedBy: "：").last ?? ""
        app.tabBars.buttons["首页动态"].tap()

        openFeed()
        XCTAssertTrue(app.buttons["feed.publish"].waitForExistence(timeout: 5))
        app.buttons["feed.publish"].tap()

        let textView = a11y("publish.text")
        XCTAssertTrue(textView.waitForExistence(timeout: 5), "应进入发布表单")
        let content = "UI发布走查\(Int(Date().timeIntervalSince1970))"
        typeInto(textView, text: content)

        // 宠物选择：默认选中当前宠物（必选项，无档案时表单显示 publish.noPet 且发布禁用）。
        // menu 风格 Picker 的 a11y value 不暴露选中项，打开菜单验证默认勾选；点回默认项关闭菜单
        let petPicker = a11y("publish.pet")
        XCTAssertTrue(petPicker.waitForExistence(timeout: 3))
        if !nickname.isEmpty {
            petPicker.tap()
            let petOption = app.buttons[nickname].firstMatch
            XCTAssertTrue(petOption.waitForExistence(timeout: 3))
            XCTAssertTrue(petOption.isSelected, "宠物应默认勾选当前宠物「\(nickname)」")
            petOption.tap()
        }
        // 可见性默认值：仅粉丝（Visibility.default = .followersOnly）
        let visibilityPicker = a11y("publish.visibility")
        XCTAssertTrue(visibilityPicker.waitForExistence(timeout: 3))
        visibilityPicker.tap()
        let followersOption = app.buttons["仅粉丝"].firstMatch
        XCTAssertTrue(followersOption.waitForExistence(timeout: 3))
        XCTAssertTrue(followersOption.isSelected, "可见范围应默认勾选「仅粉丝」")
        followersOption.tap()

        // 文本 + 默认宠物就绪后「发布」才可用（onReceive 异步选中，轮询等待）
        let submit = app.buttons["publish.submit"]
        var ready = submit.isEnabled
        for _ in 0..<30 where !ready {
            usleep(100_000)
            ready = submit.isEnabled
        }
        XCTAssertTrue(ready, "填写文本且宠物默认选中后发布按钮应可用")
        submit.tap()

        // Mock 将新动态插到首位，pop 回信息流后顶部即见（publish 有 150ms 模拟延迟）
        XCTAssertTrue(app.staticTexts[content].waitForExistence(timeout: 5), "新发布的动态应出现在信息流顶部")
    }
}
