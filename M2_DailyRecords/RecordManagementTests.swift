import XCTest
import UIKit
import Combine
import CoreData
@testable import PetPal

final class RecordManagementTests: XCTestCase {
    private var bag = Set<AnyCancellable>()
    private func records(_ repo: RecordRepository, petID: UUID) -> [PetPal.Record] {
        var result: [PetPal.Record] = []
        repo.recordsPublisher(petID: petID).sink { result = $0 }.store(in: &bag)
        return result
    }
    private func imageData() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).jpegData(withCompressionQuality: 0.8) {
            UIColor.blue.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @MainActor func test_templateChangeAndDeletion_doNotChangeHistoricalFields() throws {
        let stack = CoreDataStack(inMemory: true)
        let templates = CoreDataCustomTemplateRepository(stack: stack)
        let repo = CoreDataRecordRepository(stack: stack)
        var template = CustomTemplate(name: "用药", fields: [
            .init(title: "剂量", type: .number, isRequired: true),
            .init(title: "时段", type: .single, options: ["早", "晚"])])
        try templates.save(template)
        let vm = RecordFormViewModel(repo: repo, petID: UUID(), kind: .custom, template: template)
        vm.draft.answers = [template.fields[0].id.uuidString: "2", template.fields[1].id.uuidString: "晚"]
        XCTAssertTrue(vm.save())
        template.name = "新模板"; template.fields.reverse(); template.fields[0].title = "改名"
        try templates.save(template); try templates.delete(id: template.id)
        let record = try XCTUnwrap(records(repo, petID: vm.draft.petID).first)
        XCTAssertEqual(record.displayKind, "用药")
        XCTAssertEqual(record.fields.map(\.title), ["剂量", "时段"])
        XCTAssertEqual(record.templateSnapshot?.version, 1)
        XCTAssertEqual(record.templateSnapshot?.templateID, template.id)
        XCTAssertEqual(record.templateSnapshot?.fields[1].options, ["早", "晚"])
        XCTAssertEqual(record.summary, "2 · 晚")
        XCTAssertTrue(record.templateSnapshot?.fields[0].isRequired == true)
    }

    @MainActor func test_legacyRecord_editPreservesAllAnswersAndIdentity() throws {
        let repo = CoreDataRecordRepository(stack: CoreDataStack(inMemory: true))
        let record = PetPal.Record(petID: UUID(), kind: .custom, answers: ["b": "乙", "a": "甲"], templateName: "旧模板")
        try repo.create(record)
        let vm = RecordFormViewModel(repo: repo, petID: record.petID, kind: .custom, editing: record)
        vm.draft.note = "补充备注"
        XCTAssertTrue(vm.save()); XCTAssertTrue(vm.save())
        let saved = try XCTUnwrap(records(repo, petID: record.petID).first)
        XCTAssertEqual(records(repo, petID: record.petID).count, 1)
        XCTAssertEqual(saved.answers, record.answers)
        XCTAssertEqual(saved.fields.map(\.key), ["a", "b"])
        XCTAssertEqual(Set(saved.fields.map(\.title)).count, 2)
        XCTAssertNil(saved.templateSnapshot)
        XCTAssertEqual(saved.createdAt, record.createdAt)
        XCTAssertEqual(saved.id, record.id)
    }

    @MainActor func test_photosRejectUnreadableOversizeAndTenthSelection() {
        let vm = RecordFormViewModel(repo: CoreDataRecordRepository(stack: CoreDataStack(inMemory: true)), petID: UUID(), kind: .walking)
        XCTAssertFalse(vm.addPhoto(Data("bad image".utf8)))
        XCTAssertFalse(vm.addPhoto(Data(count: MediaPolicy.maxPhotoBytes + 1)))
        XCTAssertEqual(vm.errors, ["单张图片不能超过10MB"])
        for _ in 0..<9 { XCTAssertTrue(vm.addPhoto(imageData())) }
        XCTAssertFalse(vm.addPhoto(imageData()))
        XCTAssertEqual(vm.photoCount, 9)
    }

    @MainActor func test_photoWriteFailure_cleansPartialFilesAndAllowsRetry() throws {
        let folder = try directory()
        let repo = CoreDataRecordRepository(stack: CoreDataStack(inMemory: true))
        var attempts = 0, fail = true
        let remove: (String) -> Void = { try? FileManager.default.removeItem(at: folder.appendingPathComponent($0)) }
        let vm = RecordFormViewModel(repo: repo, petID: UUID(), kind: .walking, savePhoto: {
            attempts += 1
            if fail && attempts == 2 { throw CocoaError(.fileWriteOutOfSpace) }
            return try AvatarStore.save($0, to: folder)
        }, deletePhoto: remove)
        XCTAssertTrue(vm.addPhoto(imageData())); XCTAssertTrue(vm.addPhoto(imageData()))
        XCTAssertFalse(vm.save())
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        XCTAssertTrue(records(repo, petID: vm.draft.petID).isEmpty)
        XCTAssertEqual(vm.pendingPhotos.count, 2)
        fail = false
        XCTAssertTrue(vm.save()); XCTAssertTrue(vm.save())
        let saved = try XCTUnwrap(records(repo, petID: vm.draft.petID).first)
        XCTAssertEqual(records(repo, petID: vm.draft.petID).count, 1)
        XCTAssertEqual(saved.photoFileNames.count, 2)
        for file in saved.photoFileNames { XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path)) }
    }

    @MainActor func test_failedEdit_preservesOldRecordAndPhoto_thenSuccessfulEditCleansRemovedPhoto() throws {
        let folder = try directory()
        var fail = false
        let stack = CoreDataStack(inMemory: true, saveContext: {
            if fail { throw CocoaError(.fileWriteOutOfSpace) }; try $0.save()
        })
        let remove: (String) -> Void = { try? FileManager.default.removeItem(at: folder.appendingPathComponent($0)) }
        let repo = CoreDataRecordRepository(stack: stack, deletePhoto: remove)
        let oldName = try AvatarStore.save(UIImage(data: imageData())!, to: folder)
        let original = PetPal.Record(petID: UUID(), kind: .walking, note: "旧备注", photoFileNames: [oldName])
        try repo.create(original)
        let vm = RecordFormViewModel(repo: repo, petID: original.petID, kind: .walking, editing: original,
            savePhoto: { try AvatarStore.save($0, to: folder) }, deletePhoto: remove)
        vm.draft.note = "新备注"; vm.draft.photoFileNames = []
        XCTAssertTrue(vm.addPhoto(imageData()))
        fail = true
        XCTAssertFalse(vm.save())
        XCTAssertEqual(records(repo, petID: original.petID).first, original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [oldName])
        fail = false
        XCTAssertTrue(vm.save())
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(oldName).path))
        XCTAssertEqual(records(repo, petID: original.petID).first?.note, "新备注")
        try repo.delete(id: original.id)
        XCTAssertTrue(records(repo, petID: original.petID).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @MainActor func test_failedDeletion_doesNotRemovePhotosOrRecord() throws {
        var fail = false, deleted: [String] = []
        let stack = CoreDataStack(inMemory: true, saveContext: {
            if fail { throw CocoaError(.fileWriteOutOfSpace) }; try $0.save()
        })
        let repo = CoreDataRecordRepository(stack: stack, deletePhoto: { deleted.append($0) })
        let original = PetPal.Record(petID: UUID(), kind: .walking, photoFileNames: ["old.jpg"])
        try repo.create(original); fail = true
        XCTAssertThrowsError(try repo.delete(id: original.id))
        XCTAssertTrue(deleted.isEmpty)
        XCTAssertEqual(records(repo, petID: original.petID), [original])
    }

    @MainActor func test_editAndDelete_refreshTimelineCalendarDashboardAndDetail() throws {
        let stack = CoreDataStack(inMemory: true)
        let writer = CoreDataRecordRepository(stack: stack)
        var record = PetPal.Record(petID: UUID(), kind: .vaccine, answers: ["vaccineName": "旧疫苗"])
        try writer.create(record)
        let timeline = TimelineViewModel(repo: CoreDataRecordRepository(stack: stack), petID: record.petID)
        let calendar = RecordCalendarViewModel(repo: CoreDataRecordRepository(stack: stack), petID: record.petID)
        let heatmap = CheckinHeatmapModel(repo: CoreDataRecordRepository(stack: stack), petID: record.petID)
        let health = HealthTimelineModel(repo: CoreDataRecordRepository(stack: stack), petID: record.petID)
        let detail = RecordDetailViewModel(record: record, repo: CoreDataRecordRepository(stack: stack))
        record.answers["vaccineName"] = "新疫苗"; try writer.update(record)
        drain()
        XCTAssertEqual(detail.record.answers["vaccineName"], "新疫苗")
        XCTAssertEqual(timeline.sections.first?.items.first?.summary, "新疫苗")
        XCTAssertEqual(calendar.records.count, 1)
        XCTAssertEqual(health.events.first?.title, "新疫苗")
        XCTAssertEqual(heatmap.counts.values.reduce(0, +), 1)
        try writer.delete(id: record.id); drain()
        XCTAssertTrue(timeline.sections.isEmpty); XCTAssertTrue(calendar.records.isEmpty)
        XCTAssertTrue(health.events.isEmpty); XCTAssertTrue(heatmap.counts.isEmpty)
    }
    private func drain() {
        let delivered = expectation(description: "repository updates delivered")
        DispatchQueue.main.async { delivered.fulfill() }; wait(for: [delivered], timeout: 2)
    }
}

final class PersistentStoreMigrationTests: XCTestCase {
    func test_originalSQLite_migratesWithoutLosingAnswersAndEnablesExistingReminders() throws {
        let bundle = Bundle(for: CDPet.self)
        let modelURL = try XCTUnwrap(bundle.url(forResource: "PetPal", withExtension: "momd"))
        let oldModel = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelURL.appendingPathComponent("PetPal.mom")))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("PetPal.sqlite")
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: oldModel)
        let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let petID = UUID(), recordID = UUID()
        let record = NSEntityDescription.insertNewObject(forEntityName: "CDRecord", into: context)
        record.setValue(recordID, forKey: "id"); record.setValue(petID, forKey: "petID")
        record.setValue(RecordKind.custom.rawValue, forKey: "kind")
        record.setValue(["old-field": "旧答案"], forKey: "answers")
        record.setValue("旧模板", forKey: "templateName")
        let reminder = NSEntityDescription.insertNewObject(forEntityName: "CDReminder", into: context)
        reminder.setValue(UUID(), forKey: "id"); reminder.setValue(petID, forKey: "petID")
        reminder.setValue(ReminderType.feeding.rawValue, forKey: "type"); reminder.setValue(8, forKey: "hour")
        try context.save(); context.reset(); try coordinator.remove(store)
        let migrated = CoreDataStack(storeURL: url)
        XCTAssertNil(migrated.loadError)
        let records = try migrated.container.viewContext.fetch(CDRecord.fetchRequest())
        XCTAssertEqual(records.count, 1); XCTAssertEqual(records.first?.id, recordID)
        XCTAssertEqual(records.first?.answers, ["old-field": "旧答案"])
        XCTAssertNil(records.first?.templateSnapshot)
        let reminders = try CoreDataReminderRepository(stack: migrated).reminders(petID: petID)
        XCTAssertEqual(reminders.count, 1); XCTAssertTrue(reminders[0].isEnabled)
        for store in migrated.container.persistentStoreCoordinator.persistentStores {
            try migrated.container.persistentStoreCoordinator.remove(store)
        }
    }
}
