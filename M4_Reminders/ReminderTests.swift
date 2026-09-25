import XCTest
import UserNotifications
@testable import PetPal

// MARK: - Mock 调度器（替代 UNUserNotificationCenter）
final class MockNotificationScheduler: NotificationScheduling {
    var authorized = true
    var added: [UNNotificationRequest] = []
    var removedPrefixes: [String] = []
    func requestAuthorization() async throws -> Bool { authorized }
    func add(_ request: UNNotificationRequest) async throws { added.append(request) }
    func removePending(matchingPrefix prefix: String) {
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
                                                       hour: 9, minute: 0, advance: .d3)
        XCTAssertEqual(t.count, 1)
        XCTAssertEqual(t[0].dateComponents.month, 2)
        XCTAssertEqual(t[0].dateComponents.day, 26)
    }
    @MainActor func test_saveWithAdvance_schedulesBothTriggerGroups() async throws {
        let repo = CoreDataReminderRepository(stack: CoreDataStack(inMemory: true))
        let scheduler = MockNotificationScheduler()
        let service = ReminderService(repo: repo, scheduler: scheduler)
        await service.requestPermission()
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
        await service.requestPermission()
        try await service.save(Reminder(petID: UUID(), type: .feeding, hour: 8, minute: 0), petName: "小白")
        XCTAssertEqual(service.permission, .denied)
        XCTAssertTrue(scheduler.added.isEmpty)
    }
    // M-03：权限被拒时提醒配置仍落库（配置与送达解耦，不再静默丢失）
    @MainActor func test_deniedPermission_stillPersists() async throws {
        scheduler.authorized = false
        await service.requestPermission()
        let pet = UUID()
        try await service.save(Reminder(petID: pet, type: .feeding, hour: 8, minute: 0), petName: "小白")
        XCTAssertEqual(try repo.reminders(petID: pet).count, 1)
        XCTAssertTrue(scheduler.added.isEmpty)
    }
    // M-06：时区变更后全量重排——撤销旧调度并按库中配置重建
    @MainActor func test_rescheduleAll_rebuildsFromStore() async throws {
        await service.requestPermission()
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
        await service.requestPermission()
        let pet = UUID()
        try await service.save(Reminder(petID: pet, type: .feeding, hour: 8, minute: 0), petName: "小白")
        await service.rescheduleAll()
        XCTAssertTrue(scheduler.added.isEmpty)
    }
    @MainActor func test_save_schedulesAndPersists() async throws {
        await service.requestPermission()
        let pet = UUID()
        try await service.save(Reminder(petID: pet, type: .medication, hour: 21, minute: 0), petName: "小白")
        XCTAssertEqual(scheduler.added.count, 1)
        XCTAssertEqual(try repo.reminders(petID: pet).count, 1)
    }
    @MainActor func test_removeAll_cancelsAndDeletes() async throws {
        await service.requestPermission()
        let pet = UUID()
        let reminder = Reminder(petID: pet, type: .feeding, hour: 8, minute: 0)
        try await service.save(reminder, petName: "小白")
        try service.removeAll(petID: pet)
        XCTAssertTrue(scheduler.added.isEmpty)
        XCTAssertTrue(scheduler.removedPrefixes.contains(reminder.id.uuidString),
                      "removeAll 必须按提醒 id 前缀撤销 pending 通知")
        XCTAssertTrue(try repo.reminders(petID: pet).isEmpty)
    }
}
