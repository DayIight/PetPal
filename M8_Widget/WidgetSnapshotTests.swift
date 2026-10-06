import XCTest
import Combine
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
        try await service.requestPermission()
        let pet = UUID()
        try await service.save(Reminder(petID: pet, type: .feeding, hour: 8, minute: 0),
                               petName: "小白")
        XCTAssertEqual(calls, 1, "save 后应触发快照重建钩子")
        await service.rescheduleAll()
        XCTAssertEqual(calls, 2, "rescheduleAll 后应触发快照重建钩子")
        try await service.removeAll(petID: pet)
        XCTAssertEqual(calls, 3, "removeAll 后应触发快照重建钩子")
    }

    @MainActor func test_save_whenDenied_stillTriggersOnDidChange() async throws {
        scheduler.authorized = false
        var calls = 0
        service.onDidChange = { calls += 1 }
        try await service.requestPermission()
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

final class WidgetTimelineRegressionTests: XCTestCase {
    private let petID = UUID()
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }
    private func date(_ month: Int, _ day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }
    private func snapshot(_ reminders: [WidgetSnapshot.ReminderEntry]) -> WidgetSnapshot {
        .init(generatedAt: date(10, 4, hour: 8), currentPetID: petID,
              pets: [.init(id: petID, nickname: "小白", species: "狗")], reminders: reminders)
    }
    private func reminder(rule: RepeatRule?, hour: Int = 9) -> WidgetSnapshot.ReminderEntry {
        .init(id: UUID(), petID: petID, petName: "小白", type: "喂食", hour: hour, minute: 0, repeatRule: rule)
    }

    func test_timeline_removesReminderAtItsTime_withoutAppRefresh() throws {
        let r = reminder(rule: .daily)
        let plan = WidgetSnapshotQueries.timeline(in: snapshot([r]), now: date(10, 4, hour: 8), calendar: calendar)
        XCTAssertEqual(plan.states.first?.remaining.map(\.id), [r.id])
        let after = try XCTUnwrap(plan.states.first { $0.date == date(10, 4, hour: 9) })
        XCTAssertTrue(after.remaining.isEmpty)
        XCTAssertEqual(plan.states.map(\.date), plan.states.map(\.date).sorted())
    }

    func test_midnight_changesWeeklyRules_usingSameSnapshot() throws {
        let sunday = reminder(rule: .weekly([1]))
        let monday = reminder(rule: .weekly([2]))
        let plan = WidgetSnapshotQueries.timeline(in: snapshot([sunday, monday]),
            now: date(10, 4, hour: 23), calendar: calendar)
        let midnight = try XCTUnwrap(plan.states.first { $0.date == date(10, 5) })
        XCTAssertEqual(midnight.remaining.map(\.id), [monday.id])
        XCTAssertEqual(plan.refreshAfter, date(10, 11))
    }

    func test_oldSnapshot_rulesStillWorkInAnotherMonth() {
        let monthly = reminder(rule: .monthly(day: 1))
        let yearly = reminder(rule: .yearly(month: 11, day: 1), hour: 10)
        let result = WidgetSnapshotQueries.remainingReminders(in: snapshot([monthly, yearly]),
            now: date(11, 1, hour: 8), calendar: calendar)
        XCTAssertEqual(result.map(\.id), [monthly.id, yearly.id])
        XCTAssertTrue(WidgetSnapshotQueries.remainingReminders(in: snapshot([monthly, yearly]),
            now: date(11, 2, hour: 8), calendar: calendar).isEmpty)
    }

    func test_legacySnapshot_expiresInsteadOfReusingYesterday() {
        let r = reminder(rule: nil)
        XCTAssertEqual(WidgetSnapshotQueries.remainingReminders(in: snapshot([r]),
            now: date(10, 4, hour: 8), calendar: calendar).count, 1)
        XCTAssertTrue(WidgetSnapshotQueries.remainingReminders(in: snapshot([r]),
            now: date(10, 5, hour: 8), calendar: calendar).isEmpty)
    }

    func test_legacyJSON_withoutRepeatRule_isStillDecodable() throws {
        let data = Data("""
        {"generatedAt":0,"pets":[],"reminders":[{"id":"\(UUID())","petID":"\(petID)","petName":"小白","type":"喂食","hour":8,"minute":0}]}
        """.utf8)
        let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        XCTAssertEqual(snapshot.reminders.count, 1)
        XCTAssertNil(snapshot.reminders[0].repeatRule)
    }
}

final class WidgetSyncerRegressionTests: XCTestCase {
    private final class FailingReminderRepository: ReminderRepository {
        func reminders(petID: UUID) throws -> [Reminder] { [] }
        func allReminders() throws -> [Reminder] { throw CocoaError(.fileReadUnknown) }
        func save(_ reminder: Reminder) throws { }
        func delete(id: UUID) throws { }
        func deleteAll(petID: UUID) throws { }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @MainActor func test_syncer_preservesRulesForFutureDays() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stack = CoreDataStack(inMemory: true)
        let repo = CoreDataReminderRepository(stack: stack)
        let nextWeekday = Calendar.current.component(.weekday, from: Date()) % 7 + 1
        let r = Reminder(petID: UUID(), type: .feeding, hour: 8, minute: 0, repeatRule: .weekly([nextWeekday]))
        try repo.save(r)
        let current = CurrentPetStore(repo: CoreDataPetRepository(stack: stack))
        let syncer = WidgetSnapshotSyncer(reminderRepo: repo, currentPet: current, directory: { directory })
        syncer.reloadTimelines = { }
        syncer.sync()
        let snapshot = try XCTUnwrap(WidgetSnapshotStore.read(from: directory))
        XCTAssertEqual(snapshot.reminders.map(\.id), [r.id])
        XCTAssertEqual(snapshot.reminders.first?.repeatRule, .weekly([nextWeekday]))
    }

    @MainActor func test_syncer_excludesPausedReminders() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stack = CoreDataStack(inMemory: true)
        let repo = CoreDataReminderRepository(stack: stack)
        let petID = UUID()
        let enabled = Reminder(petID: petID, type: .feeding, hour: 8, minute: 0)
        let paused = Reminder(petID: petID, type: .medication, hour: 12, minute: 0, isEnabled: false)
        try repo.save(enabled); try repo.save(paused)
        let current = CurrentPetStore(repo: CoreDataPetRepository(stack: stack))
        let syncer = WidgetSnapshotSyncer(reminderRepo: repo, currentPet: current, directory: { directory })
        syncer.reloadTimelines = {}
        syncer.sync()
        XCTAssertEqual(WidgetSnapshotStore.read(from: directory)?.reminders.map(\.id), [enabled.id])
    }

    @MainActor func test_failedRead_preservesLastGoodSnapshot_withoutReload() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = WidgetSnapshot(generatedAt: Date(), pets: [], reminders: [])
        try WidgetSnapshotStore.write(original, to: directory)
        let current = CurrentPetStore(repo: CoreDataPetRepository(stack: CoreDataStack(inMemory: true)))
        let syncer = WidgetSnapshotSyncer(reminderRepo: FailingReminderRepository(), currentPet: current,
                                          directory: { directory })
        var reloads = 0
        syncer.reloadTimelines = { reloads += 1 }
        syncer.sync()
        XCTAssertEqual(WidgetSnapshotStore.read(from: directory), original)
        XCTAssertEqual(reloads, 0)
    }

    @MainActor func test_unavailableSharedContainer_doesNotWritePrivateDocumentsOrReload() {
        let privateSnapshot = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(WidgetSnapshotStore.snapshotFileName)
        let before = try? Data(contentsOf: privateSnapshot)
        let stack = CoreDataStack(inMemory: true)
        let current = CurrentPetStore(repo: CoreDataPetRepository(stack: stack))
        let syncer = WidgetSnapshotSyncer(reminderRepo: CoreDataReminderRepository(stack: stack),
                                          currentPet: current, directory: { nil })
        var reloads = 0
        syncer.reloadTimelines = { reloads += 1 }
        syncer.sync()
        XCTAssertEqual(try? Data(contentsOf: privateSnapshot), before)
        XCTAssertEqual(reloads, 0, "没有共享容器时不能假装已经同步成功")
    }
}

final class ApplicationConfigurationTests: XCTestCase {
    func test_appBundle_canReadAndWriteRealWidgetSharedContainer() throws {
        let shared = try XCTUnwrap(WidgetSnapshotStore.sharedDirectory,
            "App Group 不可用。模拟器构建也需保留签名和 entitlements，不能用 CODE_SIGNING_ALLOWED=NO。")
        let probe = shared.appendingPathComponent("widget-sharing-test-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: probe) }
        let snapshot = WidgetSnapshot(generatedAt: Date(), pets: [], reminders: [])
        try WidgetSnapshotStore.write(snapshot, to: probe)
        XCTAssertEqual(WidgetSnapshotStore.read(from: probe), snapshot)
    }

    func test_appBundle_registersPetPalURLScheme() throws {
        let types = try XCTUnwrap(Bundle.main.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertTrue(schemes.contains("petpal"))
    }

    func test_appBundle_containsCompiledPetPalIcon() throws {
        let icons = try XCTUnwrap(Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any])
        let primary = try XCTUnwrap(icons["CFBundlePrimaryIcon"] as? [String: Any])
        XCTAssertEqual(primary["CFBundleIconName"] as? String, "PetPalSocial")
        XCTAssertNotNil(Bundle.main.url(forResource: "Assets", withExtension: "car"))
    }
}
