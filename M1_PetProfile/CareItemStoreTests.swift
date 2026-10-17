import XCTest
import CoreData
@testable import PetPal

final class CareItemStoreTests: XCTestCase {
    struct Payload: Codable, Equatable {
        var id: UUID
        var petID: UUID
        var title: String
    }

    func test_itemsPersistInSameDatabaseAndRemainScopedToPetAndCategory() throws {
        let stack = CoreDataStack(inMemory: true)
        let pet = Pet(nickname: "目标", breed: "柯基")
        let other = Pet(nickname: "其他", breed: "猫")
        let pets = CoreDataPetRepository(stack: stack)
        try pets.create(pet); try pets.create(other)
        let store = CareItemStore(stack: stack)
        let value = Payload(id: UUID(), petID: pet.id, title: "早餐")
        try store.upsert(value, id: value.id, petID: pet.id, category: .quickAction)
        let reopened = CareItemStore(stack: stack)
        XCTAssertEqual(try reopened.items(Payload.self, category: .quickAction, petID: pet.id), [value])
        XCTAssertTrue(try reopened.items(Payload.self, category: .quickAction, petID: other.id).isEmpty)
        XCTAssertTrue(try reopened.items(Payload.self, category: .careInstructions, petID: pet.id).isEmpty)
    }

    func test_missingPetOrMismatchedPayloadDoesNotInsertAnything() throws {
        let stack = CoreDataStack(inMemory: true)
        let pet = Pet(nickname: "目标", breed: "柯基")
        try CoreDataPetRepository(stack: stack).create(pet)
        let store = CareItemStore(stack: stack)
        let value = Payload(id: UUID(), petID: pet.id, title: "早餐")
        XCTAssertThrowsError(try store.upsert(value, id: UUID(), petID: pet.id, category: .quickAction))
        XCTAssertThrowsError(try store.upsert(value, id: value.id, petID: UUID(), category: .quickAction))
        XCTAssertTrue(try store.items(Payload.self, category: .quickAction, petID: pet.id).isEmpty)
        XCTAssertFalse(stack.container.viewContext.hasChanges)
    }

    func test_uncommittedWritesCanBeRolledBackWithOtherDomainChanges() throws {
        let stack = CoreDataStack(inMemory: true)
        let pet = Pet(nickname: "目标", breed: "柯基")
        try CoreDataPetRepository(stack: stack).create(pet)
        let store = CareItemStore(stack: stack)
        let value = Payload(id: UUID(), petID: pet.id, title: "早餐")
        try store.upsert(value, id: value.id, petID: pet.id, category: .quickAction, commit: false)
        XCTAssertTrue(stack.container.viewContext.hasChanges)
        stack.container.viewContext.rollback()
        XCTAssertTrue(try store.items(Payload.self, category: .quickAction, petID: pet.id).isEmpty)
    }

    func test_cascadeDeleteRemovesCareItemsOnlyForDeletedPet() throws {
        let stack = CoreDataStack(inMemory: true)
        let pets = CoreDataPetRepository(stack: stack)
        let first = Pet(nickname: "一", breed: "柯基"), second = Pet(nickname: "二", breed: "猫")
        try pets.create(first); try pets.create(second)
        let store = CareItemStore(stack: stack)
        for pet in [first, second] {
            let value = Payload(id: UUID(), petID: pet.id, title: "护理")
            try store.upsert(value, id: value.id, petID: pet.id, category: .careInstructions)
        }
        try pets.delete(id: first.id)
        XCTAssertTrue(try store.items(Payload.self, category: .careInstructions, petID: first.id).isEmpty)
        XCTAssertEqual(try store.items(Payload.self, category: .careInstructions, petID: second.id).count, 1)
    }

    func test_v3SQLiteMigratesWithoutLosingExistingPet() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let modelURL = try XCTUnwrap(Bundle(for: CDPet.self).url(forResource: "PetPal", withExtension: "momd"))
        let model = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelURL.appendingPathComponent("PetPalV3.mom")))
        let url = folder.appendingPathComponent("legacy.sqlite")
        let container = NSPersistentContainer(name: "Legacy", managedObjectModel: model)
        container.persistentStoreDescriptions = [NSPersistentStoreDescription(url: url)]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        XCTAssertNil(loadError)
        let pet = NSEntityDescription.insertNewObject(forEntityName: "CDPet", into: container.viewContext)
        let id = UUID()
        pet.setValue(id, forKey: "id"); pet.setValue("旧档案", forKey: "nickname")
        pet.setValue("柯基", forKey: "breed"); pet.setValue("狗", forKey: "species")
        pet.setValue(Date(), forKey: "birthday"); pet.setValue(Date(), forKey: "createdAt")
        try container.viewContext.save()
        for store in container.persistentStoreCoordinator.persistentStores { try container.persistentStoreCoordinator.remove(store) }
        let migrated = CoreDataStack(storeURL: url)
        XCTAssertNil(migrated.loadError)
        XCTAssertEqual(try migrated.container.viewContext.fetch(CDPet.fetchRequest()).first?.id, id)
        XCTAssertNotNil(migrated.container.managedObjectModel.entitiesByName["CDCareItem"])
    }

    func test_failedUpdateRollsBackAndCanBeRetried() throws {
        var fail = false
        let stack = CoreDataStack(inMemory: true, saveHandler: { context in
            if fail { throw NSError(domain: "Disk", code: 1) }
            try context.save()
        })
        let pet = Pet(nickname: "目标", breed: "柯基")
        try CoreDataPetRepository(stack: stack).create(pet)
        let store = CareItemStore(stack: stack)
        var value = Payload(id: UUID(), petID: pet.id, title: "原内容")
        try store.upsert(value, id: value.id, petID: pet.id, category: .quickAction)
        value.title = "新内容"; fail = true
        XCTAssertThrowsError(try store.upsert(value, id: value.id, petID: pet.id, category: .quickAction))
        XCTAssertEqual(try store.items(Payload.self, category: .quickAction, petID: pet.id).first?.title, "原内容")
        XCTAssertFalse(stack.container.viewContext.hasChanges)
        fail = false
        XCTAssertNoThrow(try store.upsert(value, id: value.id, petID: pet.id, category: .quickAction))
    }
}
