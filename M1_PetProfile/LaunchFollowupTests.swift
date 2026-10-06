import XCTest
import CoreData
import Combine
import UserNotifications
@testable import PetPal

final class RecurrenceBoundaryTests: XCTestCase {
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return c }
    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: minute))!
    }
    func test_month31_clampsEachMonthAndReturnsTo31() {
        let dates = ReminderRecurrence.dates(rule: .monthly(day: 31), hour: 9, minute: 0,
            after: date(2026, 1, 1), through: date(2026, 4, 30, 23), calendar: calendar)
        XCTAssertEqual(dates, [date(2026, 1, 31, 9), date(2026, 2, 28, 9), date(2026, 3, 31, 9), date(2026, 4, 30, 9)])
    }
    func test_feb29_clampsNonLeapYears() {
        let dates = ReminderRecurrence.dates(rule: .yearly(month: 2, day: 29), hour: 9, minute: 0,
            after: date(2027, 1, 1), through: date(2029, 3, 1), calendar: calendar)
        XCTAssertEqual(dates, [date(2027, 2, 28, 9), date(2028, 2, 29, 9), date(2029, 2, 28, 9)])
    }
    func test_advanceOffsetsEachActualDate() {
        let dates = ReminderRecurrence.dates(rule: .monthly(day: 1), hour: 9, minute: 0,
            after: date(2026, 2, 1), through: date(2026, 4, 2), calendar: calendar)
        XCTAssertEqual(dates.map { AdvanceOption.d3.fireDate(for: $0, calendar: calendar) },
            [date(2026, 1, 29, 9), date(2026, 2, 26, 9), date(2026, 3, 29, 9)])
    }
    func test_invalidDatesEmptyWeekdaysAndDailyAdvanceAreRejected() {
        XCTAssertNotNil(ReminderRecurrence.validationError(rule: .weekly([]), hour: 9, minute: 0, advance: .none))
        XCTAssertNotNil(ReminderRecurrence.validationError(rule: .yearly(month: 2, day: 31), hour: 9, minute: 0, advance: .none))
        XCTAssertNotNil(ReminderRecurrence.validationError(rule: .daily, hour: 9, minute: 0, advance: .d1))
        XCTAssertNil(ReminderRecurrence.validationError(rule: .daily, hour: 9, minute: 0, advance: .h1))
        XCTAssertNil(ReminderRecurrence.validationError(rule: .yearly(month: 2, day: 29), hour: 9, minute: 0, advance: .none))
    }
    func test_onceIsFiniteAndExpiredIsOmitted() {
        let due = date(2026, 10, 8, 9)
        XCTAssertEqual(ReminderRecurrence.dates(rule: .once(at: due), hour: 9, minute: 0, after: date(2026, 10, 7), through: date(2026, 10, 9), calendar: calendar), [due])
        XCTAssertTrue(ReminderRecurrence.dates(rule: .once(at: due), hour: 9, minute: 0, after: due, through: date(2026, 10, 9), calendar: calendar).isEmpty)
    }
    func test_dayAdvancePreservesWallClockAcrossDST() {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let due = c.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 9))!
        let early = AdvanceOption.d3.fireDate(for: due, calendar: c)
        XCTAssertEqual(c.component(.day, from: early), 6)
        XCTAssertEqual(c.component(.hour, from: early), 9)
        XCTAssertNotEqual(due.timeIntervalSince(early), 3 * 86400)
    }
    func test_rollingPlanRespectsBudgetAndKeepsPairsTogether() {
        let r = Reminder(petID: UUID(), type: .vaccine, hour: 9, minute: 0, repeatRule: .monthly(day: 31), advance: .d3)
        let plan = ReminderSchedulePlan.build([r], now: date(2026, 1, 1), calendar: calendar, limit: 5)
        XCTAssertEqual(plan.requests.count, 4)
        XCTAssertEqual(plan.scheduledThrough[r.id], date(2026, 2, 28, 9))
        XCTAssertTrue(plan.incomplete.contains(r.id))
        XCTAssertTrue(plan.requests.allSatisfy { ($0.trigger as? UNCalendarNotificationTrigger)?.repeats == false })
        let earlyDates = plan.requests.filter { $0.identifier.contains("#adv#") }.compactMap { ($0.trigger as? UNCalendarNotificationTrigger).flatMap { calendar.date(from: $0.dateComponents) } }
        XCTAssertEqual(earlyDates.count, 2)
    }
    func test_pausedIsOmittedAndBudgetNeverExceeds64() {
        let disabled = Reminder(petID: UUID(), type: .feeding, hour: 9, minute: 0, isEnabled: false)
        XCTAssertTrue(ReminderSchedulePlan.build([disabled]).requests.isEmpty)
        let monthly = (0..<40).map { _ in Reminder(petID: UUID(), type: .feeding, hour: 9, minute: 0, repeatRule: .monthly(day: 31), advance: .d1) }
        XCTAssertLessThanOrEqual(ReminderSchedulePlan.build(monthly, now: date(2026, 1, 1), calendar: calendar).requests.count, 64)
    }
}

final class ReminderLifecycleTests: XCTestCase {
    @MainActor func test_foregroundRefreshRecognizesPermissionGrantedInSettings() async throws {
        let repo = CoreDataReminderRepository(stack: CoreDataStack(inMemory: true))
        let scheduler = MockNotificationScheduler(); scheduler.authorized = false
        let service = ReminderService(repo: repo, scheduler: scheduler)
        let r = Reminder(petID: UUID(), type: .feeding, hour: 8, minute: 0)
        let notice = try await service.save(r, petName: "小白")
        XCTAssertNotNil(notice); XCTAssertTrue(scheduler.added.isEmpty)
        scheduler.authorized = true
        await service.rescheduleAll()
        XCTAssertEqual(service.permission, .granted); XCTAssertEqual(scheduler.added.count, 1)
        scheduler.authorized = false
        await service.rescheduleAll()
        XCTAssertEqual(service.permission, .denied); XCTAssertTrue(scheduler.added.isEmpty)
    }
    @MainActor func test_databaseFailureThrowsAndNeverAddsNotification() async {
        let stack = CoreDataStack(inMemory: true, saveHandler: { _ in throw NSError(domain: "disk", code: 1) })
        let repo = CoreDataReminderRepository(stack: stack)
        let scheduler = MockNotificationScheduler()
        let service = ReminderService(repo: repo, scheduler: scheduler)
        do { try await service.save(Reminder(petID: UUID(), type: .feeding, hour: 8, minute: 0), petName: "小白"); XCTFail("应报告保存失败") }
        catch {}
        XCTAssertTrue(scheduler.added.isEmpty); XCTAssertEqual(try? repo.allReminders().count, 0)
    }
    @MainActor func test_addFailureIsReportedAfterConfigurationSaved() async throws {
        let repo = CoreDataReminderRepository(stack: CoreDataStack(inMemory: true))
        let scheduler = MockNotificationScheduler(); scheduler.failAdd = true
        let service = ReminderService(repo: repo, scheduler: scheduler)
        let notice = try await service.save(Reminder(petID: UUID(), type: .feeding, hour: 8, minute: 0), petName: "小白")
        XCTAssertNotNil(notice)
        XCTAssertEqual(try repo.allReminders().count, 1)
        XCTAssertNotNil(service.scheduleError)
    }
    @MainActor func test_overlappingSavesWaitForRemovalAndFinishWithLatestConfiguration() async throws {
        let repo = CoreDataReminderRepository(stack: CoreDataStack(inMemory: true))
        let scheduler = MockNotificationScheduler(); scheduler.removalDelay = 20_000_000
        let service = ReminderService(repo: repo, scheduler: scheduler)
        let r = Reminder(petID: UUID(), type: .feeding, hour: 8, minute: 0)
        let first = Task { try await service.save(r, petName: "旧名字") }
        await Task.yield()
        let second = Task { try await service.save(r, petName: "新名字") }
        _ = try await first.value; _ = try await second.value
        XCTAssertEqual(scheduler.events, ["remove.begin", "remove.end", "add", "remove.begin", "remove.end", "add"])
        XCTAssertEqual(scheduler.added.count, 1)
        XCTAssertTrue(scheduler.added[0].content.body.contains("新名字"))
    }
    @MainActor func test_pauseAndEditReuseIdentity() async throws {
        let repo = CoreDataReminderRepository(stack: CoreDataStack(inMemory: true))
        let scheduler = MockNotificationScheduler(); let service = ReminderService(repo: repo, scheduler: scheduler)
        var r = Reminder(petID: UUID(), type: .feeding, hour: 8, minute: 0)
        try await service.save(r, petName: "小白")
        r.isEnabled = false; try await service.save(r, petName: "小白")
        XCTAssertTrue(scheduler.added.isEmpty)
        r.isEnabled = true; r.hour = 11; try await service.save(r, petName: "小白")
        XCTAssertEqual(try repo.allReminders().count, 1)
        XCTAssertEqual((scheduler.added.first?.trigger as? UNCalendarNotificationTrigger)?.dateComponents.hour, 11)
    }
}

final class HealthConsistencyTests: XCTestCase {
    func test_editCheckupReplacesLinkedWeightAndDeleteRemovesIt() throws {
        let stack = CoreDataStack(inMemory: true); let repo = CoreDataRecordRepository(stack: stack)
        let weights = CoreDataWeightRepository(stack: stack)
        var r = Record(petID: UUID(), kind: .checkup, answers: ["weightKg": "8"])
        try repo.create(r)
        let originalID = try XCTUnwrap(weights.samples(petID: r.petID).first?.id)
        r.answers["weightKg"] = "9"; try repo.update(r)
        let samples = try weights.samples(petID: r.petID)
        XCTAssertEqual(samples.count, 1); XCTAssertEqual(samples[0].kg, 9)
        XCTAssertEqual(samples[0].id, originalID); XCTAssertEqual(samples[0].sourceRecordID, r.id)
        try repo.delete(id: r.id); XCTAssertTrue(try weights.samples(petID: r.petID).isEmpty)
    }
    func test_clearingCheckupWeightDoesNotDeleteManualWeight() throws {
        let stack = CoreDataStack(inMemory: true); let repo = CoreDataRecordRepository(stack: stack)
        let weights = CoreDataWeightRepository(stack: stack)
        let pet = UUID(); let manual = WeightSample(petID: pet, kg: 8, date: Date())
        try weights.add(manual)
        var r = Record(petID: pet, kind: .checkup, answers: ["weightKg": "8"]); try repo.create(r)
        XCTAssertEqual(try weights.samples(petID: pet).count, 2)
        r.answers["weightKg"] = ""; try repo.update(r)
        XCTAssertEqual(try weights.samples(petID: pet).map(\.id), [manual.id])
    }
    func test_recordAndDerivedWeightRollbackTogether() throws {
        var fail = false
        let stack = CoreDataStack(inMemory: true, saveHandler: { ctx in if fail { throw NSError(domain: "disk", code: 1) }; try ctx.save() })
        let repo = CoreDataRecordRepository(stack: stack); let weights = CoreDataWeightRepository(stack: stack)
        var r = Record(petID: UUID(), kind: .checkup, answers: ["weightKg": "8"]); try repo.create(r)
        fail = true; r.answers["weightKg"] = "9"
        XCTAssertThrowsError(try repo.update(r))
        XCTAssertEqual(try weights.samples(petID: r.petID).first?.kg, 8)
        XCTAssertEqual(try stack.container.viewContext.fetch(CDRecord.fetchRequest()).first?.answers?["weightKg"], "8")
        XCTAssertThrowsError(try repo.delete(id: r.id)); XCTAssertEqual(try weights.samples(petID: r.petID).count, 1)
    }
    func test_manualWeightEditableAndSourceWeightProtected() throws {
        let stack = CoreDataStack(inMemory: true); let weights = CoreDataWeightRepository(stack: stack)
        var manual = WeightSample(petID: UUID(), kg: 8, date: Date()); try weights.add(manual)
        manual.kg = 9; try weights.update(manual)
        XCTAssertEqual(try weights.samples(petID: manual.petID).first?.kg, 9)
        let r = Record(petID: manual.petID, kind: .checkup, answers: ["weightKg": "10"])
        try CoreDataRecordRepository(stack: stack).create(r)
        let derived = try XCTUnwrap(weights.samples(petID: manual.petID).first { $0.sourceRecordID != nil })
        XCTAssertThrowsError(try weights.update(derived)); XCTAssertThrowsError(try weights.delete(id: derived.id))
        try weights.delete(id: manual.id)
        XCTAssertEqual(try weights.samples(petID: manual.petID).count, 1)
    }
    func test_currentWeightUsesLatestDateAndRestoresBaselineAfterDeletion() throws {
        let stack = CoreDataStack(inMemory: true); let pets = CoreDataPetRepository(stack: stack)
        let weights = CoreDataWeightRepository(stack: stack)
        let pet = Pet(nickname: "小白", breed: "柯基", weightKg: 5); try pets.create(pet)
        var current: Pet?; let subscription = pets.petsPublisher.sink { current = $0.first }; defer { subscription.cancel() }
        let latest = WeightSample(petID: pet.id, kg: 8, date: Date()); try weights.add(latest)
        try weights.add(WeightSample(petID: pet.id, kg: 6, date: Date().addingTimeInterval(-86400)))
        XCTAssertEqual(current?.weightKg, 8)
        try weights.delete(id: latest.id); XCTAssertEqual(current?.weightKg, 6)
        for sample in try weights.samples(petID: pet.id) { try weights.delete(id: sample.id) }
        XCTAssertEqual(current?.weightKg, 5)
    }
    func test_profileWeightChangeCreatesSampleButOtherEditsDoNot() throws {
        let stack = CoreDataStack(inMemory: true); let pets = CoreDataPetRepository(stack: stack)
        let weights = CoreDataWeightRepository(stack: stack)
        var pet = Pet(nickname: "小白", breed: "柯基", weightKg: 5); try pets.create(pet)
        pet.weightKg = 8; try pets.update(pet)
        XCTAssertEqual(try weights.samples(petID: pet.id).count, 1)
        pet.nickname = "豆豆"; try pets.update(pet)
        XCTAssertEqual(try weights.samples(petID: pet.id).count, 1)
    }
    func test_checkupWeightUsesSameRangeAsManualInput() {
        XCTAssertFalse(RecordValidator.errors(for: Record(kind: .checkup, answers: ["weightKg": "101"])).isEmpty)
        XCTAssertTrue(RecordValidator.errors(for: Record(kind: .checkup, answers: ["weightKg": "100"])).isEmpty)
    }
    func test_customRecordRetainsSchemaAfterTemplateRenameAndDeletion() throws {
        let stack = CoreDataStack(inMemory: true); let templates = CoreDataCustomTemplateRepository(stack: stack)
        let records = CoreDataRecordRepository(stack: stack)
        var template = CustomTemplate(name: "旧模板", fields: [.init(title: "旧字段", type: .text)])
        try templates.save(template)
        let record = Record(petID: UUID(), kind: .custom, answers: [template.fields[0].id.uuidString: "原答案"], templateName: template.name,
                            templateID: template.id, templateSnapshot: template, templateSchemaVersion: 1)
        try records.create(record)
        template.name = "新名字"; template.fields[0].title = "新字段"; try templates.save(template); try templates.delete(id: template.id)
        var saved: PetPal.Record?; let subscription = records.recordsPublisher(petID: record.petID).sink { saved = $0.first }; defer { subscription.cancel() }
        XCTAssertEqual(saved?.templateSnapshot?.fields[0].title, "旧字段")
        XCTAssertEqual(saved?.templateID, template.id); XCTAssertEqual(saved?.displayKind, "旧模板")
    }
    func test_nextDueReminderUpdatesAndDeletesWithSource() throws {
        let stack = CoreDataStack(inMemory: true); let records = CoreDataRecordRepository(stack: stack)
        let reminders = CoreDataReminderRepository(stack: stack)
        var record = Record(petID: UUID(), kind: .vaccine, answers: ["vaccineName": "疫苗", "nextDue": "2030-03-01"], wantsNextReminder: true)
        try records.create(record)
        let old = try XCTUnwrap(reminders.allReminders().first)
        XCTAssertEqual(old.sourceRecordID, record.id)
        var customized = old; customized.advance = .d1; customized.isEnabled = false; try reminders.save(customized)
        record.answers["nextDue"] = "2030-04-01"; try records.update(record)
        let new = try XCTUnwrap(reminders.allReminders().first)
        XCTAssertEqual(new.id, old.id); XCTAssertNotEqual(new.repeatRule, old.repeatRule)
        XCTAssertEqual(new.advance, .d1); XCTAssertFalse(new.isEnabled)
        try records.delete(id: record.id); XCTAssertTrue(try reminders.allReminders().isEmpty)
    }
}

final class WidgetRecurrenceTests: XCTestCase {
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return c }
    func date(_ day: Int, _ hour: Int = 0) -> Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))! }
    func snapshot(_ rule: RepeatRule?) -> WidgetSnapshot {
        let id = UUID()
        return WidgetSnapshot(generatedAt: date(5), currentPetID: id, pets: [.init(id: id, nickname: "小白", species: "狗")],
            reminders: [.init(id: UUID(), petID: id, petName: "小白", type: "喂食", hour: 9, minute: 0, repeatRule: rule)])
    }
    func test_legacySnapshotExpiresAtMidnight() {
        XCTAssertEqual(WidgetSnapshotQueries.remainingReminders(in: snapshot(nil), now: date(5, 8), calendar: calendar).count, 1)
        XCTAssertTrue(WidgetSnapshotQueries.remainingReminders(in: snapshot(nil), now: date(6, 8), calendar: calendar).isEmpty)
    }
    func test_weeklySnapshotDoesNotRepeatOnWrongDay() {
        let s = snapshot(.weekly([2])) // 10月5日周一，6日周二
        XCTAssertEqual(WidgetSnapshotQueries.remainingReminders(in: s, now: date(5, 8), calendar: calendar).count, 1)
        XCTAssertTrue(WidgetSnapshotQueries.remainingReminders(in: s, now: date(6, 8), calendar: calendar).isEmpty)
        XCTAssertEqual(WidgetSnapshotQueries.remainingReminders(in: s, now: date(12, 8), calendar: calendar).count, 1)
    }
    func test_timelineContainsMidnightsAndReminderBoundaries() {
        let s = snapshot(.daily)
        let dates = WidgetSnapshotQueries.timelineDates(in: s, now: date(5, 8), calendar: calendar)
        XCTAssertTrue(dates.contains(date(5, 9))); XCTAssertTrue(dates.contains(date(6))); XCTAssertTrue(dates.contains(date(6, 9)))
        XCTAssertTrue(WidgetSnapshotQueries.remainingReminders(in: s, now: date(5, 9), calendar: calendar).isEmpty)
    }
    func test_advanceOnPriorDayAndPausedAreHandled() {
        var s = snapshot(.once(at: date(8, 9))); s.reminders[0].advance = .d3
        let events = WidgetSnapshotQueries.remainingReminders(in: s, now: date(5, 8), calendar: calendar)
        XCTAssertEqual(events.count, 1); XCTAssertEqual(events.first?.isAdvance, true)
        s.reminders[0].isEnabled = false
        XCTAssertTrue(WidgetSnapshotQueries.remainingReminders(in: s, now: date(5, 8), calendar: calendar).isEmpty)
    }
    func test_prunesOnlyUnusedSharedAvatars() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let avatars = dir.appendingPathComponent(WidgetSnapshotStore.avatarsDirName)
        try FileManager.default.createDirectory(at: avatars, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data([1]).write(to: avatars.appendingPathComponent("old.jpg")); try Data([1]).write(to: avatars.appendingPathComponent("used.jpg"))
        try WidgetSnapshotStore.pruneAvatars(keeping: ["used.jpg"], in: dir)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: avatars.path), ["used.jpg"])
    }
}

final class DataVersionMigrationTests: XCTestCase {
    private func legacyStore(at url: URL) throws -> UUID {
        let momd = try XCTUnwrap(Bundle.main.url(forResource: "PetPal", withExtension: "momd"))
        let model = try XCTUnwrap(NSManagedObjectModel(contentsOf: momd.appendingPathComponent("PetPal.mom")))
        let container = NSPersistentContainer(name: "Legacy", managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: url); description.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [description]
        var error: Error?; container.loadPersistentStores { _, failure in error = failure }; if let error { throw error }
        let petID = UUID(); let recordID = UUID(); let now = Date()
        let pet = NSEntityDescription.insertNewObject(forEntityName: "CDPet", into: container.viewContext)
        pet.setValue(petID, forKey: "id"); pet.setValue("旧宠物", forKey: "nickname"); pet.setValue(now, forKey: "createdAt")
        let record = NSEntityDescription.insertNewObject(forEntityName: "CDRecord", into: container.viewContext)
        record.setValue(recordID, forKey: "id"); record.setValue(petID, forKey: "petID"); record.setValue("体检", forKey: "kind")
        record.setValue(["weightKg": "8"], forKey: "answers"); record.setValue(now, forKey: "createdAt")
        let weight = NSEntityDescription.insertNewObject(forEntityName: "CDWeightSample", into: container.viewContext)
        weight.setValue(UUID(), forKey: "id"); weight.setValue(petID, forKey: "petID"); weight.setValue(8.0, forKey: "kg"); weight.setValue(now, forKey: "date")
        let reminder = NSEntityDescription.insertNewObject(forEntityName: "CDReminder", into: container.viewContext)
        reminder.setValue(UUID(), forKey: "id"); reminder.setValue(petID, forKey: "petID"); reminder.setValue("喂食", forKey: "type")
        reminder.setValue(String(data: try JSONEncoder().encode(RepeatRule.daily), encoding: .utf8), forKey: "repeatRule")
        reminder.setValue("准时", forKey: "advance")
        try container.viewContext.save(); container.viewContext.reset()
        for store in container.persistentStoreCoordinator.persistentStores { try container.persistentStoreCoordinator.remove(store) }
        return petID
    }
    func test_v1SQLiteMigratesAndLinksUniqueLegacyWeight() throws {
        let dir = try PortableBackup.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("legacy.sqlite"); let petID = try legacyStore(at: url)
        let stack = CoreDataStack(storeURL: url); XCTAssertNil(stack.loadError)
        let reminders = try CoreDataReminderRepository(stack: stack).allReminders()
        XCTAssertEqual(reminders.count, 1); XCTAssertTrue(reminders[0].isEnabled)
        let sample = try XCTUnwrap(CoreDataWeightRepository(stack: stack).samples(petID: petID).first)
        XCTAssertNotNil(sample.sourceRecordID)
        var record: PetPal.Record?; let repo = CoreDataRecordRepository(stack: stack)
        let subscription = repo.recordsPublisher(petID: petID).sink { record = $0.first }; defer { subscription.cancel() }
        var edited = try XCTUnwrap(record); edited.answers["weightKg"] = "9"; try repo.update(edited)
        XCTAssertEqual(try CoreDataWeightRepository(stack: stack).samples(petID: petID).map(\.kg), [9])
    }
    func test_v1PortableBackupRestoresThroughStagedMigration() throws {
        let dir = try PortableBackup.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("legacy.sqlite"); let petID = try legacyStore(at: url)
        let archive = PortableBackup(createdAt: Date(), appVersion: "1.0", currentPetID: petID, database: .init(try Data(contentsOf: url)), media: [:])
        let target = CoreDataStack(storeURL: dir.appendingPathComponent("target.sqlite"))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "Migration-\(UUID())"))
        try PortableBackup.restore(JSONEncoder().encode(archive), stack: target, mediaDirectory: dir, defaults: defaults)
        XCTAssertNil(target.loadError)
        XCTAssertEqual(try target.container.viewContext.fetch(CDPet.fetchRequest()).first?.nickname, "旧宠物")
        XCTAssertNotNil(try CoreDataWeightRepository(stack: target).samples(petID: petID).first?.sourceRecordID)
        XCTAssertTrue(try CoreDataReminderRepository(stack: target).allReminders()[0].isEnabled)
    }
    func test_ambiguousLegacyWeightIsPreservedWithoutGuessing() throws {
        let stack = CoreDataStack(inMemory: true); let record = Record(petID: UUID(), kind: .checkup, answers: ["weightKg": "8"])
        let e = stack.insert(CDRecord.self); e.id = record.id; e.petID = record.petID; e.kind = "体检"; e.answers = record.answers; e.createdAt = record.createdAt
        for _ in 0..<2 { let s = stack.insert(CDWeightSample.self); s.id = UUID(); s.petID = record.petID; s.date = record.createdAt; s.kg = 8 }
        try stack.save(); try HealthDataMigration.linkLegacyWeights(in: stack.container.viewContext)
        XCTAssertTrue(try stack.container.viewContext.fetch(CDWeightSample.fetchRequest()).allSatisfy { $0.sourceRecordID == nil })
    }
}

final class FollowupBackupAndMediaTests: XCTestCase {
    func test_v2BackupPreservesRecordSchemaWeightSourceAndPausedReminder() throws {
        let dir = try PortableBackup.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = CoreDataStack(storeURL: dir.appendingPathComponent("source.sqlite"))
        let pet = Pet(nickname: "小白", breed: "柯基"); try CoreDataPetRepository(stack: source).create(pet)
        let records = CoreDataRecordRepository(stack: source)
        let checkup = Record(petID: pet.id, kind: .checkup, answers: ["weightKg": "8"]); try records.create(checkup)
        let template = CustomTemplate(name: "健康观察", fields: [.init(title: "状态", type: .text)])
        let custom = Record(petID: pet.id, kind: .custom, answers: [template.fields[0].id.uuidString: "正常"], templateName: template.name,
                            templateID: template.id, templateSnapshot: template, templateSchemaVersion: 1)
        try records.create(custom)
        let vaccine = Record(petID: pet.id, kind: .vaccine, answers: ["nextDue": "2030-03-01"], wantsNextReminder: true)
        try records.create(vaccine)
        let reminders = CoreDataReminderRepository(stack: source)
        var reminder = try XCTUnwrap(reminders.allReminders().first); reminder.isEnabled = false; try reminders.save(reminder)
        let suite = "FollowupBackup-\(UUID())"; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let data = try PortableBackup.create(stack: source, mediaDirectory: dir, defaults: defaults)
        let target = CoreDataStack(storeURL: dir.appendingPathComponent("target.sqlite"))
        try PortableBackup.restore(data, stack: target, mediaDirectory: dir, defaults: defaults)
        XCTAssertEqual(try CoreDataWeightRepository(stack: target).samples(petID: pet.id).first?.sourceRecordID, checkup.id)
        let restoredReminder = try XCTUnwrap(CoreDataReminderRepository(stack: target).allReminders().first)
        XCTAssertEqual(restoredReminder.sourceRecordID, vaccine.id); XCTAssertFalse(restoredReminder.isEnabled)
        let restoredCustom = try XCTUnwrap(target.container.viewContext.fetch(CDRecord.fetchRequest()).first { $0.id == custom.id })
        XCTAssertEqual(restoredCustom.templateID, template.id); XCTAssertEqual(restoredCustom.templateSchemaVersion, 1)
        XCTAssertNotNil(restoredCustom.templateSnapshot)
    }
    func test_backupWithOrphanWeightSourceIsRejectedAndLiveDataSurvives() throws {
        let dir = try PortableBackup.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = CoreDataStack(storeURL: dir.appendingPathComponent("source.sqlite"))
        let pet = Pet(nickname: "备份宠物", breed: "柯基"); try CoreDataPetRepository(stack: source).create(pet)
        try CoreDataRecordRepository(stack: source).create(Record(petID: pet.id, kind: .checkup, answers: ["weightKg": "8"]))
        var archive = try JSONDecoder().decode(PortableBackup.self, from: PortableBackup.create(stack: source, mediaDirectory: dir))
        let tamperedURL = dir.appendingPathComponent("tampered.sqlite"); try archive.database.data.write(to: tamperedURL)
        let tampered = CoreDataStack(storeURL: tamperedURL)
        let sample = try XCTUnwrap(tampered.container.viewContext.fetch(CDWeightSample.fetchRequest()).first)
        sample.sourceRecordID = UUID(); try tampered.save()
        tampered.container.viewContext.reset()
        for store in tampered.container.persistentStoreCoordinator.persistentStores { try tampered.container.persistentStoreCoordinator.remove(store) }
        archive.database = .init(try Data(contentsOf: tamperedURL))
        let target = CoreDataStack(storeURL: dir.appendingPathComponent("target.sqlite"))
        try CoreDataPetRepository(stack: target).create(Pet(nickname: "原数据", breed: "柯基"))
        XCTAssertThrowsError(try PortableBackup.restore(JSONEncoder().encode(archive), stack: target, mediaDirectory: dir))
        XCTAssertEqual(try target.container.viewContext.fetch(CDPet.fetchRequest()).map(\.nickname), ["原数据"])
    }
    func test_recordDeletionCleansPhotoOnlyAfterDatabaseCommit() throws {
        var fail = false
        let stack = CoreDataStack(inMemory: true, saveHandler: { ctx in if fail { throw NSError(domain: "disk", code: 1) }; try ctx.save() })
        let repo = CoreDataRecordRepository(stack: stack)
        let photo = try XCTUnwrap(AvatarStore.save(AvatarStoreTests.makeImage())); defer { AvatarStore.delete(fileName: photo) }
        let r = Record(petID: UUID(), kind: .checkup, answers: ["weightKg": "8"], photoFileNames: [photo]); try repo.create(r)
        fail = true; XCTAssertThrowsError(try repo.delete(id: r.id))
        XCTAssertNotNil(AvatarStore.load(fileName: photo)); XCTAssertEqual(try stack.container.viewContext.fetch(CDRecord.fetchRequest()).count, 1)
        fail = false; try repo.delete(id: r.id); XCTAssertNil(AvatarStore.load(fileName: photo))
    }
    @MainActor func test_failedPetDeleteKeepsReminderConfigurationAndSkipsCleanup() throws {
        var fail = false
        let stack = CoreDataStack(inMemory: true, saveHandler: { ctx in if fail { throw NSError(domain: "disk", code: 1) }; try ctx.save() })
        let repo = CoreDataPetRepository(stack: stack); let vm = PetListViewModel(repo: repo)
        let reminders = CoreDataReminderRepository(stack: stack)
        let pet = Pet(nickname: "小白", breed: "柯基"); try repo.create(pet)
        try reminders.save(Reminder(petID: pet.id, type: .feeding, hour: 9, minute: 0))
        var cleanupCalled = false; vm.reminderCleanup = { _ in cleanupCalled = true }
        fail = true; XCTAssertFalse(vm.delete(pet)); XCTAssertFalse(cleanupCalled)
        XCTAssertEqual(try reminders.allReminders().count, 1)
    }
}
