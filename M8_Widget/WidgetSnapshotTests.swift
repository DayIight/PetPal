import XCTest
@testable import PetPal

final class WidgetSnapshotStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("widget-snapshot-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func sampleSnapshot() -> WidgetSnapshot {
        WidgetSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            currentPetID: UUID(),
            pets: [.init(id: UUID(), nickname: "小白", species: "狗", avatarFileName: "a.jpg")],
            reminders: [.init(id: UUID(), petID: UUID(), petName: "小白",
                              type: "喂食", hour: 8, minute: 30)])
    }

    func test_writeThenRead_roundTrips() throws {
        let snapshot = sampleSnapshot()
        try WidgetSnapshotStore.write(snapshot, to: dir)
        XCTAssertEqual(WidgetSnapshotStore.read(from: dir), snapshot)
    }

    func test_read_missingFile_returnsNil() {
        XCTAssertNil(WidgetSnapshotStore.read(from: dir))
    }

    func test_copyAvatar_copiesIntoAvatarsSubdir() throws {
        let src = dir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try Data([0xFF, 0xD8]).write(to: src.appendingPathComponent("a.jpg"))
        WidgetSnapshotStore.copyAvatar(fileName: "a.jpg", from: src, to: dir)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: WidgetSnapshotStore.avatarURL(fileName: "a.jpg", in: dir).path))
    }
}

final class WidgetSnapshotQueryTests: XCTestCase {
    private let petA = UUID(), petB = UUID()
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    private func snapshot(currentPetID: UUID?,
                          reminders: [WidgetSnapshot.ReminderEntry]) -> WidgetSnapshot {
        WidgetSnapshot(generatedAt: Date(), currentPetID: currentPetID,
                       pets: [.init(id: petA, nickname: "小白", species: "狗", avatarFileName: nil),
                              .init(id: petB, nickname: "豆豆", species: "猫", avatarFileName: nil)],
                       reminders: reminders)
    }

    private func reminder(_ petID: UUID, _ hour: Int, _ minute: Int) -> WidgetSnapshot.ReminderEntry {
        .init(id: UUID(), petID: petID, petName: "小白", type: "喂食", hour: hour, minute: minute)
    }

    private func noon() -> Date {   // 当天 12:00（固定时区，避免宿主机时区影响）
        let comps = calendar.dateComponents([.year, .month, .day], from: Date())
        var c = comps; c.hour = 12; c.minute = 0
        return calendar.date(from: c)!
    }

    func test_currentPet_fallsBackToFirstWhenIDMissing() {
        let s = snapshot(currentPetID: UUID(), reminders: [])
        XCTAssertEqual(WidgetSnapshotQueries.currentPet(in: s)?.id, petA)
    }

    func test_remainingReminders_filtersPastAndOtherPet_andSorts() {
        let s = snapshot(currentPetID: petA, reminders: [
            reminder(petA, 18, 0), reminder(petA, 8, 0),      // 18:00 未过；8:00 已过
            reminder(petB, 20, 0),                             // 其他宠物排除
            reminder(petA, 15, 30),
        ])
        let result = WidgetSnapshotQueries.remainingReminders(in: s, now: noon(), calendar: calendar)
        XCTAssertEqual(result.map(\.hour), [15, 18])
        XCTAssertEqual(result.map(\.minute), [30, 0])
    }

    func test_nextReminder_nilWhenAllPast() {
        let s = snapshot(currentPetID: petA, reminders: [reminder(petA, 7, 0)])
        XCTAssertNil(WidgetSnapshotQueries.nextReminder(in: s, now: noon(), calendar: calendar))
    }

    func test_remainingReminders_emptyWhenNoPet() {
        let s = WidgetSnapshot(generatedAt: Date(), currentPetID: nil, pets: [], reminders: [])
        XCTAssertTrue(WidgetSnapshotQueries.remainingReminders(in: s, now: noon()).isEmpty)
    }
}

final class WidgetSnapshotFiresTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }
    // 2026-09-26 为周六（weekday 7）
    private var saturday: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 26))!
    }

    func test_daily_alwaysFires() {
        XCTAssertTrue(WidgetSnapshotSyncer.fires(rule: .daily, on: saturday, calendar: calendar))
    }
    func test_weekly_matchesWeekday() {
        XCTAssertTrue(WidgetSnapshotSyncer.fires(rule: .weekly([7]), on: saturday, calendar: calendar))
        XCTAssertFalse(WidgetSnapshotSyncer.fires(rule: .weekly([2]), on: saturday, calendar: calendar))
    }
    func test_monthly_matchesDay() {
        XCTAssertTrue(WidgetSnapshotSyncer.fires(rule: .monthly(day: 26), on: saturday, calendar: calendar))
        XCTAssertFalse(WidgetSnapshotSyncer.fires(rule: .monthly(day: 27), on: saturday, calendar: calendar))
    }
    func test_yearly_matchesMonthAndDay() {
        XCTAssertTrue(WidgetSnapshotSyncer.fires(rule: .yearly(month: 9, day: 26),
                                                 on: saturday, calendar: calendar))
        XCTAssertFalse(WidgetSnapshotSyncer.fires(rule: .yearly(month: 10, day: 26),
                                                  on: saturday, calendar: calendar))
    }
}

final class ReminderServiceOnDidChangeTests: XCTestCase {
    private var repo: CoreDataReminderRepository!
    private var scheduler: MockNotificationScheduler!
    private var service: ReminderService!

    @MainActor override func setUp() {
        repo = CoreDataReminderRepository(stack: CoreDataStack(inMemory: true))
        scheduler = MockNotificationScheduler()
        service = ReminderService(repo: repo, scheduler: scheduler)
    }

    @MainActor func test_save_removeAll_rescheduleAll_triggerOnDidChange() async throws {
        var calls = 0
        service.onDidChange = { calls += 1 }
        await service.requestPermission()
        let pet = UUID()
        try await service.save(Reminder(petID: pet, type: .feeding, hour: 8, minute: 0),
                               petName: "小白")
        XCTAssertEqual(calls, 1, "save 后应触发快照重建钩子")
        await service.rescheduleAll()
        XCTAssertEqual(calls, 2, "rescheduleAll 后应触发快照重建钩子")
        try service.removeAll(petID: pet)
        XCTAssertEqual(calls, 3, "removeAll 后应触发快照重建钩子")
    }

    @MainActor func test_save_whenDenied_stillTriggersOnDidChange() async throws {
        scheduler.authorized = false
        var calls = 0
        service.onDidChange = { calls += 1 }
        await service.requestPermission()
        try await service.save(Reminder(petID: UUID(), type: .feeding, hour: 8, minute: 0),
                               petName: "小白")
        XCTAssertEqual(calls, 1, "权限被拒只影响调度，快照钩子仍应触发")
    }
}

final class DeepLinkRouterTests: XCTestCase {
    @MainActor func test_handle_petURL_appendsToPath() {
        let router = DeepLinkRouter()
        let id = UUID()
        router.handle(url: URL(string: "petpal://pet/\(id.uuidString)")!)
        XCTAssertEqual(router.path.count, 1)
    }

    @MainActor func test_handle_foreignScheme_ignored() {
        let router = DeepLinkRouter()
        router.handle(url: URL(string: "https://example.com/pet/\(UUID().uuidString)")!)
        router.handle(url: URL(string: "petpal://other/\(UUID().uuidString)")!)
        router.handle(url: URL(string: "petpal://pet/not-a-uuid")!)
        XCTAssertEqual(router.path.count, 0)
    }
}
