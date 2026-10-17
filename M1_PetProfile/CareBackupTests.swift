import XCTest
import CoreData
import UIKit
@testable import PetPal

@MainActor final class CareBackupTests: XCTestCase {
    private func fixture() throws -> (URL, URL, CoreDataStack, Pet) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let media = root.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let stack = CoreDataStack(storeURL: root.appendingPathComponent("source.sqlite"))
        let pet = Pet(nickname: "备份宠物", breed: "柯基")
        try CoreDataPetRepository(stack: stack).create(pet)
        return (root, media, stack, pet)
    }
    private func pdf() -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400)).pdfData { context in
            context.beginPage(); ("医疗资料原件" as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: nil)
        }
    }
    private func addDocument(stack: CoreDataStack, pet: Pet, media: URL) throws -> MedicalDocument {
        let prepared = try MedicalDocumentImporter.prepare(data: pdf(), fileExtension: "pdf", directory: media)
        let value = MedicalDocument(petID: pet.id, title: "原始化验单", fileName: prepared.fileName)
        try MedicalDocumentRepository(store: CareItemStore(stack: stack), directory: media).create(value, prepared: prepared)
        return value
    }

    func test_roundTripPreservesAllCarePayloadsAndRenamesPDFReferences() throws {
        let (root, media, source, pet) = try fixture()
        let store = CareItemStore(stack: source)
        let document = try addDocument(stack: source, pet: pet, media: media)
        let originalPDF = try Data(contentsOf: media.appendingPathComponent(document.fileName))
        try QuickActionRepository(store: store).save(QuickAction(name: "早餐", record: Record(petID: pet.id, kind: .feeding, answers: ["food": "粮", "grams": "40"])))
        try CareInstructionsRepository(store: store).save(CareInstructions(petID: pet.id, diet: "早餐40克", emergencyContacts: "主人"))
        let start = Calendar.current.startOfDay(for: Date())
        let course = try MedicationCourseStore(stack: source).save(MedicationCourse(petID: pet.id, drugName: "记录药品", doseInstructions: "主人填写用量",
            startDate: start, endDate: Calendar.current.date(byAdding: .day, value: 1, to: start)!, times: [.init(hour: 8, minute: 0)]), petName: pet.nickname)
        let backup = try PortableBackup.create(stack: source, mediaDirectory: media)
        let archive = try JSONDecoder().decode(PortableBackup.self, from: backup)
        XCTAssertEqual(archive.media[document.fileName]?.data, originalPDF)
        let target = CoreDataStack(storeURL: root.appendingPathComponent("target.sqlite"))
        try PortableBackup.restore(backup, stack: target, mediaDirectory: media)
        let restored = CareItemStore(stack: target)
        let documents = try MedicalDocumentRepository(store: restored, directory: media).documents(petID: pet.id)
        XCTAssertEqual(documents.map(\.id), [document.id])
        XCTAssertNotEqual(documents.first?.fileName, document.fileName)
        let restoredName = try XCTUnwrap(documents.first?.fileName)
        XCTAssertEqual(try Data(contentsOf: media.appendingPathComponent(restoredName)), archive.media[document.fileName]?.data)
        XCTAssertEqual(try QuickActionRepository(store: restored).actions(petID: pet.id).map(\.name), ["早餐"])
        XCTAssertEqual(try CareInstructionsRepository(store: restored).load(petID: pet.id)?.diet, "早餐40克")
        XCTAssertEqual(try MedicationCourseStore(stack: target).courses(petID: pet.id).map(\.id), [course.id])
        XCTAssertTrue(Set(course.reminderIDs).isSubset(of: Set(try CoreDataReminderRepository(stack: target).allReminders().map(\.id))))
    }

    func test_corruptPDFIsRejectedWithoutReplacingTargetOrWritingFiles() throws {
        let (root, media, source, pet) = try fixture()
        let document = try addDocument(stack: source, pet: pet, media: media)
        var archive = try JSONDecoder().decode(PortableBackup.self, from: PortableBackup.create(stack: source, mediaDirectory: media))
        archive.media[document.fileName] = .init(Data("not a readable PDF".utf8))
        let target = CoreDataStack(storeURL: root.appendingPathComponent("target.sqlite"))
        let kept = Pet(nickname: "保留资料", breed: "猫")
        try CoreDataPetRepository(stack: target).create(kept)
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: media.path))
        XCTAssertThrowsError(try PortableBackup.restore(JSONEncoder().encode(archive), stack: target, mediaDirectory: media))
        XCTAssertEqual(try target.container.viewContext.fetch(CDPet.fetchRequest()).map(\.id), [kept.id])
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: media.path)), before)
    }

    func test_invalidCarePayloadWithValidDigestIsRejectedBeforeCommit() throws {
        let (root, media, source, pet) = try fixture()
        try CareInstructionsRepository(store: CareItemStore(stack: source)).save(CareInstructions(petID: pet.id, diet: "早餐"))
        var archive = try JSONDecoder().decode(PortableBackup.self, from: PortableBackup.create(stack: source, mediaDirectory: media))
        let tamperedURL = root.appendingPathComponent("tampered.sqlite")
        try archive.database.data.write(to: tamperedURL)
        let tampered = CoreDataStack(storeURL: tamperedURL)
        let row = try XCTUnwrap(tampered.container.viewContext.fetch(CDCareItem.fetchRequest()).first)
        row.payload = "{\"id\":\"\(UUID())\",\"petID\":\"\(pet.id)\"}"
        try tampered.save()
        XCTAssertThrowsError(try CareItemBackup.validate(in: tampered.container.viewContext), "先证明构造的载荷确实损坏")
        // 关闭实际写入连接，确保 WAL 中的篡改进入用于测试的单文件。
        for store in tampered.container.persistentStoreCoordinator.persistentStores {
            try tampered.container.persistentStoreCoordinator.remove(store)
        }
        archive.database = .init(try Data(contentsOf: tamperedURL))
        let target = CoreDataStack(storeURL: root.appendingPathComponent("target.sqlite"))
        let kept = Pet(nickname: "保留资料", breed: "猫")
        try CoreDataPetRepository(stack: target).create(kept)
        XCTAssertThrowsError(try PortableBackup.restore(JSONEncoder().encode(archive), stack: target, mediaDirectory: media))
        XCTAssertEqual(try target.container.viewContext.fetch(CDPet.fetchRequest()).map(\.id), [kept.id])
    }

    func test_missingMedicalOriginalBlocksExportAndPetDeletionCleansOriginal() throws {
        let (_, media, source, pet) = try fixture()
        let document = try addDocument(stack: source, pet: pet, media: media)
        try FileManager.default.removeItem(at: media.appendingPathComponent(document.fileName))
        XCTAssertThrowsError(try PortableBackup.create(stack: source, mediaDirectory: media))
        let liveDocument = try addDocument(stack: source, pet: pet, media: AvatarStore.directory)
        addTeardownBlock { AvatarStore.delete(fileName: liveDocument.fileName) }
        try CoreDataPetRepository(stack: source).delete(id: pet.id)
        XCTAssertTrue(try source.container.viewContext.fetch(CDCareItem.fetchRequest()).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AvatarStore.directory.appendingPathComponent(liveDocument.fileName).path))
    }

    func test_secondBackupIncludesEditsCommittedAfterFirstSnapshot() throws {
        let (root, media, source, pet) = try fixture()
        let repository = CareInstructionsRepository(store: CareItemStore(stack: source))
        var value = CareInstructions(petID: pet.id, diet: "第一份安排")
        try repository.save(value)
        _ = try PortableBackup.create(stack: source, mediaDirectory: media)
        value.diet = "修改后的安排"
        try repository.save(value)
        let latest = try PortableBackup.create(stack: source, mediaDirectory: media)
        let target = CoreDataStack(storeURL: root.appendingPathComponent("target.sqlite"))
        try PortableBackup.restore(latest, stack: target, mediaDirectory: media)
        XCTAssertEqual(try CareInstructionsRepository(store: CareItemStore(stack: target)).load(petID: pet.id)?.diet, value.diet)
    }

    func test_deletingLinkedHealthRecordKeepsMedicalOriginalAndBackupUsable() throws {
        let (_, media, source, pet) = try fixture()
        let records = CoreDataRecordRepository(stack: source)
        let record = Record(petID: pet.id, kind: .checkup)
        try records.create(record)
        let prepared = try MedicalDocumentImporter.prepare(data: pdf(), fileExtension: "pdf", directory: media)
        var value = MedicalDocument(petID: pet.id, title: "体检原件", fileName: prepared.fileName)
        value.recordID = record.id
        let repository = MedicalDocumentRepository(store: CareItemStore(stack: source), directory: media)
        try repository.create(value, prepared: prepared)
        try records.delete(id: record.id)
        XCTAssertNil(try repository.documents(petID: pet.id).first?.recordID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.appendingPathComponent(value.fileName).path))
        XCTAssertNoThrow(try PortableBackup.create(stack: source, mediaDirectory: media))
    }

    func test_v1ArchiveWithV3DatabaseRestoresIntoV4WithoutCareItems() throws {
        let (root, media, _, _) = try fixture()
        let url = root.appendingPathComponent("legacy.sqlite")
        let modelURL = try XCTUnwrap(Bundle(for: CDPet.self).url(forResource: "PetPal", withExtension: "momd"))
        let model = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelURL.appendingPathComponent("PetPalV3.mom")))
        let legacy = NSPersistentContainer(name: "Legacy", managedObjectModel: model)
        legacy.persistentStoreDescriptions = [NSPersistentStoreDescription(url: url)]
        var error: Error?
        legacy.loadPersistentStores { _, failure in error = failure }
        XCTAssertNil(error)
        let pet = NSEntityDescription.insertNewObject(forEntityName: "CDPet", into: legacy.viewContext)
        let id = UUID()
        pet.setValue(id, forKey: "id"); pet.setValue("历史宠物", forKey: "nickname")
        pet.setValue("柯基", forKey: "breed"); pet.setValue("狗", forKey: "species")
        pet.setValue(Date(), forKey: "birthday"); pet.setValue(Date(), forKey: "createdAt")
        try legacy.viewContext.save()
        for store in legacy.persistentStoreCoordinator.persistentStores { try legacy.persistentStoreCoordinator.remove(store) }
        var archive = PortableBackup(createdAt: Date(), appVersion: "1.0", currentPetID: id, database: .init(try Data(contentsOf: url)), media: [:])
        archive.version = 1
        let target = CoreDataStack(storeURL: root.appendingPathComponent("target.sqlite"))
        try PortableBackup.restore(JSONEncoder().encode(archive), stack: target, mediaDirectory: media)
        XCTAssertEqual(try target.container.viewContext.fetch(CDPet.fetchRequest()).first?.nickname, "历史宠物")
        XCTAssertTrue(try target.container.viewContext.fetch(CDCareItem.fetchRequest()).isEmpty)
    }
}
