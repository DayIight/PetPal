import XCTest
@testable import PetPal

final class OnboardingTests: XCTestCase {
    @MainActor func test_savedDataDrivesProgressAndSkipPersists() throws {
        let name = "OnboardingTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let stack = CoreDataStack(inMemory: true)
        let store = OnboardingStore(defaults: defaults, stack: stack)
        store.refresh(pets: [])
        XCTAssertTrue(store.isVisible); XCTAssertEqual(store.step, .pet)
        let pet = Pet(nickname: "小白", breed: "柯基")
        try CoreDataPetRepository(stack: stack).create(pet)
        store.refresh(pets: [pet]); XCTAssertEqual(store.step, .record)
        let other = Pet(nickname: "其他", breed: "柯基")
        try CoreDataRecordRepository(stack: stack).create(Record(petID: other.id, kind: .walking))
        store.refresh(pets: [pet, other]); XCTAssertEqual(store.step, .record)
        try CoreDataRecordRepository(stack: stack).create(Record(petID: pet.id, kind: .walking))
        store.refresh(pets: [pet]); XCTAssertEqual(store.step, .reminder)
        store.skip()
        let restarted = OnboardingStore(defaults: defaults, stack: stack)
        restarted.refresh(pets: [pet]); XCTAssertFalse(restarted.isVisible)
        restarted.reopen(pets: [pet]); XCTAssertTrue(restarted.isVisible)
        XCTAssertEqual(restarted.step, .reminder)
        try CoreDataReminderRepository(stack: stack).save(Reminder(petID: pet.id, type: .feeding, hour: 9, minute: 0))
        restarted.refresh(pets: [pet]); XCTAssertEqual(restarted.step, .finished)
        restarted.finish()
        let completed = OnboardingStore(defaults: defaults, stack: stack)
        completed.refresh(pets: []); XCTAssertFalse(completed.isVisible, "删除数据不能重新触发完成过的引导")
    }
    @MainActor func test_existingUsersAndDeletedPartialPet() throws {
        let name = "OnboardingTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let stack = CoreDataStack(inMemory: true)
        let pet = Pet(nickname: "旧用户", breed: "柯基")
        let store = OnboardingStore(defaults: defaults, stack: stack)
        store.refresh(pets: [pet]); XCTAssertFalse(store.isVisible)
        store.reopen(pets: [pet]); XCTAssertEqual(store.step, .record)
        store.refresh(pets: []); XCTAssertEqual(store.step, .pet); XCTAssertNil(store.petID)
    }
    @MainActor func test_completionOnlyAfterBothRecordAndReminderAreSaved() throws {
        let name = "OnboardingTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let stack = CoreDataStack(inMemory: true)
        let store = OnboardingStore(defaults: defaults, stack: stack)
        store.refresh(pets: [])
        let pet = Pet(nickname: "小白", breed: "柯基")
        store.refresh(pets: [pet])
        try CoreDataReminderRepository(stack: stack).save(Reminder(petID: pet.id, type: .feeding, hour: 9, minute: 0))
        store.refresh(pets: [pet]); XCTAssertEqual(store.step, .record); XCTAssertTrue(store.isVisible)
        try CoreDataRecordRepository(stack: stack).create(Record(petID: pet.id, kind: .walking))
        store.refresh(pets: [pet]); XCTAssertFalse(store.isVisible)
        XCTAssertEqual(store.step, .finished)
    }
    func test_feedbackTemplateContainsReproductionFieldsAndOnlyPublicDeviceInfo() {
        let text = SupportFeedback.template(version: "1.0", build: "1", system: "iOS 27", device: "iPhone")
        for field in ["1.0（1）", "iOS 27", "操作步骤", "预期结果", "实际结果", "是否可以重复"] { XCTAssertTrue(text.contains(field)) }
        XCTAssertFalse(text.contains("芯片号")); XCTAssertFalse(text.contains("宠物昵称"))
    }
}
