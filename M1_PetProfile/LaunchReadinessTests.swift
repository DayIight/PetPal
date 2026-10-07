import XCTest
import CoreData
import Combine
import UIKit
@testable import PetPal

final class LaunchMediaFailureTests: XCTestCase {
    func test_actualWriteFailure_returnsNil() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertNil(AvatarStore.save(AvatarStoreTests.makeImage(), to: file))
    }

    @MainActor func test_avatarWriteFailure_keepsOriginalAndDraft_thenCanRetry() throws {
        let stack = CoreDataStack(inMemory: true)
        let repo = CoreDataPetRepository(stack: stack)
        let old = try XCTUnwrap(AvatarStore.save(AvatarStoreTests.makeImage()))
        defer { AvatarStore.delete(fileName: old) }
        let pet = Pet(nickname: "小白", breed: "柯基", avatarFileName: old)
        try repo.create(pet)
        var canWrite = false
        let vm = PetFormViewModel(repo: repo, editing: pet, saveAvatar: { canWrite ? AvatarStore.save($0) : nil })
        vm.pickAvatar(AvatarStoreTests.makeImage())
        XCTAssertFalse(vm.save())
        XCTAssertNotNil(vm.saveError)
        XCTAssertNotNil(vm.pickedAvatar)
        XCTAssertEqual(vm.draft.avatarFileName, old)
        XCTAssertEqual(try stack.container.viewContext.fetch(CDPet.fetchRequest()).first?.avatarFileName, old)
        XCTAssertTrue(FileManager.default.fileExists(atPath: AvatarStore.url(for: old).path))
        canWrite = true
        XCTAssertTrue(vm.save())
        if let new = vm.draft.avatarFileName { AvatarStore.delete(fileName: new) }
    }

    @MainActor func test_partialRecordPhotoFailure_rollsBackFilesAndAllowsRetry() throws {
        let stack = CoreDataStack(inMemory: true)
        var calls = 0
        var written: [String] = []
        let vm = RecordFormViewModel(repo: CoreDataRecordRepository(stack: stack), petID: UUID(), kind: .training,
            savePhoto: { image in
                calls += 1
                if calls == 2 { return nil }
                let name = AvatarStore.save(image)
                if let name { written.append(name) }
                return name
            })
        defer { written.forEach(AvatarStore.delete(fileName:)) }
        vm.draft.answers = ["subject": "召回"]
        vm.addPhoto(AvatarStoreTests.makeImage()); vm.addPhoto(AvatarStoreTests.makeImage())
        XCTAssertFalse(vm.save())
        XCTAssertEqual(vm.pickedImages.count, 2)
        XCTAssertTrue(vm.draft.photoFileNames.isEmpty)
        XCTAssertEqual(try stack.container.viewContext.count(for: CDRecord.fetchRequest()), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AvatarStore.url(for: written[0]).path))
        XCTAssertTrue(vm.save())
        XCTAssertEqual(try stack.container.viewContext.fetch(CDRecord.fetchRequest()).first?.photoFileNames?.count, 2)
    }

    @MainActor func test_deletedPetUpdate_doesNotPretendToSaveOrDeleteOldAvatar() throws {
        let repo = CoreDataPetRepository(stack: CoreDataStack(inMemory: true))
        let old = try XCTUnwrap(AvatarStore.save(AvatarStoreTests.makeImage()))
        defer { AvatarStore.delete(fileName: old) }
        let vm = PetFormViewModel(repo: repo, editing: Pet(nickname: "小白", breed: "柯基", avatarFileName: old))
        vm.removeAvatar()
        XCTAssertFalse(vm.save())
        XCTAssertNotNil(vm.saveError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: AvatarStore.url(for: old).path))
    }
    @MainActor func test_deletedRecordUpdate_preservesRemovedPhotosAndDraft() throws {
        let repo = CoreDataRecordRepository(stack: CoreDataStack(inMemory: true))
        let old = try XCTUnwrap(AvatarStore.save(AvatarStoreTests.makeImage()))
        defer { AvatarStore.delete(fileName: old) }
        let record = Record(petID: UUID(), kind: .training, answers: ["subject": "召回"], photoFileNames: [old])
        let vm = RecordFormViewModel(repo: repo, editing: record)
        vm.removeSavedPhoto(old)
        vm.addPhoto(AvatarStoreTests.makeImage())
        XCTAssertFalse(vm.save())
        XCTAssertTrue(FileManager.default.fileExists(atPath: AvatarStore.url(for: old).path))
        XCTAssertEqual(vm.pickedImages.count, 1)
        XCTAssertTrue(vm.draft.photoFileNames.isEmpty)
    }

    @MainActor func test_databaseFailure_discardsFailedOperationBeforeLaterSave() throws {
        var fail = true
        let stack = CoreDataStack(inMemory: true, saveHandler: { ctx in
            if fail { throw NSError(domain: "SimulatedDiskFull", code: 1) }
            try ctx.save()
        })
        let repo = CoreDataPetRepository(stack: stack)
        XCTAssertThrowsError(try repo.create(Pet(nickname: "失败的草稿", breed: "柯基")))
        XCTAssertFalse(stack.container.viewContext.hasChanges)
        fail = false
        try repo.create(Pet(nickname: "成功", breed: "柯基"))
        XCTAssertEqual(try stack.container.viewContext.fetch(CDPet.fetchRequest()).map(\.nickname), ["成功"])
    }

    @MainActor func test_databaseFailure_preservesOldAvatarAndRemovesNewFile() throws {
        var fail = false
        let stack = CoreDataStack(inMemory: true, saveHandler: { ctx in
            if fail { throw NSError(domain: "SimulatedDiskFull", code: 1) }
            try ctx.save()
        })
        let repo = CoreDataPetRepository(stack: stack)
        let old = try XCTUnwrap(AvatarStore.save(AvatarStoreTests.makeImage()))
        defer { AvatarStore.delete(fileName: old) }
        let pet = Pet(nickname: "小白", breed: "柯基", avatarFileName: old)
        try repo.create(pet)
        var new: String?
        let vm = PetFormViewModel(repo: repo, editing: pet, saveAvatar: { new = AvatarStore.save($0); return new })
        vm.pickAvatar(AvatarStoreTests.makeImage()); fail = true
        XCTAssertFalse(vm.save())
        XCTAssertEqual(try stack.container.viewContext.fetch(CDPet.fetchRequest()).first?.avatarFileName, old)
        XCTAssertTrue(FileManager.default.fileExists(atPath: AvatarStore.url(for: old).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: AvatarStore.url(for: try XCTUnwrap(new)).path))
        XCTAssertFalse(stack.container.viewContext.hasChanges)
    }
}

final class PortableBackupTests: XCTestCase {
    private var directory: URL!
    private var media: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var stacks: [CoreDataStack] = []
    override func setUpWithError() throws {
        directory = try PortableBackup.temporaryDirectory()
        media = directory.appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        suite = "PetPalPortableTests-\(UUID())"
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDownWithError() throws {
        for stack in stacks {
            stack.container.viewContext.reset()
            for store in stack.container.persistentStoreCoordinator.persistentStores { try stack.container.persistentStoreCoordinator.remove(store) }
        }
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: directory)
    }
    private func stack(_ name: String) -> CoreDataStack {
        let stack = CoreDataStack(storeURL: directory.appendingPathComponent(name + ".sqlite"))
        stacks.append(stack)
        return stack
    }
    private func populatedArchive() throws -> (Data, UUID, String) {
        let source = stack("source")
        let first = Pet(nickname: "小白", breed: "柯基", avatarFileName: try XCTUnwrap(AvatarStore.save(AvatarStoreTests.makeImage(), to: media)))
        let second = Pet(species: .cat, nickname: "橘子", breed: "橘猫")
        try CoreDataPetRepository(stack: source).create(first)
        try CoreDataPetRepository(stack: source).create(second)
        let photo = try XCTUnwrap(AvatarStore.save(AvatarStoreTests.makeImage(width: 300, height: 200), to: media))
        let template = CustomTemplate(name: "药物", fields: [.init(title: "药名", type: .text)])
        try CoreDataCustomTemplateRepository(stack: source).save(template)
        try CoreDataRecordRepository(stack: source).create(Record(petID: first.id, kind: .custom,
            answers: [template.fields[0].id.uuidString: "测试药品"], note: "备注", mood: "开心", photoFileNames: [photo], templateName: template.name))
        try CoreDataRecordRepository(stack: source).create(Record(petID: second.id, kind: .training, answers: ["subject": "召回"]))
        try CoreDataWeightRepository(stack: source).add(WeightSample(petID: first.id, kg: 8.5, date: Date()))
        try CoreDataReminderRepository(stack: source).save(Reminder(petID: first.id, petName: first.nickname,
            type: .feeding, hour: 9, minute: 30, repeatRule: .weekly([2, 4])))
        defaults.set(second.id.uuidString, forKey: "petpal.currentPetID")
        return (try PortableBackup.create(stack: source, mediaDirectory: media, defaults: defaults), second.id, photo)
    }

    func test_completeBackup_restoresTwoPetsMediaTemplatesWeightsRemindersAndSelection() throws {
        let (data, selectedID, photo) = try populatedArchive()
        let archive = try JSONDecoder().decode(PortableBackup.self, from: data)
        let target = stack("cleanInstall")
        try PortableBackup.restore(data, stack: target, mediaDirectory: media, defaults: defaults)
        let ctx = target.container.viewContext
        XCTAssertEqual(Set(try ctx.fetch(CDPet.fetchRequest()).compactMap(\.nickname)), ["小白", "橘子"])
        let records = try ctx.fetch(CDRecord.fetchRequest())
        XCTAssertEqual(records.count, 2)
        let restoredPhoto = try XCTUnwrap(records.first { $0.kind == RecordKind.custom.rawValue }?.photoFileNames?.first)
        XCTAssertNotEqual(photo, restoredPhoto)
        XCTAssertEqual(try Data(contentsOf: media.appendingPathComponent(restoredPhoto)), archive.media[photo]?.data)
        let avatar = try XCTUnwrap(ctx.fetch(CDPet.fetchRequest()).first { $0.nickname == "小白" }?.avatarFileName)
        XCTAssertNotNil(UIImage(contentsOfFile: media.appendingPathComponent(avatar).path))
        XCTAssertEqual(try ctx.fetch(CDCustomTemplate.fetchRequest()).first?.name, "药物")
        XCTAssertEqual(try CoreDataWeightRepository(stack: target).samples(petID: try XCTUnwrap(records.first { $0.kind == RecordKind.custom.rawValue }?.petID)).first?.kg, 8.5)
        XCTAssertEqual(try CoreDataReminderRepository(stack: target).allReminders().first?.repeatRule, .weekly([2, 4]))
        XCTAssertEqual(defaults.string(forKey: "petpal.currentPetID"), selectedID.uuidString)
    }
    private func assertRejected(_ data: Data) throws {
        let target = stack("target-\(UUID())")
        try CoreDataPetRepository(stack: target).create(Pet(nickname: "原宠物", breed: "柯基"))
        let before = try FileManager.default.contentsOfDirectory(atPath: media.path)
        XCTAssertThrowsError(try PortableBackup.restore(data, stack: target, mediaDirectory: media, defaults: defaults))
        XCTAssertEqual(try target.container.viewContext.fetch(CDPet.fetchRequest()).map(\.nickname), ["原宠物"])
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: media.path)), Set(before))
    }
    func test_backupWithoutExplicitSelection_preservesDisplayedFallbackPet() throws {
        let source = stack("fallback")
        let repo = CoreDataPetRepository(stack: source)
        let old = Pet(nickname: "旧宠物", breed: "柯基", createdAt: Date(timeIntervalSince1970: 100))
        let newest = Pet(nickname: "新宠物", breed: "柯基", createdAt: Date(timeIntervalSince1970: 200))
        try repo.create(old); try repo.create(newest)
        let data = try PortableBackup.create(stack: source, mediaDirectory: media, defaults: defaults)
        XCTAssertEqual(try JSONDecoder().decode(PortableBackup.self, from: data).currentPetID, newest.id)
    }
    func test_wrongVersion_isRejectedWithoutReplacingData() throws {
        var archive = try JSONDecoder().decode(PortableBackup.self, from: populatedArchive().0)
        archive.version = 999
        try assertRejected(JSONEncoder().encode(archive))
    }
    func test_extremeOnceDate_isRejectedBeforeReplacingLiveData() throws {
        let data = try populatedArchive().0
        for interval in [1e20, -1e20] {
            var archive = try JSONDecoder().decode(PortableBackup.self, from: data)
            let url = directory.appendingPathComponent("tampered-\(UUID()).sqlite")
            try archive.database.data.write(to: url)
            let tampered = CoreDataStack(storeURL: url)
            stacks.append(tampered)
            let reminder = try XCTUnwrap(tampered.container.viewContext.fetch(CDReminder.fetchRequest()).first)
            reminder.repeatRule = String(data: try JSONEncoder().encode(RepeatRule.once(at: Date(timeIntervalSinceReferenceDate: interval))), encoding: .utf8)
            reminder.isEnabled = interval > 0
            try tampered.save()
            tampered.container.viewContext.reset()
            for store in tampered.container.persistentStoreCoordinator.persistentStores {
                try tampered.container.persistentStoreCoordinator.remove(store)
            }
            archive.database = .init(try Data(contentsOf: url))
            try assertRejected(JSONEncoder().encode(archive))
        }
    }
    func test_overBudgetDatabase_isRejectedBeforeReplacingLiveData() throws {
        let source = stack("rowBudget")
        let pet = Pet(nickname: "备份宠物", breed: "柯基")
        try CoreDataPetRepository(stack: source).create(pet)
        var archive = try JSONDecoder().decode(PortableBackup.self,
            from: PortableBackup.create(stack: source, mediaDirectory: media, defaults: defaults))
        var index = 0
        let insert = NSBatchInsertRequest(entityName: "CDRecord", dictionaryHandler: { row in
            guard index < PortableBackup.maxDatabaseRows else { return true }
            row.setDictionary(["id": UUID(), "petID": pet.id, "kind": RecordKind.checkup.rawValue,
                               "createdAt": Date(timeIntervalSince1970: Double(index))])
            index += 1
            return false
        })
        try source.container.viewContext.execute(insert)
        XCTAssertEqual(try source.container.viewContext.count(for: CDRecord.fetchRequest()), PortableBackup.maxDatabaseRows)
        source.container.viewContext.reset()
        for store in source.container.persistentStoreCoordinator.persistentStores {
            try source.container.persistentStoreCoordinator.remove(store)
        }
        archive.database = .init(try Data(contentsOf: try XCTUnwrap(source.storeURL)))
        let data = try JSONEncoder().encode(archive)
        XCTAssertLessThan(data.count, PortableBackup.maxBytes)
        let target = stack("rowBudgetTarget")
        try CoreDataPetRepository(stack: target).create(Pet(nickname: "原宠物", breed: "柯基"))
        XCTAssertThrowsError(try PortableBackup.restore(data, stack: target, mediaDirectory: media, defaults: defaults)) { error in
            guard case BackupError.tooManyRows = error else { return XCTFail("应在迁移前拒绝超出条数上限的数据库：\(error)") }
        }
        XCTAssertEqual(try target.container.viewContext.fetch(CDPet.fetchRequest()).map(\.nickname), ["原宠物"])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: media.path).isEmpty)
    }
    func test_corruptDatabaseHash_isRejectedWithoutReplacingData() throws {
        var archive = try JSONDecoder().decode(PortableBackup.self, from: populatedArchive().0)
        archive.database.data = Data("broken".utf8)
        try assertRejected(JSONEncoder().encode(archive))
    }
    func test_corruptSQLiteWithMatchingHash_isRejectedWithoutReplacingData() throws {
        var archive = try JSONDecoder().decode(PortableBackup.self, from: populatedArchive().0)
        archive.database = .init(Data("broken".utf8))
        try assertRejected(JSONEncoder().encode(archive))
    }
    func test_missingReferencedPhoto_isRejectedWithoutReplacingData() throws {
        var archive = try JSONDecoder().decode(PortableBackup.self, from: populatedArchive().0)
        archive.media.removeValue(forKey: try XCTUnwrap(archive.media.keys.first))
        try assertRejected(JSONEncoder().encode(archive))
    }
    func test_mediaWriteFailure_keepsOriginalDatabase() throws {
        let data = try populatedArchive().0
        let target = stack("target")
        try CoreDataPetRepository(stack: target).create(Pet(nickname: "原宠物", breed: "柯基"))
        let blocked = directory.appendingPathComponent("blocked")
        try Data([0]).write(to: blocked)
        XCTAssertThrowsError(try PortableBackup.restore(data, stack: target, mediaDirectory: blocked, defaults: defaults)) { error in
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain, "应到达真实媒体写入步骤")
        }
        XCTAssertEqual(try target.container.viewContext.fetch(CDPet.fetchRequest()).map(\.nickname), ["原宠物"])
    }
    func test_missingMedia_blocksExport() throws {
        let source = stack("source")
        try CoreDataPetRepository(stack: source).create(Pet(nickname: "小白", breed: "柯基", avatarFileName: "missing.jpg"))
        XCTAssertThrowsError(try PortableBackup.create(stack: source, mediaDirectory: media, defaults: defaults))
    }
    func test_restore_replacesExistingDataAndRetainsRecoverableOriginal() throws {
        let data = try populatedArchive().0
        let target = stack("existing")
        try CoreDataPetRepository(stack: target).create(Pet(nickname: "原宠物", breed: "柯基"))
        try PortableBackup.restore(data, stack: target, mediaDirectory: media, defaults: defaults)
        XCTAssertEqual(try target.container.viewContext.count(for: CDPet.fetchRequest()), 2)
        let recovery = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("Recovery-") })
        let original = CoreDataStack(storeURL: recovery.appendingPathComponent("original.sqlite"))
        stacks.append(original)
        XCTAssertNil(original.loadError)
        XCTAssertEqual(try original.container.viewContext.fetch(CDPet.fetchRequest()).map(\.nickname), ["原宠物"])
    }
    func test_autoBackup_upgradesLegacyDateKeepsTwoFullCopiesAndReportsFailure() throws {
        let source = stack("auto")
        let repo = CoreDataPetRepository(stack: source)
        let pet = Pet(nickname: "小白", breed: "柯基")
        try repo.create(pet)
        let backups = directory.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        defaults.set(now, forKey: "PetPal.lastBackupDate") // 旧版只有 sqlite，不应跳过首份完整备份。
        for i in 0..<3 {
            DatabaseBackupManager.backupIfDue(stack: source, defaults: defaults,
                now: now.addingTimeInterval(Double(i) * DatabaseBackupManager.interval), directory: backups, mediaDirectory: media)
        }
        let files = try DatabaseBackupManager.completeBackups(in: backups)
        XCTAssertEqual(files.count, 2)
        XCTAssertFalse(files.contains { $0.lastPathComponent.contains(DatabaseBackupManager.timestamp(now)) })
        let target = stack("autoRestore")
        try PortableBackup.restore(Data(contentsOf: files[0]), stack: target, mediaDirectory: media, defaults: defaults)
        XCTAssertEqual(try target.container.viewContext.fetch(CDPet.fetchRequest()).first?.nickname, "小白")
        let last = defaults.object(forKey: "PetPal.lastCompleteBackupDate") as? Date
        var broken = pet; broken.avatarFileName = "missing.jpg"
        try repo.update(broken)
        DatabaseBackupManager.backupIfDue(stack: source, defaults: defaults,
            now: now.addingTimeInterval(3 * DatabaseBackupManager.interval), directory: backups, mediaDirectory: media)
        XCTAssertNotNil(defaults.string(forKey: "PetPal.lastBackupError"))
        XCTAssertEqual(defaults.object(forKey: "PetPal.lastCompleteBackupDate") as? Date, last)
        XCTAssertEqual(try DatabaseBackupManager.completeBackups(in: backups).count, 2)
    }
    func test_restore_recoversUnreadableLiveDatabase() throws {
        let data = try populatedArchive().0
        let url = directory.appendingPathComponent("broken.sqlite")
        try Data("not a database".utf8).write(to: url)
        let target = stack("broken")
        XCTAssertNotNil(target.loadError)
        try PortableBackup.restore(data, stack: target, mediaDirectory: media, defaults: defaults)
        XCTAssertNil(target.loadError)
        XCTAssertEqual(try target.container.viewContext.count(for: CDPet.fetchRequest()), 2)
        let recovery = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("Recovery-") }
        XCTAssertFalse(recovery.isEmpty)
    }
}
