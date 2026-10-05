import XCTest
import UserNotifications
@testable import PetPal

// MARK: - Mock 调度器（替代 UNUserNotificationCenter）
final class MockNotificationScheduler: NotificationScheduling {
    var authorized = true
    var status: UNAuthorizationStatus?
    var authorizationError: Error?
    var authorizationRequests = 0
    var failNextAdd = false
    var removalDelay: UInt64 = 0
    private(set) var isRemoving = false
    private(set) var addedDuringRemoval = false
    var added: [UNNotificationRequest] = []
    var removedPrefixes: [String] = []
    func requestAuthorization() async throws -> Bool {
        authorizationRequests += 1
        if let authorizationError { throw authorizationError }
        status = authorized ? .authorized : .denied
        return authorized
    }
    func authorizationStatus() async -> UNAuthorizationStatus { status ?? (authorized ? .authorized : .denied) }
    func pendingRequests() async -> [UNNotificationRequest] { added }
    func add(_ request: UNNotificationRequest) async throws {
        if isRemoving { addedDuringRemoval = true }
        if failNextAdd { failNextAdd = false; throw CocoaError(.fileWriteUnknown) }
        added.removeAll { $0.identifier == request.identifier }
        added.append(request)
    }
    func removePending(matchingPrefix prefix: String) async {
        isRemoving = true
        defer { isRemoving = false }
        if removalDelay > 0 { try? await Task.sleep(nanoseconds: removalDelay) }
        removedPrefixes.append(prefix)
        added.removeAll { $0.identifier.hasPrefix(prefix) }
    }
}

final class ReminderContentBuilderTests: XCTestCase {
    func test_bodyContainsPetNickname() {
        let c = ReminderContentBuilder.content(type: .feeding, petName: "小白",
                                               reminderID: UUID(), petID: UUID())
        XCTAssertEqual(c.body, "该给【小白】喂食了")
        XCTAssertEqual(c.userInfo["route"] as? String, "reminder")
    }
    func test_vaccineUsesProperAction() {
        let c = ReminderContentBuilder.content(type: .vaccine, petName: "豆豆",
                                               reminderID: UUID(), petID: UUID())
        XCTAssertTrue(c.body.contains("接种疫苗"))
    }
}

final class ReminderTriggerBuilderTests: XCTestCase {
    func test_daily_isRepeatingWithTime() {
        let t = ReminderTriggerBuilder.triggers(rule: .daily, hour: 8, minute: 30)
        XCTAssertEqual(t.count, 1)
        XCTAssertTrue(t[0].repeats)
        XCTAssertEqual(t[0].dateComponents.hour, 8)
        XCTAssertEqual(t[0].dateComponents.minute, 30)
    }
    func test_weeklyMultiSelect_yieldsOneTriggerPerDay() {
        let t = ReminderTriggerBuilder.triggers(rule: .weekly([2, 4, 6]), hour: 9, minute: 0)
        XCTAssertEqual(t.count, 3)
        XCTAssertEqual(t.map(\.dateComponents.weekday), [2, 4, 6])
    }
}

// MARK: - 提前量（波4新增）
final class AdvanceTriggerTests: XCTestCase {
    func test_advanceContent_containsNicknameAndLabel() {
        let c = ReminderContentBuilder.advanceContent(type: .vaccine, petName: "小白",
                                                      advance: .d1, reminderID: UUID(), petID: UUID())
        XCTAssertTrue(c.body.contains("【小白】"))
        XCTAssertTrue(c.body.contains("提前1天"))
    }
    func test_noneAdvance_yieldsNoTriggers() {
        XCTAssertTrue(ReminderTriggerBuilder.advanceTriggers(rule: .daily, hour: 8, minute: 0,
                                                             advance: .none).isEmpty)
    }
    func test_dailyAdvance15m_shiftsTimeBack() {
        let t = ReminderTriggerBuilder.advanceTriggers(rule: .daily, hour: 8, minute: 0, advance: .m15)
        XCTAssertEqual(t.count, 1)
        XCTAssertEqual(t[0].dateComponents.hour, 7)
        XCTAssertEqual(t[0].dateComponents.minute, 45)
        XCTAssertTrue(t[0].repeats)
    }
    func test_weeklyAdvance1Day_shiftsWeekdayBack() {
        let t = ReminderTriggerBuilder.advanceTriggers(rule: .weekly([2, 4]), hour: 9,
                                                       minute: 0, advance: .d1)
        XCTAssertEqual(t.count, 2)
        XCTAssertEqual(Set(t.compactMap(\.dateComponents.weekday)), [1, 3])   // 周一/三 ← 周二/四
    }
    func test_yearlyAdvance_wrapsMonthDay() {
        // 3月1日 提前3天 → 2月26日（2026 非闰年）
        let t = ReminderTriggerBuilder.advanceTriggers(rule: .yearly(month: 3, day: 1),
                                                       hour: 9, minute: 0, advance: .d3,
                                                       now: Date(timeIntervalSince1970: 1_767_225_600),
                                                       occurrenceCount: 1)
        XCTAssertEqual(t.count, 1)
        XCTAssertEqual(t[0].dateComponents.month, 2)
        XCTAssertEqual(t[0].dateComponents.day, 26)
    }
    @MainActor func test_saveWithAdvance_schedulesBothTriggerGroups() async throws {
        let repo = CoreDataReminderRepository(stack: CoreDataStack(inMemory: true))
        let scheduler = MockNotificationScheduler()
        let service = ReminderService(repo: repo, scheduler: scheduler)
        try await service.requestPermission()
        var r = Reminder(petID: UUID(), type: .feeding, hour: 8, minute: 0)
        r.advance = .m30
        try await service.save(r, petName: "小白")
        XCTAssertEqual(scheduler.added.count, 2)   // 1 主触发 + 1 提前触发
        XCTAssertTrue(scheduler.added.contains { $0.identifier.contains("#adv#") })
        XCTAssertEqual(scheduler.added.first { $0.identifier.contains("#adv#") }?
            .content.body, "提前30分钟：该给【小白】喂食了")
    }
}

final class ReminderServiceTests: XCTestCase {
    private var repo: CoreDataReminderRepository!
    private var scheduler: MockNotificationScheduler!
    private var service: ReminderService!

    @MainActor override func setUp() {
        repo = CoreDataReminderRepository(stack: CoreDataStack(inMemory: true))
        scheduler = MockNotificationScheduler()
        service = ReminderService(repo: repo, scheduler: scheduler)
    }

    @MainActor func test_deniedPermission_schedulesNothing() async throws {
        scheduler.authorized = false
        try await service.requestPermission()
        try await service.save(Reminder(petID: UUID(), type: .feeding, hour: 8, minute: 0), petName: "小白")
        XCTAssertEqual(service.permission, .denied)
        XCTAssertTrue(scheduler.added.isEmpty)
    }
    // M-03：权限被拒时提醒配置仍落库（配置与送达解耦，不再静默丢失）
    @MainActor func test_deniedPermission_stillPersists() async throws {
        scheduler.authorized = false
        try await service.requestPermission()
        let pet = UUID()
        try await service.save(Reminder(petID: pet, type: .feeding, hour: 8, minute: 0), petName: "小白")
        XCTAssertEqual(try repo.reminders(petID: pet).count, 1)
        XCTAssertTrue(scheduler.added.isEmpty)
    }
    // M-06：时区变更后全量重排——撤销旧调度并按库中配置重建
    @MainActor func test_rescheduleAll_rebuildsFromStore() async throws {
        try await service.requestPermission()
        let pet = UUID()
        try await service.save(Reminder(petID: pet, type: .medication, hour: 21, minute: 0), petName: "小白")
        XCTAssertEqual(scheduler.added.count, 1)
        scheduler.added.removeAll(); scheduler.removedPrefixes.removeAll()
        await service.rescheduleAll()
        XCTAssertEqual(scheduler.added.count, 1, "重排后应恢复 1 条调度")
        XCTAssertEqual(scheduler.removedPrefixes.count, 1, "重排前应先撤销旧调度")
        XCTAssertEqual(scheduler.added.first?.content.body, "该给【小白】服药了",
                       "重排应使用落库的宠物昵称重建通知正文")
    }
    // M-06：权限被拒时重排为空操作（权限回补后再触发）
    @MainActor func test_rescheduleAll_whenDenied_isNoOp() async throws {
        scheduler.authorized = false
        try await service.requestPermission()
        let pet = UUID()
        try await service.save(Reminder(petID: pet, type: .feeding, hour: 8, minute: 0), petName: "小白")
        await service.rescheduleAll()
        XCTAssertTrue(scheduler.added.isEmpty)
    }
    @MainActor func test_save_schedulesAndPersists() async throws {
        try await service.requestPermission()
        let pet = UUID()
        try await service.save(Reminder(petID: pet, type: .medication, hour: 21, minute: 0), petName: "小白")
        XCTAssertEqual(scheduler.added.count, 1)
        XCTAssertEqual(try repo.reminders(petID: pet).count, 1)
    }
    @MainActor func test_removeAll_cancelsAndDeletes() async throws {
        try await service.requestPermission()
        let pet = UUID()
        let reminder = Reminder(petID: pet, type: .feeding, hour: 8, minute: 0)
        try await service.save(reminder, petName: "小白")
        try await service.removeAll(petID: pet)
        XCTAssertTrue(scheduler.added.isEmpty)
        XCTAssertTrue(scheduler.removedPrefixes.contains(reminder.id.uuidString + "#"),
                      "removeAll 必须按提醒 id 前缀撤销 pending 通知")
        XCTAssertTrue(try repo.reminders(petID: pet).isEmpty)
    }
}

final class ReminderReliabilityTests: XCTestCase {
    @MainActor func test_foregroundReconcile_recoversPermissionWithoutAnotherPrompt() async throws {
        let repo = CoreDataReminderRepository(stack: CoreDataStack(inMemory: true))
        let scheduler = MockNotificationScheduler()
        scheduler.authorized = false
        let service = ReminderService(repo: repo, scheduler: scheduler)
        let reminder = Reminder(petID: UUID(), type: .feeding, hour: 8, minute: 0)
        try await service.save(reminder, petName: "小白")
        XCTAssertTrue(scheduler.added.isEmpty)
        scheduler.authorized = true   // 用户在设置中开启通知
        await service.rescheduleAll()
        XCTAssertEqual(service.permission, .granted)
        XCTAssertEqual(scheduler.authorizationRequests, 0)
        XCTAssertEqual(scheduler.added.count, 1)
        XCTAssertNil(service.errorMessage)
    }

    @MainActor func test_coldLaunchReconcile_readsSystemPermission() async throws {
        let repo = CoreDataReminderRepository(stack: CoreDataStack(inMemory: true))
        try repo.save(Reminder(petID: UUID(), petName: "豆豆", type: .medication, hour: 21, minute: 0))
        let scheduler = MockNotificationScheduler()
        let service = ReminderService(repo: repo, scheduler: scheduler)
        XCTAssertEqual(service.permission, .unknown)
        await service.rescheduleAll()
        XCTAssertEqual(scheduler.added.count, 1)
        XCTAssertTrue(scheduler.added[0].content.body.contains("豆豆"))
    }

    @MainActor func test_delayedRemoval_finishesBeforeAdd_evenDuringForegroundReconcile() async throws {
        let repo = CoreDataReminderRepository(stack: CoreDataStack(inMemory: true))
        let scheduler = MockNotificationScheduler()
        scheduler.removalDelay = 20_000_000
        let service = ReminderService(repo: repo, scheduler: scheduler)
        let reminder = Reminder(petID: UUID(), type: .feeding, hour: 8, minute: 0)
        let save = Task { try await service.save(reminder, petName: "小白") }
        await Task.yield()
        let reconcile = Task { await service.rescheduleAll() }
        try await save.value
        await reconcile.value
        XCTAssertFalse(scheduler.addedDuringRemoval)
        XCTAssertEqual(scheduler.added.count, 1)
        XCTAssertEqual(try repo.allReminders().count, 1)
    }

    @MainActor func test_failedScheduling_keepsConfiguration_andRetryUsesSameID() async throws {
        let repo = CoreDataReminderRepository(stack: CoreDataStack(inMemory: true))
        let scheduler = MockNotificationScheduler()
        let service = ReminderService(repo: repo, scheduler: scheduler)
        var changes = 0
        service.onDidChange = { changes += 1 }
        let reminder = Reminder(petID: UUID(), type: .feeding, hour: 8, minute: 0)
        scheduler.failNextAdd = true
        do { try await service.save(reminder, petName: "小白"); XCTFail("应报告调度失败") }
        catch { XCTAssertTrue(error is ReminderServiceError) }
        XCTAssertEqual(try repo.allReminders().count, 1)
        XCTAssertEqual(changes, 1, "已保存的配置仍应同步给 Widget")
        XCTAssertTrue(scheduler.added.isEmpty)
        try await service.save(reminder, petName: "小白")
        XCTAssertEqual(try repo.allReminders().count, 1)
        XCTAssertEqual(scheduler.added.count, 1)
    }

    @MainActor func test_failedReplacement_restoresPreviousNotifications() async throws {
        let repo = CoreDataReminderRepository(stack: CoreDataStack(inMemory: true))
        let scheduler = MockNotificationScheduler()
        let service = ReminderService(repo: repo, scheduler: scheduler)
        var reminder = Reminder(petID: UUID(), type: .feeding, hour: 8, minute: 0)
        try await service.save(reminder, petName: "旧名字")
        let originalID = scheduler.added[0].identifier
        reminder.hour = 10
        scheduler.failNextAdd = true
        do { try await service.save(reminder, petName: "新名字"); XCTFail("应报告调度失败") }
        catch { }
        XCTAssertEqual(scheduler.added.count, 1)
        XCTAssertEqual(scheduler.added[0].identifier, originalID)
        XCTAssertTrue(scheduler.added[0].content.body.contains("旧名字"))
        await service.rescheduleAll()
        XCTAssertTrue(scheduler.added[0].content.body.contains("新名字"))
    }

    @MainActor func test_databaseFailure_doesNotScheduleOrPublishChanges() async throws {
        let stack = CoreDataStack(inMemory: true, saveContext: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        let repo = CoreDataReminderRepository(stack: stack)
        let scheduler = MockNotificationScheduler()
        let service = ReminderService(repo: repo, scheduler: scheduler)
        var changes = 0
        service.onDidChange = { changes += 1 }
        do {
            try await service.save(Reminder(petID: UUID(), type: .feeding, hour: 8, minute: 0), petName: "小白")
            XCTFail("应报告数据库保存失败")
        } catch { }
        XCTAssertTrue(try repo.allReminders().isEmpty)
        XCTAssertTrue(scheduler.added.isEmpty)
        XCTAssertEqual(changes, 0)
        XCTAssertFalse(stack.container.viewContext.hasChanges)
    }

    @MainActor func test_invalidRule_doesNotPersistOrSchedule() async throws {
        let repo = CoreDataReminderRepository(stack: CoreDataStack(inMemory: true))
        let scheduler = MockNotificationScheduler()
        let service = ReminderService(repo: repo, scheduler: scheduler)
        for rule in [RepeatRule.weekly([]), .yearly(month: 2, day: 30)] {
            do {
                try await service.save(Reminder(petID: UUID(), type: .feeding, hour: 8,
                                                minute: 0, repeatRule: rule), petName: "小白")
                XCTFail("应拒绝无效重复规则")
            } catch { }
        }
        XCTAssertTrue(try repo.allReminders().isEmpty)
        XCTAssertTrue(scheduler.added.isEmpty)
    }

    @MainActor func test_notificationCapacity_isReportedWithoutEvictingExistingRequests() async throws {
        let repo = CoreDataReminderRepository(stack: CoreDataStack(inMemory: true))
        let scheduler = MockNotificationScheduler()
        scheduler.added = (0..<64).map {
            UNNotificationRequest(identifier: "existing-\($0)", content: UNMutableNotificationContent(), trigger: nil)
        }
        let service = ReminderService(repo: repo, scheduler: scheduler)
        do {
            try await service.save(Reminder(petID: UUID(), type: .feeding, hour: 8, minute: 0), petName: "小白")
            XCTFail("应报告容量不足")
        } catch { XCTAssertTrue(error is ReminderServiceError) }
        XCTAssertEqual(scheduler.added.count, 64)
        XCTAssertTrue(scheduler.removedPrefixes.isEmpty)
    }
}

final class AdvanceCalendarRegressionTests: XCTestCase {
    private func calendar(_ zone: String = "Asia/Shanghai") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }
    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0,
                      calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
    func test_monthlyFirst_advanceOneDay_followsDifferentMonthLengths() {
        let cal = calendar()
        let triggers = ReminderTriggerBuilder.advanceTriggers(rule: .monthly(day: 1), hour: 8, minute: 0,
            advance: .d1, now: date(2026, 1, 15, calendar: cal), occurrenceCount: 3, calendar: cal)
        XCTAssertEqual(triggers.map(\.dateComponents.month), [1, 2, 3])
        XCTAssertEqual(triggers.map(\.dateComponents.day), [31, 28, 31])
        XCTAssertTrue(triggers.allSatisfy { !$0.repeats && $0.dateComponents.year == 2026 })
    }
    func test_yearlyAdvance_recomputesLeapYearDate() {
        let cal = calendar()
        let triggers = ReminderTriggerBuilder.advanceTriggers(rule: .yearly(month: 3, day: 1), hour: 9,
            minute: 0, advance: .d3, now: date(2027, 1, 1, calendar: cal), occurrenceCount: 2, calendar: cal)
        XCTAssertEqual(triggers.map(\.dateComponents.year), [2027, 2028])
        XCTAssertEqual(triggers.map(\.dateComponents.day), [26, 27])
    }
    func test_expiredAdvance_isSkipped_andWindowIsReplenished() {
        let cal = calendar()
        let now = date(2026, 1, 31, hour: 23, calendar: cal)
        let triggers = ReminderTriggerBuilder.advanceTriggers(rule: .monthly(day: 1), hour: 8, minute: 0,
            advance: .d1, now: now, occurrenceCount: 3, calendar: cal)
        XCTAssertEqual(triggers.count, 3)
        XCTAssertEqual(triggers[0].dateComponents.month, 2)
        XCTAssertEqual(triggers[0].dateComponents.day, 28)
        XCTAssertTrue(triggers.allSatisfy { cal.date(from: $0.dateComponents)! > now })
    }
    func test_dayAdvance_preservesWallClockAcrossDaylightSaving() {
        let cal = calendar("America/New_York")
        let triggers = ReminderTriggerBuilder.advanceTriggers(rule: .yearly(month: 3, day: 8), hour: 8,
            minute: 0, advance: .d1, now: date(2026, 1, 1, calendar: cal), occurrenceCount: 1, calendar: cal)
        XCTAssertEqual(triggers[0].dateComponents.day, 7)
        XCTAssertEqual(triggers[0].dateComponents.hour, 8)
        XCTAssertEqual(date(2026, 3, 8, hour: 8, calendar: cal).timeIntervalSince(
            cal.date(from: triggers[0].dateComponents)!), 23 * 3600)
    }
    func test_monthly31_skipsMonthsWithoutTheDay() {
        let cal = calendar()
        let dates = ReminderOccurrenceBuilder.dates(rule: .monthly(day: 31), hour: 8, minute: 0,
            after: date(2026, 1, 31, hour: 9, calendar: cal), count: 2, calendar: cal)
        XCTAssertEqual(dates.map { cal.component(.month, from: $0) }, [3, 5])
    }
}
