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

final class WidgetPetPagingTests: XCTestCase {
    private let pets: [WidgetSnapshot.PetEntry] = [
        .init(id: UUID(), nickname: "小白", species: "狗"),
        .init(id: UUID(), nickname: "豆豆", species: "猫"),
        .init(id: UUID(), nickname: "团团", species: "兔"),
    ]

    private func snapshot() -> WidgetSnapshot {
        WidgetSnapshot(generatedAt: Date(), currentPetID: pets[1].id, pets: pets, reminders: [])
    }

    func test_firstPage_usesAppCurrentPetUntilWidgetSelectionExists() {
        XCTAssertEqual(WidgetPetPage.resolve(in: snapshot(), selectedPetID: nil)?.pet.id, pets[1].id)
        XCTAssertEqual(WidgetPetPage.resolve(in: snapshot(), selectedPetID: pets[2].id)?.pet.id, pets[2].id)
    }

    func test_nextAndPrevious_visitEveryPetAndWrap() throws {
        var page = try XCTUnwrap(WidgetPetPage.resolve(in: snapshot(), selectedPetID: pets[0].id))
        for index in [1, 2, 0] {
            page = try XCTUnwrap(WidgetPetPage.resolve(in: snapshot(), selectedPetID: page.nextPetID))
            XCTAssertEqual(page.pet.id, pets[index].id)
            XCTAssertEqual(page.index, index)
            XCTAssertEqual(page.count, pets.count)
        }
        for index in [2, 1, 0] {
            page = try XCTUnwrap(WidgetPetPage.resolve(in: snapshot(), selectedPetID: page.previousPetID))
            XCTAssertEqual(page.pet.id, pets[index].id)
        }
    }

    func test_selectedIdentity_survivesReorderingAndAppPetChange() throws {
        var updated = snapshot()
        updated.currentPetID = pets[0].id
        updated.pets = [pets[2], pets[0], pets[1]]
        let page = try XCTUnwrap(WidgetPetPage.resolve(in: updated, selectedPetID: pets[2].id))
        XCTAssertEqual(page.pet.id, pets[2].id)
        XCTAssertEqual(page.index, 0)
    }

    func test_deletedSelection_fallsBackToValidCurrentPetThenFirst() {
        var updated = snapshot()
        updated.pets.removeLast()
        XCTAssertEqual(WidgetPetPage.resolve(in: updated, selectedPetID: pets[2].id)?.pet.id, pets[1].id)
        updated.currentPetID = pets[2].id
        XCTAssertEqual(WidgetPetPage.resolve(in: updated, selectedPetID: pets[2].id)?.pet.id, pets[0].id)
    }

    func test_singleAndEmptyPets_doNotOfferPaging() throws {
        var updated = snapshot()
        updated.pets = [pets[0]]
        let page = try XCTUnwrap(WidgetPetPage.resolve(in: updated, selectedPetID: pets[1].id))
        XCTAssertEqual(page.count, 1)
        XCTAssertNil(page.nextPetID)
        XCTAssertNil(page.previousPetID)
        updated.pets = []
        XCTAssertNil(WidgetPetPage.resolve(in: updated, selectedPetID: pets[0].id))
    }

    func test_eachPage_usesItsOwnRemindersAndTimelineBoundaries() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 12))!
        var s = snapshot()
        s.currentPetID = pets[0].id
        s.reminders = [
            .init(id: UUID(), petID: pets[0].id, petName: pets[0].nickname,
                  type: "喂食", hour: 14, minute: 0, repeatRule: .daily),
            .init(id: UUID(), petID: pets[1].id, petName: pets[1].nickname,
                  type: "服药", hour: 17, minute: 0, repeatRule: .daily),
            .init(id: UUID(), petID: pets[1].id, petName: pets[1].nickname,
                  type: "驱虫", hour: 18, minute: 0, repeatRule: .daily, isEnabled: false),
        ]
        for (index, hour) in [(0, 14), (1, 17)] {
            let events = WidgetSnapshotQueries.remainingReminders(in: s, petID: pets[index].id, now: now, calendar: calendar)
            XCTAssertEqual(events.map(\.hour), [hour])
            XCTAssertTrue(events.allSatisfy { $0.petID == pets[index].id })
            let dates = WidgetSnapshotQueries.timelineDates(in: s, petID: pets[index].id, now: now, calendar: calendar)
            XCTAssertTrue(dates.contains(calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now)!))
            let otherHour = index == 0 ? 17 : 14
            XCTAssertFalse(dates.contains(calendar.date(bySettingHour: otherHour, minute: 0, second: 0, of: now)!))
        }
        XCTAssertTrue(WidgetSnapshotQueries.remainingReminders(in: s, petID: pets[2].id, now: now, calendar: calendar).isEmpty)
        XCTAssertTrue(WidgetSnapshotQueries.remainingReminders(in: s, petID: UUID(), now: now, calendar: calendar).isEmpty)
    }

    func test_selectionPersists_withoutChangingSnapshot_andRejectsStaleTarget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("widget-pages-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let s = snapshot()
        try WidgetSnapshotStore.write(s, to: directory)
        XCTAssertTrue(try WidgetPetPageStore.select(petID: pets[2].id, in: directory))
        XCTAssertEqual(WidgetPetPageStore.selectedPetID(from: directory), pets[2].id)
        XCTAssertEqual(WidgetSnapshotStore.read(from: directory), s)
        XCTAssertFalse(try WidgetPetPageStore.select(petID: UUID(), in: directory))
        XCTAssertEqual(WidgetPetPageStore.selectedPetID(from: directory), pets[2].id)
        var updated = s
        updated.pets.removeLast()
        try WidgetSnapshotStore.write(updated, to: directory)
        XCTAssertFalse(try WidgetPetPageStore.select(petID: pets[2].id, in: directory))
        XCTAssertEqual(WidgetPetPage.resolve(in: updated, selectedPetID: WidgetPetPageStore.selectedPetID(from: directory))?.pet.id, pets[1].id)
    }

    func test_unreadableSelectionAndSnapshot_haveSafeFallbacks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("widget-pages-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertNil(WidgetPetPageStore.selectedPetID(from: directory))
        XCTAssertFalse(try WidgetPetPageStore.select(petID: pets[0].id, in: directory))
        try Data("broken".utf8).write(to: directory.appendingPathComponent(WidgetPetPageStore.selectionFileName))
        XCTAssertNil(WidgetPetPageStore.selectedPetID(from: directory))
        XCTAssertEqual(WidgetPetPage.resolve(in: snapshot(), selectedPetID: WidgetPetPageStore.selectedPetID(from: directory))?.pet.id, pets[1].id)
    }

    func test_selectionWriteFailure_leavesSnapshotIntact() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("widget-pages-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let s = snapshot()
        try WidgetSnapshotStore.write(s, to: directory)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(WidgetPetPageStore.selectionFileName), withIntermediateDirectories: true)
        XCTAssertThrowsError(try WidgetPetPageStore.select(petID: pets[0].id, in: directory))
        XCTAssertEqual(WidgetSnapshotStore.read(from: directory), s)
        XCTAssertNil(WidgetPetPageStore.selectedPetID(from: directory))
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
        try await service.removeAll(petID: pet)
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

    @MainActor func test_handle_recordsURL_preservesTargetPetAndClearsProfileNavigation() {
        let router = DeepLinkRouter()
        router.openPet(id: UUID())
        let petID = UUID()
        router.handle(url: URL(string: "petpal://records/\(petID.uuidString)")!)
        XCTAssertEqual(router.recordsPetID, petID)
        XCTAssertTrue(router.path.isEmpty)
        let otherPet = UUID()
        router.handle(url: URL(string: "petpal://records/\(otherPet.uuidString)")!)
        XCTAssertEqual(router.recordsPetID, otherPet)
    }

    @MainActor func test_handle_invalidRecordsURL_doesNotChangePendingDestination() {
        let router = DeepLinkRouter()
        let petID = UUID()
        router.openRecords(id: petID)
        for raw in ["https://records/\(UUID())", "petpal://records/not-a-uuid",
                    "petpal://records/extra/\(UUID())", "petpal://other/\(UUID())"] {
            router.handle(url: URL(string: raw)!)
        }
        XCTAssertEqual(router.recordsPetID, petID)
        XCTAssertTrue(router.path.isEmpty)
        router.handle(url: URL(string: "petpal://pet/\(UUID())")!)
        XCTAssertNil(router.recordsPetID)
        XCTAssertEqual(router.path.count, 1)
    }
}
