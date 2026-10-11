import XCTest
import CoreData
import Combine
import UserNotifications
@testable import PetPal

@MainActor final class RecordTaskTests: XCTestCase {
    private var cal: Calendar { Calendar.current }
    private func day(_ offset: Int, hour: Int = 9) -> Date {
        let base = cal.date(byAdding: .day, value: offset, to: Date())!
        return cal.date(bySettingHour: hour, minute: 0, second: 0, of: base)!
    }
    private func close(_ stack: CoreDataStack) throws {
        stack.container.viewContext.reset()
        for store in stack.container.persistentStoreCoordinator.persistentStores {
            try stack.container.persistentStoreCoordinator.remove(store)
        }
    }
    private func completion(_ reminder: Reminder, due: Date) -> PetPal.Record {
        PetPal.Record(petID: reminder.petID, kind: reminder.type.recordKind,
               answers: ["food": "粮", "grams": "50", "mealTime": "早", "drug": "药", "dose": "按医嘱", "vaccineName": "疫苗"],
               occurredAt: Date(), completedReminderID: reminder.id, completedDueAt: due,
               completedDay: ReminderTaskKey.day(rule: reminder.repeatRule, due: due))
    }
    func test_backdateAndEditMoveCalendarAndDerivedWeightWithoutChangingCreation() throws {
        let stack = CoreDataStack(inMemory: true)
        let repo = CoreDataRecordRepository(stack: stack)
        var record = PetPal.Record(petID: UUID(), kind: .checkup, answers: ["weightKg": "8"], occurredAt: day(-30))
        let created = record.createdAt
        try repo.create(record)
        var loaded: [PetPal.Record] = []
        let sub = repo.recordsPublisher(petID: record.petID).sink { loaded = $0 }; defer { sub.cancel() }
        XCTAssertEqual(loaded.first?.eventDate, day(-30))
        XCTAssertEqual(CalendarGridBuilder.countsByDay(loaded)[cal.startOfDay(for: day(-30))], 1)
        record.eventDate = day(-60); record.answers["weightKg"] = "9"
        try repo.update(record)
        XCTAssertEqual(loaded.first?.createdAt, created)
        XCTAssertEqual(TimelineGrouper.group(loaded).first?.day, cal.startOfDay(for: day(-60)))
        XCTAssertNil(CalendarGridBuilder.countsByDay(loaded)[cal.startOfDay(for: day(-30))])
        let weights = try CoreDataWeightRepository(stack: stack).samples(petID: record.petID)
        XCTAssertEqual(weights.count, 1); XCTAssertEqual(weights.first?.date, day(-60)); XCTAssertEqual(weights.first?.kg, 9)
    }
    func test_legacyDateFallbackAndCustomRecordBackdate() throws {
        let old = PetPal.Record(createdAt: day(-50))
        XCTAssertEqual(old.eventDate, old.createdAt)
        let stack = CoreDataStack(inMemory: true)
        let vm = RecordFormViewModel(repo: CoreDataRecordRepository(stack: stack), petID: UUID(), kind: .custom, validationFields: [])
        vm.draft.eventDate = day(-20)
        XCTAssertTrue(vm.save())
        XCTAssertEqual(try stack.container.viewContext.fetch(CDRecord.fetchRequest()).first?.occurredAt, day(-20))
    }
    func test_invalidAndFutureOccurrenceDatesRejectedWithoutWriting() throws {
        let stack = CoreDataStack(inMemory: true); let repo = CoreDataRecordRepository(stack: stack)
        for date in [day(1), Date(timeIntervalSinceReferenceDate: .infinity)] {
            XCTAssertThrowsError(try repo.create(PetPal.Record(petID: UUID(), kind: .checkup, occurredAt: date)))
        }
        XCTAssertEqual(try stack.container.viewContext.count(for: CDRecord.fetchRequest()), 0)
    }
    func test_recordAndCompletionAreAtomicAndRetryableOnSaveFailure() throws {
        var fail = false
        let stack = CoreDataStack(inMemory: true, saveHandler: { if fail { throw NSError(domain: "Disk", code: 1) }; try $0.save() })
        let reminders = CoreDataReminderRepository(stack: stack)
        let reminder = Reminder(petID: UUID(), type: .feeding, hour: 9, minute: 0, repeatRule: .once(at: day(-1)))
        try reminders.save(reminder)
        let repo = CoreDataRecordRepository(stack: stack)
        let record = completion(reminder, due: day(-1))
        fail = true
        XCTAssertThrowsError(try repo.create(record))
        XCTAssertTrue(try reminders.completedRecords().isEmpty)
        XCTAssertEqual(try stack.container.viewContext.count(for: CDRecord.fetchRequest()), 0)
        fail = false; try repo.create(record)
        XCTAssertEqual(try reminders.completedRecords().count, 1)
    }
    func test_duplicateCompletionRejectedAndDeletingRecordReopensTask() throws {
        let stack = CoreDataStack(inMemory: true); let reminders = CoreDataReminderRepository(stack: stack)
        let reminder = Reminder(petID: UUID(), type: .feeding, hour: 9, minute: 0, repeatRule: .once(at: day(-1)))
        try reminders.save(reminder)
        let repo = CoreDataRecordRepository(stack: stack); let record = completion(reminder, due: day(-1))
        try repo.create(record)
        XCTAssertThrowsError(try repo.create(completion(reminder, due: day(-1))))
        var tasks = ReminderTaskBuilder.tasks(reminders: try reminders.allReminders(), records: try reminders.completedRecords(), petID: reminder.petID)
        XCTAssertEqual(tasks.first?.status(now: Date()), .done)
        try repo.delete(id: record.id)
        tasks = ReminderTaskBuilder.tasks(reminders: try reminders.allReminders(), records: try reminders.completedRecords(), petID: reminder.petID)
        XCTAssertEqual(tasks.first?.status(now: Date()), .overdue)
    }
    func test_completionRejectsWrongPetKindPausedAndChangedSchedule() throws {
        let stack = CoreDataStack(inMemory: true); let reminders = CoreDataReminderRepository(stack: stack)
        var reminder = Reminder(petID: UUID(), type: .feeding, hour: 9, minute: 0, repeatRule: .once(at: day(-1)))
        try reminders.save(reminder)
        let repo = CoreDataRecordRepository(stack: stack)
        var record = completion(reminder, due: day(-1)); record.petID = UUID()
        XCTAssertThrowsError(try repo.create(record))
        record = completion(reminder, due: day(-1)); record.kind = .checkup
        XCTAssertThrowsError(try repo.create(record))
        reminder.isEnabled = false; try reminders.save(reminder)
        XCTAssertThrowsError(try repo.create(completion(reminder, due: day(-1))))
        reminder.isEnabled = true; reminder.repeatRule = .once(at: day(-2)); try reminders.save(reminder)
        XCTAssertThrowsError(try repo.create(completion(reminder, due: day(-1))))
    }
    func test_dailyCompletionOnlyCompletesItsOwnOccurrenceAndPet() {
        let pet = UUID()
        let reminder = Reminder(petID: pet, type: .feeding, hour: 9, minute: 0, trackingSince: day(-2))
        var record = completion(reminder, due: day(-1)); record.createdAt = day(-1)
        let tasks = ReminderTaskBuilder.tasks(reminders: [reminder], records: [record], petID: pet, now: day(0, hour: 10))
        XCTAssertEqual(tasks.map(\.due), [day(-2), day(0)])
        XCTAssertTrue(tasks.allSatisfy { $0.status(now: day(0, hour: 10)) == .overdue })
        XCTAssertTrue(ReminderTaskBuilder.tasks(reminders: [reminder], records: [record], petID: UUID()).isEmpty)
    }
    func test_earlyCompletionSkipsNotificationButPreservesNextDayAndAdvance() {
        let reminder = Reminder(petID: UUID(), type: .feeding, hour: 9, minute: 0, advance: .m15)
        let record = completion(reminder, due: day(0))
        let plan = ReminderSchedulePlan.build([reminder], now: day(0, hour: 8), completedKeys: [record.completionKey!])
        let dates = plan.requests.compactMap { ($0.trigger as? UNCalendarNotificationTrigger).flatMap { cal.date(from: $0.dateComponents) } }
        XCTAssertFalse(dates.contains(day(0)))
        XCTAssertFalse(dates.contains(day(0).addingTimeInterval(-900)))
        XCTAssertTrue(dates.contains(day(1)))
        XCTAssertTrue(dates.contains(day(1).addingTimeInterval(-900)))
        let tomorrow = ReminderSchedulePlan.build([reminder], now: day(1, hour: 8), completedKeys: [record.completionKey!])
        XCTAssertTrue(tomorrow.requests.allSatisfy { ($0.trigger as? UNCalendarNotificationTrigger)?.repeats == true })
    }
    func test_onceRescheduleDoesNotReuseOldCompletionAndTimezoneKeepsIdentity() {
        var reminder = Reminder(petID: UUID(), type: .vaccine, hour: 9, minute: 0, repeatRule: .once(at: day(-1)))
        let record = completion(reminder, due: day(-1))
        var remote = Calendar(identifier: .gregorian); remote.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertEqual(ReminderTaskKey.day(rule: reminder.repeatRule, due: day(-1)), ReminderTaskKey.day(rule: reminder.repeatRule, due: day(-1), calendar: remote))
        reminder.repeatRule = .once(at: day(0))
        let tasks = ReminderTaskBuilder.tasks(reminders: [reminder], records: [record], petID: reminder.petID, now: day(0, hour: 8))
        XCTAssertEqual(tasks.first?.status(now: day(0, hour: 8)), .pending)
    }
    func test_widgetOmitsCompletedOccurrenceAndShowsTomorrow() {
        let reminder = Reminder(petID: UUID(), type: .feeding, hour: 9, minute: 0)
        let record = completion(reminder, due: day(0))
        let snapshot = WidgetSnapshot(generatedAt: day(0), currentPetID: reminder.petID,
            pets: [.init(id: reminder.petID, nickname: "小白", species: "狗")],
            reminders: [.init(id: reminder.id, petID: reminder.petID, petName: "小白", type: "喂食", hour: 9, minute: 0, repeatRule: .daily)],
            completedTaskKeys: [record.completionKey!])
        XCTAssertTrue(WidgetSnapshotQueries.remainingReminders(in: snapshot, now: day(0, hour: 8)).isEmpty)
        XCTAssertEqual(WidgetSnapshotQueries.remainingReminders(in: snapshot, now: day(1, hour: 8)).count, 1)
    }
    func test_healthHistoryAlwaysDoneAndIncludesDewormingWithSeparateNextPlan() {
        let vaccine = PetPal.Record(kind: .vaccine, answers: ["vaccineName": "疫苗", "nextDue": "2020-01-01"], occurredAt: day(-30))
        let deworm = PetPal.Record(kind: .deworming, answers: ["drug": "驱虫药", "nextDue": "2030-01-01"], occurredAt: day(-20))
        let events = HealthEvent.build(records: [deworm, vaccine], reminders: [])
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events.allSatisfy { $0.status == .done })
        XCTAssertEqual(events.first?.date, day(-30))
        XCTAssertEqual(events.first?.nextStatus(), .overdue)
        XCTAssertEqual(events.last?.nextStatus(), .pending)
    }
    func test_healthNextPlanUsesItsCompletionAndDoesNotCompleteAnotherSource() {
        let source = PetPal.Record(petID: UUID(), kind: .vaccine, answers: ["nextDue": "2020-01-01"])
        let reminder = Reminder(petID: source.petID, type: .vaccine, hour: 9, minute: 0, repeatRule: .once(at: day(-1)), sourceRecordID: source.id)
        let record = completion(reminder, due: day(-1))
        let events = HealthEvent.build(records: [source, record], reminders: [reminder])
        XCTAssertEqual(events.first { $0.id == source.id }?.nextStatus(), .done)
        XCTAssertNil(events.first { $0.id == record.id }?.nextStatus())
        XCTAssertEqual(HealthEvent.build(records: [source], reminders: [reminder]).first?.nextStatus(), .overdue)
    }
    func test_editExpiredSourceAllowsUnchangedReminderButRejectsNewPastDate() throws {
        let stack = CoreDataStack(inMemory: true)
        let entity = stack.insert(CDRecord.self)
        let record = PetPal.Record(petID: UUID(), kind: .vaccine, answers: ["vaccineName": "疫苗", "nextDue": "2020-01-01"], wantsNextReminder: true)
        record.apply(to: entity); try stack.save()
        var edited = record; edited.eventDate = day(-50); edited.note = "补充说明"
        let repo = CoreDataRecordRepository(stack: stack)
        try repo.update(edited)
        edited.answers["nextDue"] = "2020-01-02"
        XCTAssertThrowsError(try repo.update(edited))
    }
    func test_backupRoundTripKeepsOccurrenceDateAndCompletion() throws {
        let dir = try PortableBackup.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = CoreDataStack(storeURL: dir.appendingPathComponent("source.sqlite")); defer { try? close(source) }
        let pet = Pet(nickname: "小白", breed: "柯基"); try CoreDataPetRepository(stack: source).create(pet)
        let reminder = Reminder(petID: pet.id, type: .feeding, hour: 9, minute: 0, repeatRule: .once(at: day(-1)))
        try CoreDataReminderRepository(stack: source).save(reminder)
        var record = completion(reminder, due: day(-1)); record.eventDate = day(-1)
        try CoreDataRecordRepository(stack: source).create(record)
        let data = try PortableBackup.create(stack: source, mediaDirectory: dir)
        let target = CoreDataStack(storeURL: dir.appendingPathComponent("target.sqlite")); defer { try? close(target) }
        let suite = "B123-\(UUID())"; let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        try PortableBackup.restore(data, stack: target, mediaDirectory: dir, defaults: defaults)
        let restored = try CoreDataReminderRepository(stack: target).completedRecords()
        XCTAssertEqual(restored.first?.eventDate, day(-1))
        XCTAssertEqual(restored.first?.completionKey, record.completionKey)
        XCTAssertEqual(ReminderTaskBuilder.tasks(reminders: try CoreDataReminderRepository(stack: target).allReminders(), records: restored, petID: pet.id).first?.status(now: Date()), .done)
    }
    func test_v2DatabaseAndBackupMigrateDatesAndStartTrackingToday() throws {
        let dir = try PortableBackup.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let modelURL = try XCTUnwrap(Bundle.main.url(forResource: "PetPal", withExtension: "momd"))
        let model = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelURL.appendingPathComponent("PetPalV2.mom")))
        let url = dir.appendingPathComponent("v2.sqlite")
        let legacy = NSPersistentContainer(name: "Legacy", managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: url); description.shouldAddStoreAsynchronously = false
        legacy.persistentStoreDescriptions = [description]
        var failure: Error?; legacy.loadPersistentStores { _, error in failure = error }; if let failure { throw failure }
        let petID = UUID()
        func row(_ name: String, _ values: [String: Any]) {
            let object = NSEntityDescription.insertNewObject(forEntityName: name, into: legacy.viewContext)
            values.forEach { object.setValue($0.value, forKey: $0.key) }
        }
        row("CDPet", ["id": petID, "nickname": "旧宠物", "weightKg": 8.0])
        row("CDRecord", ["id": UUID(), "petID": petID, "kind": "体检", "createdAt": day(-60), "answers": ["weightKg": "8"]])
        row("CDReminder", ["id": UUID(), "petID": petID, "type": "喂食", "hour": 9, "repeatRule": String(data: try JSONEncoder().encode(RepeatRule.daily), encoding: .utf8)!, "advance": "准时"])
        try legacy.viewContext.save(); legacy.viewContext.reset()
        for store in legacy.persistentStoreCoordinator.persistentStores { try legacy.persistentStoreCoordinator.remove(store) }
        let archive = PortableBackup(createdAt: Date(), appVersion: "1.0", currentPetID: petID, database: .init(try Data(contentsOf: url)), media: [:])
        let upgraded = CoreDataStack(storeURL: url); defer { try? close(upgraded) }
        XCTAssertNil(upgraded.loadError)
        let stored = try XCTUnwrap(upgraded.container.viewContext.fetch(CDRecord.fetchRequest()).first)
        XCTAssertEqual(PetPal.Record(stored).eventDate, day(-60)); XCTAssertNil(stored.occurredAt)
        let reminders = try CoreDataReminderRepository(stack: upgraded).allReminders()
        XCTAssertTrue(cal.isDateInToday(try XCTUnwrap(reminders.first?.trackingSince)))
        XCTAssertEqual(ReminderTaskBuilder.tasks(reminders: reminders, records: [], petID: petID).count, 1)
        let prepared = try PortableBackup.prepareRestore(JSONEncoder().encode(archive), model: upgraded.container.managedObjectModel, mediaDirectory: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.databaseURL.path))
    }
    func test_changedReminderTimeOrTypeDoesNotInheritCompletion() {
        let original = Reminder(petID: UUID(), type: .feeding, hour: 9, minute: 0)
        let record = completion(original, due: day(0))
        var changed = original; changed.hour = 10
        var tasks = ReminderTaskBuilder.tasks(reminders: [changed], records: [record], petID: changed.petID, now: day(0, hour: 8))
        XCTAssertNil(tasks.first?.record)
        changed = original; changed.type = .medication
        tasks = ReminderTaskBuilder.tasks(reminders: [changed], records: [record], petID: changed.petID, now: day(0, hour: 8))
        XCTAssertNil(tasks.first?.record)
        let plan = ReminderSchedulePlan.build([changed], now: day(0, hour: 8), completedKeys: [record.completionKey!])
        XCTAssertTrue(plan.requests.allSatisfy { ($0.trigger as? UNCalendarNotificationTrigger)?.repeats == true })
    }
    func test_editCompletionDateKeepsTaskIdentityAndCreationDate() throws {
        let stack = CoreDataStack(inMemory: true)
        let reminders = CoreDataReminderRepository(stack: stack)
        let reminder = Reminder(petID: UUID(), type: .feeding, hour: 9, minute: 0, repeatRule: .once(at: day(-1)))
        try reminders.save(reminder)
        let repo = CoreDataRecordRepository(stack: stack)
        var record = completion(reminder, due: day(-1)); try repo.create(record)
        let key = record.completionKey; let created = record.createdAt
        record.eventDate = day(-1); try repo.update(record)
        let stored = try XCTUnwrap(reminders.completedRecords().first)
        XCTAssertEqual(stored.completionKey, key); XCTAssertEqual(stored.createdAt, created)
        XCTAssertEqual(stored.eventDate, day(-1))
        record.completedDueAt = day(-2)
        XCTAssertThrowsError(try repo.update(record))
    }
    func test_calendarCanReachBackdatedRecordsOlderThanTwoYears() async throws {
        let stack = CoreDataStack(inMemory: true); let repo = CoreDataRecordRepository(stack: stack)
        let old = cal.date(byAdding: .year, value: -3, to: Date())!
        let record = PetPal.Record(petID: UUID(), kind: .checkup, occurredAt: old)
        try repo.create(record)
        let model = RecordCalendarViewModel(repo: repo, petID: record.petID)
        let ready = expectation(description: "历史月份已发布")
        let subscription = model.$months.filter { $0.count > 1 }.prefix(1).sink { _ in ready.fulfill() }
        defer { subscription.cancel() }
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertGreaterThan(model.months.count, 24)
        XCTAssertEqual(model.counts[cal.startOfDay(for: old)], 1)
    }
    func test_notificationTaskDeepLinkWaitsForPetSelection() {
        let router = DeepLinkRouter(); let pet = UUID()
        router.handle(url: URL(string: "petpal://tasks/\(pet.uuidString)")!)
        XCTAssertEqual(router.tasksPetID, pet)
        XCTAssertTrue(router.path.isEmpty)
    }
}
