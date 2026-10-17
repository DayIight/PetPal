import XCTest
import CoreData
import UserNotifications
@testable import PetPal

@MainActor final class MedicationCourseTests: XCTestCase {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return result
    }
    private func date(_ day: Int, hour: Int = 0, month: Int = 3) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }
    private func course(petID: UUID, start: Date? = nil, end: Date? = nil) -> MedicationCourse {
        MedicationCourse(petID: petID, drugName: "主人填写的药名", doseInstructions: "遵照已获医嘱填写",
                         startDate: start ?? date(7), endDate: end ?? date(9),
                         times: [.init(hour: 8, minute: 0), .init(hour: 20, minute: 0)])
    }
    private func setup() throws -> (CoreDataStack, Pet, MedicationCourseStore) {
        let stack = CoreDataStack(inMemory: true)
        let pet = Pet(nickname: "豆豆", breed: "柯基")
        try CoreDataPetRepository(stack: stack).create(pet)
        return (stack, pet, MedicationCourseStore(stack: stack))
    }

    func test_dailyWindowIncludesBothCalendarDaysAndKeepsLocalTimeAcrossDST() {
        let rule = RepeatRule.dailyWindow(start: date(7), end: date(9))
        let dates = ReminderRecurrence.dates(rule: rule, hour: 8, minute: 0, after: date(6), through: date(11), calendar: calendar)
        XCTAssertEqual(dates, [date(7, hour: 8), date(8, hour: 8), date(9, hour: 8)])
        XCTAssertEqual(dates[1].timeIntervalSince(dates[0]), 23 * 3600)
        XCTAssertTrue(rule.usesRollingSchedule)
    }
    func test_windowValidationRejectsReversedAndNonFiniteBounds() {
        XCTAssertNotNil(ReminderRecurrence.validationError(rule: .dailyWindow(start: date(9), end: date(7)), hour: 8, minute: 0, advance: .none))
        XCTAssertNotNil(ReminderRecurrence.validationError(rule: .dailyWindow(start: .init(timeIntervalSinceReferenceDate: .infinity), end: date(9)), hour: 8, minute: 0, advance: .none))
    }
    func test_courseValidatesOneToSixUniqueSlotsAndMaximum180InclusiveDays() {
        var value = course(petID: UUID())
        XCTAssertNil(value.validationError)
        value.times = []; XCTAssertNotNil(value.validationError)
        value.times = [.init(hour: 8, minute: 0), .init(hour: 8, minute: 0)]; XCTAssertNotNil(value.validationError)
        value.times = (0...6).map { .init(hour: $0, minute: 0) }; XCTAssertNotNil(value.validationError)
        value.times = [.init(hour: 8, minute: 0)]
        value.startDate = Calendar.current.startOfDay(for: Date())
        value.endDate = Calendar.current.date(byAdding: .day, value: 179, to: value.startDate)!
        XCTAssertNil(value.validationError)
        value.endDate = Calendar.current.date(byAdding: .day, value: 180, to: value.startDate)!
        XCTAssertNotNil(value.validationError)
    }
    func test_careCardOnlyIncludesActiveCourseOnItsInclusiveLocalDays() {
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 2, to: start)!
        var value = course(petID: UUID(), start: start, end: end)
        XCTAssertFalse(value.isActive(at: start.addingTimeInterval(-1)))
        XCTAssertTrue(value.isActive(at: start))
        XCTAssertTrue(value.isActive(at: end.addingTimeInterval(12 * 3600)))
        XCTAssertTrue(value.careCardSummary.contains("主人填写的药名"))
        XCTAssertTrue(value.careCardSummary.contains("08:00"))
        value.status = .paused; XCTAssertFalse(value.isActive(at: start))
        value.status = .ended; XCTAssertFalse(value.isActive(at: start))
    }
    func test_finiteSchedulingNeverRepeatsOrEscapesEndAndGlobalBudgetIs64() {
        let reminder = Reminder(petID: UUID(), type: .medication, hour: 8, minute: 0,
                                repeatRule: .dailyWindow(start: date(7), end: date(9)))
        let plan = ReminderSchedulePlan.build([reminder], now: date(6), calendar: calendar)
        XCTAssertEqual(plan.requests.count, 3)
        XCTAssertTrue(plan.requests.allSatisfy { ($0.trigger as? UNCalendarNotificationTrigger)?.repeats == false })
        XCTAssertEqual(plan.scheduledThrough[reminder.id], date(9, hour: 8))
        var long = reminder
        long.repeatRule = .dailyWindow(start: date(7), end: calendar.date(byAdding: .day, value: 179, to: date(7))!)
        XCTAssertEqual(ReminderSchedulePlan.build([long], now: date(6), calendar: calendar).requests.count, 64)
        XCTAssertTrue(ReminderSchedulePlan.build([reminder], now: date(10), calendar: calendar).requests.isEmpty)
    }
    func test_widgetHidesCourseOutsideWindowAndPreservesOccurrenceIdentity() {
        let petID = UUID(), id = UUID()
        let rule = RepeatRule.dailyWindow(start: date(7), end: date(9))
        let snapshot = WidgetSnapshot(generatedAt: date(6), currentPetID: petID,
            pets: [.init(id: petID, nickname: "豆豆", species: "狗")],
            reminders: [.init(id: id, petID: petID, petName: "豆豆", type: "服药", hour: 8, minute: 0, repeatRule: rule, advance: .none, isEnabled: true)])
        XCTAssertTrue(WidgetSnapshotQueries.remainingReminders(in: snapshot, now: date(6), calendar: calendar).isEmpty)
        XCTAssertEqual(WidgetSnapshotQueries.remainingReminders(in: snapshot, now: date(9), calendar: calendar).count, 1)
        XCTAssertTrue(WidgetSnapshotQueries.remainingReminders(in: snapshot, now: date(10), calendar: calendar).isEmpty)
        XCTAssertEqual(ReminderTaskKey.day(rule: rule, due: date(9, hour: 8), calendar: calendar), "2026-03-09T08:00")
    }
    func test_createPersistsCourseAndSlotsInOneSaveAndScopesByPet() throws {
        var saves = 0
        let stack = CoreDataStack(inMemory: true, saveHandler: { saves += 1; try $0.save() })
        let pet = Pet(nickname: "豆豆", breed: "柯基")
        try CoreDataPetRepository(stack: stack).create(pet)
        let store = MedicationCourseStore(stack: stack)
        let before = saves
        let saved = try store.save(course(petID: pet.id), petName: pet.nickname)
        XCTAssertEqual(saves - before, 1)
        XCTAssertEqual(try store.courses(petID: pet.id), [saved])
        XCTAssertTrue(try store.courses(petID: UUID()).isEmpty)
        XCTAssertEqual(try CoreDataReminderRepository(stack: stack).allReminders().count, 2)
        XCTAssertEqual(Set(saved.reminderIDs).count, 2)
    }
    func test_editKeepsUnchangedSlotIdentityAndRetainsRemovedReminderDisabled() throws {
        let (stack, pet, store) = try setup()
        let first = try store.save(course(petID: pet.id), petName: pet.nickname)
        var edit = first; edit.times = [.init(hour: 8, minute: 0), .init(hour: 21, minute: 0)]
        let updated = try store.save(edit, petName: pet.nickname)
        XCTAssertEqual(updated.times[0].reminderID, first.times[0].reminderID)
        XCTAssertNotEqual(updated.times[1].reminderID, first.times[1].reminderID)
        XCTAssertTrue(updated.reminderIDs.contains(first.times[1].reminderID))
        let reminders = try CoreDataReminderRepository(stack: stack).allReminders()
        XCTAssertEqual(reminders.first { $0.id == first.times[1].reminderID }?.isEnabled, false)
        XCTAssertEqual(reminders.filter(\.isEnabled).count, 2)
    }
    func test_failedEditRollsBackCourseAndEveryReminderAndCanRetry() throws {
        var fail = false
        let stack = CoreDataStack(inMemory: true, saveHandler: { if fail { throw NSError(domain: "Disk", code: 1) }; try $0.save() })
        let pet = Pet(nickname: "豆豆", breed: "柯基"); try CoreDataPetRepository(stack: stack).create(pet)
        let store = MedicationCourseStore(stack: stack)
        let first = try store.save(course(petID: pet.id), petName: pet.nickname)
        let originalReminders = try CoreDataReminderRepository(stack: stack).allReminders()
        var edit = first; edit.drugName = "新药名"; edit.times = [.init(hour: 12, minute: 0)]
        fail = true; XCTAssertThrowsError(try store.save(edit, petName: pet.nickname))
        XCTAssertEqual(try store.courses(petID: pet.id), [first])
        XCTAssertEqual(Set(try CoreDataReminderRepository(stack: stack).allReminders().map(\.id)), Set(originalReminders.map(\.id)))
        XCTAssertFalse(stack.container.viewContext.hasChanges)
        fail = false; XCTAssertNoThrow(try store.save(edit, petName: pet.nickname))
    }
    func test_pauseResumeEndDisableSchedulingWithoutDeletingReminderIdentity() throws {
        let (stack, pet, store) = try setup()
        let first = try store.save(course(petID: pet.id), petName: pet.nickname)
        let paused = try store.setStatus(.paused, courseID: first.id, petID: pet.id)
        XCTAssertEqual(paused.reminderIDs, first.reminderIDs)
        XCTAssertTrue(try CoreDataReminderRepository(stack: stack).allReminders().allSatisfy { !$0.isEnabled })
        _ = try store.setStatus(.active, courseID: first.id, petID: pet.id)
        XCTAssertTrue(try CoreDataReminderRepository(stack: stack).allReminders().allSatisfy(\.isEnabled))
        _ = try store.setStatus(.ended, courseID: first.id, petID: pet.id)
        XCTAssertTrue(try CoreDataReminderRepository(stack: stack).allReminders().allSatisfy { !$0.isEnabled })
        XCTAssertThrowsError(try store.setStatus(.active, courseID: first.id, petID: pet.id))
    }
    func test_medicationSummaryShowsOnlyUserFacingDrugAndDose() {
        var record = Record(petID: UUID(), kind: .medication)
        record.answers = ["administrationStatus": "skipped"]
        XCTAssertEqual(record.summary, "", "内部状态不能作为用户记录摘要显示")
        record.answers["drug"] = "药品（跳过，未服药）"
        record.answers["dose"] = "未服药（已跳过）"
        XCTAssertEqual(record.summary, "药品（跳过，未服药） · 未服药（已跳过）")
    }

    func test_skipIsExplicitNonAdministeredRecordAndHistorySurvivesCourseDeletion() throws {
        let (stack, pet, store) = try setup()
        let today = Calendar.current.startOfDay(for: Date())
        let saved = try store.save(course(petID: pet.id, start: today, end: today), petName: pet.nickname)
        let reminders = try CoreDataReminderRepository(stack: stack).allReminders()
        let task = try XCTUnwrap(ReminderTaskBuilder.tasks(reminders: reminders, records: [], petID: pet.id).first)
        let record = try store.skip(task: task, courseID: saved.id)
        XCTAssertEqual(record.completedReminderID, task.reminder.id)
        XCTAssertEqual(record.answers["dose"], "未服药（已跳过）")
        XCTAssertTrue(record.answers["drug"]?.contains("跳过") == true)
        XCTAssertEqual(try store.history(for: saved).map(\.id), [record.id])
        XCTAssertThrowsError(try store.skip(task: task, courseID: saved.id))
        try store.delete(courseID: saved.id, petID: pet.id)
        XCTAssertTrue(try store.courses(petID: pet.id).isEmpty)
        XCTAssertEqual(try stack.container.viewContext.count(for: CDRecord.fetchRequest()), 1)
        XCTAssertTrue(try CoreDataReminderRepository(stack: stack).allReminders().allSatisfy { !$0.isEnabled })
    }
    func test_wrongPetCannotMutateOrDeleteCourse() throws {
        let (_, pet, store) = try setup()
        let saved = try store.save(course(petID: pet.id), petName: pet.nickname)
        XCTAssertThrowsError(try store.setStatus(.paused, courseID: saved.id, petID: UUID()))
        XCTAssertThrowsError(try store.delete(courseID: saved.id, petID: UUID()))
        XCTAssertEqual(try store.courses(petID: pet.id), [saved])
    }
    func test_failedPauseAndDeleteRetainEnabledCourseAndReminderSet() throws {
        var fail = false
        let stack = CoreDataStack(inMemory: true, saveHandler: { if fail { throw NSError(domain: "Disk", code: 1) }; try $0.save() })
        let pet = Pet(nickname: "豆豆", breed: "柯基"); try CoreDataPetRepository(stack: stack).create(pet)
        let store = MedicationCourseStore(stack: stack)
        let saved = try store.save(course(petID: pet.id), petName: pet.nickname)
        fail = true
        XCTAssertThrowsError(try store.setStatus(.paused, courseID: saved.id, petID: pet.id))
        XCTAssertEqual(try store.courses(petID: pet.id), [saved])
        XCTAssertTrue(try CoreDataReminderRepository(stack: stack).allReminders().allSatisfy(\.isEnabled))
        XCTAssertThrowsError(try store.delete(courseID: saved.id, petID: pet.id))
        XCTAssertEqual(try store.courses(petID: pet.id), [saved])
        XCTAssertTrue(try CoreDataReminderRepository(stack: stack).allReminders().allSatisfy(\.isEnabled))
        XCTAssertFalse(stack.container.viewContext.hasChanges)
    }
}
