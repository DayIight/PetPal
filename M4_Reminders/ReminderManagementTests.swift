import XCTest
import UserNotifications
@testable import PetPal

final class ReminderManagementTests: XCTestCase {
    @MainActor func test_pauseResumeAndEdit_replaceOnlySameReminderNotifications() async throws {
        let repo = CoreDataReminderRepository(stack: CoreDataStack(inMemory: true))
        let scheduler = MockNotificationScheduler(); scheduler.removalDelay = 10_000_000
        let service = ReminderService(repo: repo, scheduler: scheduler)
        var reminder = Reminder(petID: UUID(), type: .feeding, hour: 8, minute: 0, repeatRule: .weekly([2, 4]), advance: .m5)
        let other = Reminder(petID: UUID(), type: .medication, hour: 12, minute: 0)
        try await service.save(reminder, petName: "甲"); try await service.save(other, petName: "乙")
        XCTAssertEqual(scheduler.added.count, 5)
        reminder.isEnabled = false; try await service.save(reminder, petName: "甲")
        XCTAssertEqual(try repo.reminders(petID: reminder.petID).count, 1)
        XCTAssertFalse(try repo.reminders(petID: reminder.petID)[0].isEnabled)
        XCTAssertEqual(scheduler.added.map(\.identifier), [other.id.uuidString + "#0"])
        await service.rescheduleAll()
        XCTAssertEqual(scheduler.added.count, 1, "启动补排不能恢复已暂停的提醒")
        reminder.isEnabled = true; reminder.hour = 10; reminder.repeatRule = .daily; reminder.advance = .none
        try await service.save(reminder, petName: "甲")
        XCTAssertEqual(try repo.reminders(petID: reminder.petID).count, 1)
        let request = try XCTUnwrap(scheduler.added.first { $0.identifier.hasPrefix(reminder.id.uuidString + "#") })
        XCTAssertEqual((request.trigger as? UNCalendarNotificationTrigger)?.dateComponents.hour, 10)
        XCTAssertEqual(scheduler.added.count, 2)
        XCTAssertFalse(scheduler.addedDuringRemoval)
        try await service.remove(id: reminder.id)
        XCTAssertTrue(try repo.reminders(petID: reminder.petID).isEmpty)
        XCTAssertEqual(scheduler.added.map(\.identifier), [other.id.uuidString + "#0"])
    }

    @MainActor func test_pausedReminder_cancelsEvenWhenPermissionIsDenied() async throws {
        let repo = CoreDataReminderRepository(stack: CoreDataStack(inMemory: true))
        let scheduler = MockNotificationScheduler()
        let service = ReminderService(repo: repo, scheduler: scheduler)
        var reminder = Reminder(petID: UUID(), type: .feeding, hour: 8, minute: 0)
        try await service.save(reminder, petName: "小白")
        scheduler.authorized = false; reminder.isEnabled = false
        try await service.save(reminder, petName: "小白")
        XCTAssertTrue(scheduler.added.isEmpty)
        await service.rescheduleAll()
        XCTAssertTrue(scheduler.added.isEmpty)
        XCTAssertFalse(try repo.allReminders()[0].isEnabled)
    }

    @MainActor func test_failedPauseAndDelete_keepOriginalConfigurationAndNotifications() async throws {
        var fail = false
        let stack = CoreDataStack(inMemory: true, saveContext: {
            if fail { throw CocoaError(.fileWriteOutOfSpace) }; try $0.save()
        })
        let repo = CoreDataReminderRepository(stack: stack)
        let scheduler = MockNotificationScheduler()
        let service = ReminderService(repo: repo, scheduler: scheduler)
        var reminder = Reminder(petID: UUID(), type: .feeding, hour: 8, minute: 0)
        try await service.save(reminder, petName: "小白")
        let version = service.changeVersion
        fail = true; reminder.isEnabled = false
        do { try await service.save(reminder, petName: "小白"); XCTFail("应报告保存失败") } catch {}
        do { try await service.remove(id: reminder.id); XCTFail("应报告删除失败") } catch {}
        XCTAssertTrue(try repo.allReminders()[0].isEnabled)
        XCTAssertEqual(scheduler.added.count, 1)
        XCTAssertEqual(service.changeVersion, version)
        XCTAssertFalse(stack.container.viewContext.hasChanges)
    }
}
