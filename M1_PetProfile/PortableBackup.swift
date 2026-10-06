import Foundation
import CoreData
import CryptoKit
import UIKit
import UserNotifications

extension Notification.Name { static let backupDidRestore = Notification.Name("PetPal.backupDidRestore") }

enum BackupError: LocalizedError {
    case unavailable, unsupportedVersion, damaged, missingMedia(String), unsavedChanges, tooLarge
    var errorDescription: String? {
        switch self {
        case .unavailable: return "数据库暂时无法读取，无法创建完整备份。"
        case .unsupportedVersion: return "该备份版本与当前 App 不兼容，请使用对应版本。"
        case .damaged: return "备份损坏或数据关联不完整，原数据未被替换。"
        case .missingMedia(let name): return "照片文件缺失（\(name)），请修复后重新备份。"
        case .unsavedChanges: return "有尚未保存的操作，请完成后再备份或恢复。"
        case .tooLarge: return "此版本支持最大 200 MB 的完整备份。"
        }
    }
}

/// 单文件备份：数据库快照 + 所有被引用的媒体 + 版本与完整性校验。
/// 校验用于识别损坏，不提供加密或来源认证；备份应由用户保存在可信位置。
struct PortableBackup: Codable {
    struct Blob: Codable {
        var data: Data
        var sha256: String
        init(_ data: Data) { self.data = data; sha256 = PortableBackup.digest(data) }
        var valid: Bool { sha256 == PortableBackup.digest(data) }
    }
    var format = "PetPalBackup"
    var version = 1
    var createdAt: Date
    var appVersion: String
    var currentPetID: UUID?
    var database: Blob
    var media: [String: Blob]
    static let maxBytes = 200 * 1024 * 1024
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func safeName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9_-]+\.(jpg|jpeg|png)$"#, options: .regularExpression) != nil
    }

    /// 在 viewContext 所属队列调用，避免快照和媒体删除之间出现交叉写入。
    static func create(stack: CoreDataStack = .shared, mediaDirectory: URL = AvatarStore.directory,
                       defaults: UserDefaults = .standard, now: Date = Date()) throws -> Data {
        guard stack.loadError == nil, let source = stack.storeURL else { throw BackupError.unavailable }
        guard !stack.container.viewContext.hasChanges else { throw BackupError.unsavedChanges }
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let snapshot = temp.appendingPathComponent("database.sqlite")
        try copyStore(model: stack.container.managedObjectModel, source: source, destination: snapshot)
        let check = try openSnapshot(snapshot, model: stack.container.managedObjectModel)
        defer { try? close(check) }
        let references = try validateDatabase(check)
        var media: [String: Blob] = [:]
        var total = 0
        for name in references {
            guard safeName(name), let data = try? Data(contentsOf: mediaDirectory.appendingPathComponent(name)),
                  UIImage(data: data) != nil else { throw BackupError.missingMedia(name) }
            total += data.count
            guard total < maxBytes else { throw BackupError.tooLarge }
            media[name] = Blob(data)
        }
        let query = CDPet.fetchRequest()
        query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        let pets = try check.viewContext.fetch(query)
        let ids = Set(pets.compactMap(\.id))
        let fallbackCurrentID = pets.first?.id
        let current = defaults.string(forKey: "petpal.currentPetID").flatMap(UUID.init(uuidString:))
        // Core Data 打开副本时可能启用 WAL。关闭后完成 checkpoint，单文件才包含最新页。
        try close(check)
        let backup = PortableBackup(createdAt: now,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
            currentPetID: current.flatMap { ids.contains($0) ? $0 : nil } ?? fallbackCurrentID,
            database: Blob(try Data(contentsOf: snapshot)), media: media)
        let data = try JSONEncoder().encode(backup)
        guard data.count <= maxBytes else { throw BackupError.tooLarge }
        return data
    }

    /// 完整校验后才触碰主库；照片使用新的文件名，失败不会覆盖或删除旧照片。
    static func restore(_ data: Data, stack: CoreDataStack = .shared,
                        mediaDirectory: URL = AvatarStore.directory, defaults: UserDefaults = .standard) throws {
        guard data.count <= maxBytes else { throw BackupError.tooLarge }
        guard let archive = try? JSONDecoder().decode(Self.self, from: data), archive.format == "PetPalBackup" else {
            throw BackupError.damaged
        }
        guard archive.version == 1 else { throw BackupError.unsupportedVersion }
        guard archive.database.valid, archive.media.allSatisfy({ safeName($0.key) && $0.value.valid && UIImage(data: $0.value.data) != nil }) else {
            throw BackupError.damaged
        }
        guard !stack.container.viewContext.hasChanges else { throw BackupError.unsavedChanges }
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let source = temp.appendingPathComponent("source.sqlite")
        try archive.database.data.write(to: source, options: .atomic)
        let staged = try openSnapshot(source, model: stack.container.managedObjectModel)
        defer { try? close(staged) }
        try HealthDataMigration.linkLegacyWeights(in: staged.viewContext)
        let references = try validateDatabase(staged)
        guard references == Set(archive.media.keys) else { throw BackupError.damaged }
        let pets = try staged.viewContext.fetch(CDPet.fetchRequest())
        if let id = archive.currentPetID, !pets.contains(where: { $0.id == id }) { throw BackupError.damaged }
        var newFiles: [String] = []
        var committed = false
        defer {
            if !committed { newFiles.forEach { try? FileManager.default.removeItem(at: mediaDirectory.appendingPathComponent($0)) } }
        }
        var renamed: [String: String] = [:]
        for (name, blob) in archive.media {
            let newName = UUID().uuidString + "." + URL(fileURLWithPath: name).pathExtension
            try blob.data.write(to: mediaDirectory.appendingPathComponent(newName), options: .atomic)
            newFiles.append(newName)
            renamed[name] = newName
        }
        for pet in pets { pet.avatarFileName = pet.avatarFileName.flatMap { renamed[$0] } }
        for record in try staged.viewContext.fetch(CDRecord.fetchRequest()) {
            record.photoFileNames = (record.photoFileNames ?? []).compactMap { renamed[$0] }
        }
        try staged.viewContext.save()
        let ready = temp.appendingPathComponent("ready.sqlite")
        try copyStore(model: staged.managedObjectModel, source: source, destination: ready)
        // 安全副本保留在主库同级 Recovery-* 目录；恢复失败也保留以便诊断。
        try replaceLiveStore(stack: stack, source: ready)
        committed = true
        defaults.set(archive.currentPetID?.uuidString ?? pets.first?.id?.uuidString, forKey: "petpal.currentPetID")
        NotificationCenter.default.post(name: .petsDidChange, object: nil)
        NotificationCenter.default.post(name: .recordsDidChange, object: nil)
        NotificationCenter.default.post(name: .weightsDidChange, object: nil)
        NotificationCenter.default.post(name: .backupDidRestore, object: nil)
        // 原照片不删除：恢复前数据库副本仍需引用它们；避免恢复失败或后悔时无法回退。
    }

    static func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PetPalBackup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static func copyStore(model: NSManagedObjectModel, source: URL, destination: URL) throws {
        try NSPersistentStoreCoordinator(managedObjectModel: model).replacePersistentStore(
            at: destination, destinationOptions: [NSSQLitePragmasOption: ["journal_mode": "DELETE"]],
            withPersistentStoreFrom: source, sourceOptions: [NSReadOnlyPersistentStoreOption: true], ofType: NSSQLiteStoreType)
    }
    private static func openSnapshot(_ url: URL, model: NSManagedObjectModel) throws -> NSPersistentContainer {
        do {
            let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: url)
            guard model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) ||
                  NSManagedObjectModel.mergedModel(from: [Bundle.main], forStoreMetadata: metadata) != nil else { throw BackupError.unsupportedVersion }
            let container = NSPersistentContainer(name: "PetPal", managedObjectModel: model)
            let description = NSPersistentStoreDescription(url: url)
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
            description.shouldAddStoreAsynchronously = false
            container.persistentStoreDescriptions = [description]
            var failure: Error?
            container.loadPersistentStores { _, error in failure = error }
            if let failure { throw failure }
            return container
        } catch let error as BackupError { throw error }
        catch { throw BackupError.damaged }
    }
    private static func close(_ container: NSPersistentContainer) throws {
        container.viewContext.reset()
        for store in container.persistentStoreCoordinator.persistentStores { try container.persistentStoreCoordinator.remove(store) }
    }
    private static func validateDatabase(_ container: NSPersistentContainer) throws -> Set<String> {
        let ctx = container.viewContext
        let pets = try ctx.fetch(CDPet.fetchRequest())
        let petIDs = Set(pets.compactMap(\.id))
        guard petIDs.count == pets.count else { throw BackupError.damaged }
        for entity in container.managedObjectModel.entities {
            guard let name = entity.name else { throw BackupError.damaged }
            let rows = try ctx.fetch(NSFetchRequest<NSManagedObject>(entityName: name))
            let ids = rows.compactMap { $0.value(forKey: "id") as? UUID }
            guard Set(ids).count == rows.count else { throw BackupError.damaged }
            if entity.attributesByName["petID"] != nil {
                guard rows.allSatisfy({ ($0.value(forKey: "petID") as? UUID).map { petIDs.contains($0) } ?? false }) else { throw BackupError.damaged }
            }
        }
        for template in try ctx.fetch(CDCustomTemplate.fetchRequest()) {
            guard let payload = template.payload, let value = try? JSONDecoder().decode(CustomTemplate.self, from: Data(payload.utf8)),
                  value.id == template.id else { throw BackupError.damaged }
        }
        let records = try ctx.fetch(CDRecord.fetchRequest())
        let recordsByID = Dictionary(uniqueKeysWithValues: records.compactMap { record in record.id.map { ($0, record) } })
        for record in records where record.templateSchemaVersion != 0 || record.templateSnapshot != nil {
            guard record.templateSchemaVersion == 1, let raw = record.templateSnapshot,
                  let snapshot = try? JSONDecoder().decode(CustomTemplate.self, from: Data(raw.utf8)),
                  snapshot.id == record.templateID else { throw BackupError.damaged }
        }
        var weightSources = Set<UUID>()
        for sample in try ctx.fetch(CDWeightSample.fetchRequest()) {
            guard WeightValidator.isValid(sample.kg) else { throw BackupError.damaged }
            if let source = sample.sourceRecordID {
                guard let record = recordsByID[source], record.petID == sample.petID,
                      record.kind == RecordKind.checkup.rawValue,
                      weightSources.insert(source).inserted else { throw BackupError.damaged }
            }
        }
        for r in try ctx.fetch(CDReminder.fetchRequest()) {
            guard (0...23).contains(r.hour), (0...59).contains(r.minute),
                  ReminderType(rawValue: r.type ?? "") != nil,
                  AdvanceOption(rawValue: r.advance ?? "准时") != nil,
                  let rule = r.repeatRule, (try? JSONDecoder().decode(RepeatRule.self, from: Data(rule.utf8))) != nil else { throw BackupError.damaged }
            if let source = r.sourceRecordID {
                guard let record = recordsByID[source], record.petID == r.petID else { throw BackupError.damaged }
            }
        }
        let files = pets.compactMap(\.avatarFileName) + (try ctx.fetch(CDRecord.fetchRequest())).flatMap { $0.photoFileNames ?? [] }
        guard files.allSatisfy(safeName) else { throw BackupError.damaged }
        return Set(files)
    }
    private static func replaceLiveStore(stack: CoreDataStack, source: URL) throws {
        guard let destination = stack.storeURL else { throw BackupError.unavailable }
        let coordinator = stack.container.persistentStoreCoordinator
        let recovery = destination.deletingLastPathComponent().appendingPathComponent("Recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        let original = recovery.appendingPathComponent("original.sqlite")
        let hadStore = !coordinator.persistentStores.isEmpty
        if hadStore {
            try copyStore(model: stack.container.managedObjectModel, source: destination, destination: original)
        } else {
            // 加载失败的库不可读时保留原始 sqlite 与 WAL，不尝试解释损坏内容。
            for suffix in ["", "-wal", "-shm"] {
                let file = URL(fileURLWithPath: destination.path + suffix)
                if FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.copyItem(at: file, to: recovery.appendingPathComponent("original.sqlite" + suffix))
                }
            }
        }
        stack.container.viewContext.reset()
        for store in coordinator.persistentStores { try coordinator.remove(store) }
        do {
            try copyStore(model: stack.container.managedObjectModel, source: source, destination: destination)
            try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: destination)
            stack.setLoadError(nil)
        } catch {
            let restoreError = error
            do {
                if hadStore {
                    try copyStore(model: stack.container.managedObjectModel, source: original, destination: destination)
                    try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: destination)
                } else {
                    for suffix in ["", "-wal", "-shm"] {
                        let file = URL(fileURLWithPath: destination.path + suffix)
                        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                        let old = recovery.appendingPathComponent("original.sqlite" + suffix)
                        if FileManager.default.fileExists(atPath: old.path) { try FileManager.default.copyItem(at: old, to: file) }
                    }
                }
            } catch { stack.setLoadError(error) }
            throw restoreError
        }
    }

    /// 数据恢复成功后单独重建通知。送达失败不会被描述为数据恢复失败。
    @MainActor static func rebuildNotifications() async -> String? {
        await ReminderService.shared.rescheduleAll()
        if ReminderService.shared.permission != .granted {
            return "数据已恢复。通知尚未授权，请在系统设置中开启后检查提醒。"
        }
        return ReminderService.shared.scheduleError.map { "数据已恢复。" + $0 }
    }
}
