import XCTest
import PDFKit
import UIKit
@testable import PetPal

final class CareToolsTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func pdf(pages: Int) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400)).pdfData { context in
            for index in 0..<pages { context.beginPage(); ("Page \(index)" as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: nil) }
        }
    }
    func test_importRejectsUnreadableOversizedAndTooManyPagePDFWithoutFiles() throws {
        let directory = try folder()
        for data in [Data("not a pdf".utf8), Data(repeating: 0, count: 20 * 1024 * 1024 + 1), pdf(pages: 201)] {
            XCTAssertThrowsError(try MedicalDocumentImporter.prepare(data: data, fileExtension: "pdf", directory: directory))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
    func test_asyncFileImportCancellationLeavesNoImportedFile() async throws {
        let sources = try folder(), destination = try folder()
        let source = sources.appendingPathComponent("medical.pdf")
        try pdf(pages: 200).write(to: source)
        let task = Task { try await MedicalDocumentImporter.prepare(from: source, directory: destination) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled import must not succeed") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
    func test_encryptedPDFIsRejectedAndImageIsNormalizedToRandomSafeName() throws {
        let directory = try folder()
        let document = try XCTUnwrap(PDFDocument(data: pdf(pages: 1)))
        let encrypted = directory.appendingPathComponent("encrypted.pdf")
        XCTAssertTrue(document.write(to: encrypted, withOptions: [.ownerPasswordOption: "owner", .userPasswordOption: "user"]))
        XCTAssertThrowsError(try MedicalDocumentImporter.prepare(data: Data(contentsOf: encrypted), fileExtension: "pdf", directory: directory))
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100))
        let image = renderer.pngData { context in UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 200, height: 100)) }
        let prepared = try MedicalDocumentImporter.prepare(data: image, fileExtension: "png", directory: directory)
        XCTAssertNotNil(UUID(uuidString: prepared.fileName.deletingPathExtension))
        XCTAssertNotNil(UIImage(contentsOfFile: directory.appendingPathComponent(prepared.fileName).path))
        XCTAssertLessThanOrEqual(prepared.byteCount, 10 * 1024 * 1024)
    }
    func test_failedPersistenceCleansImportedFileAndCrossPetRecordLinkIsRejected() throws {
        let directory = try folder(), stack = CoreDataStack(inMemory: true)
        let repo = MedicalDocumentRepository(store: CareItemStore(stack: stack), directory: directory)
        let prepared = try MedicalDocumentImporter.prepare(data: pdf(pages: 1), fileExtension: "pdf", directory: directory)
        let missingPet = MedicalDocument(petID: UUID(), title: "检查", fileName: prepared.fileName)
        XCTAssertThrowsError(try repo.create(missingPet, prepared: prepared))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(prepared.fileName).path))
        let pet = Pet(nickname: "目标", breed: "猫"), other = Pet(nickname: "其他", breed: "狗")
        try CoreDataPetRepository(stack: stack).create(pet); try CoreDataPetRepository(stack: stack).create(other)
        let record = Record(petID: other.id, kind: .checkup)
        try CoreDataRecordRepository(stack: stack).create(record)
        let next = try MedicalDocumentImporter.prepare(data: pdf(pages: 1), fileExtension: "pdf", directory: directory)
        var metadata = MedicalDocument(petID: pet.id, title: "检查", fileName: next.fileName); metadata.recordID = record.id
        XCTAssertThrowsError(try repo.create(metadata, prepared: next))
        XCTAssertTrue(try repo.documents(petID: pet.id).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(next.fileName).path))
    }
    func test_metadataAndInstructionsPersistOnlyForTheirPet() throws {
        let directory = try folder(), stack = CoreDataStack(inMemory: true)
        let pet = Pet(nickname: "目标", breed: "猫"), other = Pet(nickname: "其他", breed: "狗")
        try CoreDataPetRepository(stack: stack).create(pet); try CoreDataPetRepository(stack: stack).create(other)
        let store = CareItemStore(stack: stack), repo = MedicalDocumentRepository(store: CareItemStore(stack: stack), directory: directory)
        let prepared = try MedicalDocumentImporter.prepare(data: pdf(pages: 1), fileExtension: "pdf", directory: directory)
        let document = MedicalDocument(petID: pet.id, title: "化验", fileName: prepared.fileName)
        try repo.create(document, prepared: prepared)
        XCTAssertEqual(try repo.documents(petID: pet.id).map(\.id), [document.id])
        XCTAssertTrue(try repo.documents(petID: other.id).isEmpty)
        let instructions = CareInstructions(petID: pet.id, diet: "早餐", dailyCare: "散步", notes: "安静休息", emergencyContacts: "主人 123")
        try CareInstructionsRepository(store: store).save(instructions)
        XCTAssertEqual(try CareInstructionsRepository(store: store).load(petID: pet.id)?.diet, "早餐")
        XCTAssertNil(try CareInstructionsRepository(store: store).load(petID: other.id))
        try repo.delete(document, petID: pet.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(prepared.fileName).path))
        XCTAssertTrue(try repo.documents(petID: pet.id).isEmpty)
    }
    func test_databaseSaveFailureRollsBackMetadataAndPreservesOriginalOnDeleteFailure() throws {
        let directory = try folder()
        var shouldFail = false
        let stack = CoreDataStack(inMemory: true, saveHandler: { context in
            if shouldFail { throw NSError(domain: "CareToolsTests", code: 1) }
            try context.save()
        })
        let pet = Pet(nickname: "目标", breed: "猫")
        try CoreDataPetRepository(stack: stack).create(pet)
        let repo = MedicalDocumentRepository(store: CareItemStore(stack: stack), directory: directory)
        let failed = try MedicalDocumentImporter.prepare(data: pdf(pages: 1), fileExtension: "pdf", directory: directory)
        shouldFail = true
        XCTAssertThrowsError(try repo.create(MedicalDocument(petID: pet.id, title: "失败", fileName: failed.fileName), prepared: failed))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(failed.fileName).path))
        XCTAssertTrue(try repo.documents(petID: pet.id).isEmpty)
        XCTAssertFalse(stack.container.viewContext.hasChanges)
        shouldFail = false
        let prepared = try MedicalDocumentImporter.prepare(data: pdf(pages: 1), fileExtension: "pdf", directory: directory)
        let document = MedicalDocument(petID: pet.id, title: "原件", fileName: prepared.fileName)
        try repo.create(document, prepared: prepared)
        shouldFail = true
        XCTAssertThrowsError(try repo.delete(document, petID: pet.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(prepared.fileName).path))
        XCTAssertEqual(try repo.documents(petID: pet.id).map(\.id), [document.id])
    }
    func test_emptyCareCardAndUnsafeMedicalFilenameAreRejected() throws {
        let pet = Pet(nickname: "目标", breed: "猫")
        XCTAssertThrowsError(try CareCardSnapshot(pet: pet, instructions: CareInstructions(petID: pet.id), options: CareCardOptions(), medicationSchedules: []))
        XCTAssertNotNil(MedicalDocument(petID: pet.id, title: "检查", fileName: "../outside.pdf").validationError)
        var instructions = CareInstructions(petID: pet.id)
        instructions.notes = String(repeating: "字", count: 20_001)
        XCTAssertNotNil(instructions.validationError)
    }
    @MainActor func test_careCardRequiresMatchingPetAndOnlyExportsSelectedSensitiveFields() throws {
        var pet = Pet(nickname: "目标", breed: "猫"); pet.chipNumber = "SECRET-CHIP"; pet.allergens = ["SECRET-ALLERGY"]; pet.vetName = "SECRET-VET"
        let instructions = CareInstructions(petID: pet.id, diet: "早餐", dailyCare: "散步", notes: "观察", emergencyContacts: "主人")
        XCTAssertThrowsError(try CareCardSnapshot(pet: pet, instructions: CareInstructions(petID: UUID()), options: CareCardOptions(), medicationSchedules: ["SECRET-MEDICATION"]))
        let snapshot = try CareCardSnapshot(pet: pet, instructions: instructions, options: CareCardOptions(), medicationSchedules: ["SECRET-MEDICATION"])
        let url = try CareCardPDFBuilder.makeDocument(snapshot: snapshot)
        attachPDF(url, name: "care-card-standard")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let text = try XCTUnwrap(PDFDocument(url: url)?.string)
        for secret in ["SECRET-CHIP", "SECRET-ALLERGY", "SECRET-VET", "SECRET-MEDICATION"] { XCTAssertFalse(text.contains(secret), secret) }
        XCTAssertTrue(text.contains("早餐")); XCTAssertTrue(text.contains("照护交接卡"))
    }
    @MainActor func test_careCardLongTextPaginatesWithoutLosingTailAndIncludesSelectedFields() throws {
        var pet = Pet(nickname: "目标", breed: "猫"); pet.allergens = ["鸡肉"]; pet.vetName = "社区兽医"
        let notes = String(repeating: "观察精神状态，及时联系主人。\n", count: 250) + "照护末尾标记"
        let instructions = CareInstructions(petID: pet.id, notes: notes)
        let snapshot = try CareCardSnapshot(pet: pet, instructions: instructions, options: CareCardOptions(includeAllergies: true, includeMedication: true, includeVet: true), medicationSchedules: ["主人填写的早餐用药"])
        let url = try CareCardPDFBuilder.makeDocument(snapshot: snapshot)
        attachPDF(url, name: "care-card-long")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let pdf = try XCTUnwrap(PDFDocument(url: url)), text = pdf.string ?? ""
        XCTAssertGreaterThan(pdf.pageCount, 3)
        for expected in ["照护末尾标记", "鸡肉", "社区兽医", "主人填写的早餐用药"] { XCTAssertTrue(text.contains(expected), expected) }
        XCTAssertEqual(text.components(separatedBy: "观察精神状态").count - 1, 250)
    }

    private func attachPDF(_ url: URL, name: String) {
        if let data = try? Data(contentsOf: url) {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "com.adobe.pdf")
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
    }
}

private extension String {
    var deletingPathExtension: String { (self as NSString).deletingPathExtension }
}
