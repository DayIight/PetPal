import Foundation
@preconcurrency import CoreData
import CryptoKit
import UIKit
import ImageIO
import UserNotifications

extension Notification.Name { static let backupDidRestore = Notification.Name("PetPal.backupDidRestore") }

enum BackupError: LocalizedError, Equatable {
    case unavailable, unsupportedVersion, damaged, missingMedia(String), unsavedChanges, tooLarge, tooManyRows, mediaBudget
    var errorDescription: String? {
        switch self {
        case .unavailable: return "数据库暂时无法读取，无法创建完整备份。"
        case .unsupportedVersion: return "该备份版本与当前 App 不兼容，请使用对应版本。"
        case .damaged: return "备份损坏或数据关联不完整，原数据未被替换。"
        case .missingMedia(let name): return "照片文件缺失（\(name)），请修复后重新备份。"
        case .unsavedChanges: return "有尚未保存的操作，请完成后再备份或恢复。"
        case .tooLarge: return "此版本支持最大 200 MB 的完整备份。"
        case .mediaBudget: return "备份图片超过支持的数量、大小或像素预算，原数据未被替换。"
        case .tooManyRows: return "备份中的数据条数超过此版本支持的 100000 条，原数据未被替换。"
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
    var version = 2
    var createdAt: Date
    var appVersion: String
    var currentPetID: UUID?
    var database: Blob
    var media: [String: Blob]
    static let maxBytes = 200 * 1024 * 1024
    static let maxDatabaseRows = 100_000
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func safeName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9_-]+\.(jpg|jpeg|png|pdf)$"#, options: .regularExpression) != nil
    }

    // 独立于文件总大小的解码预算，先读 ImageIO 元信息再创建图片。
    static let maxMediaCount = 1_000
    static let maxImageBytes = 10 * 1024 * 1024
    static let maxImageDimension = 4_096
    static let maxImagePixels = 16_000_000
    static let maxTotalImagePixels = 500_000_000

    private static func validateImage(_ data: Data) throws -> Int {
        guard data.count <= maxImageBytes else { throw BackupError.mediaBudget }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source) as String?,
              ["public.jpeg", "public.png"].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw BackupError.damaged }
        guard width <= maxImageDimension, height <= maxImageDimension,
              width * height <= maxImagePixels else { throw BackupError.mediaBudget }
        guard CGImageSourceCreateImageAtIndex(source, 0, options) != nil else { throw BackupError.damaged }
        return width * height
    }

    private static func validateMedia(_ data: Data, name: String) throws -> Int {
        if URL(fileURLWithPath: name).pathExtension == "pdf" {
            do { try MedicalDocumentImporter.validatePDF(data) }
            catch { throw BackupError.damaged }
            return 0
        }
        return try validateImage(data)
    }

    /// 同步入口供已有调用方使用；正式 UI 使用下方异步入口。
    static func create(stack: CoreDataStack = .shared, mediaDirectory: URL = AvatarStore.directory,
                       defaults: UserDefaults = .standard, now: Date = Date()) throws -> Data {
        guard stack.loadError == nil, let source = stack.storeURL else { throw BackupError.unavailable }
        guard !stack.container.viewContext.hasChanges else { throw BackupError.unsavedChanges }
        return try createSnapshot(source: source, model: stack.container.managedObjectModel,
                                  mediaDirectory: mediaDirectory,
                                  currentPetID: defaults.string(forKey: "petpal.currentPetID").flatMap(UUID.init(uuidString:)),
                                  now: now, cancellation: BackupCancellation())
    }

    @MainActor static func createAsync(stack: CoreDataStack = .shared,
                                      mediaDirectory: URL = AvatarStore.directory,
                                      defaults: UserDefaults = .standard, now: Date = Date()) async throws -> Data {
        guard stack.loadError == nil, let source = stack.storeURL else { throw BackupError.unavailable }
        try stack.beginBackupOperation()
        defer { stack.endBackupOperation() }
        let model = stack.container.managedObjectModel
        let current = defaults.string(forKey: "petpal.currentPetID").flatMap(UUID.init(uuidString:))
        return try await background { cancellation in
            try createSnapshot(source: source, model: model, mediaDirectory: mediaDirectory,
                               currentPetID: current, now: now, cancellation: cancellation)
        }
    }

    private static func createSnapshot(source: URL, model: NSManagedObjectModel, mediaDirectory: URL,
                                       currentPetID: UUID?, now: Date, cancellation: BackupCancellation) throws -> Data {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let snapshot = temp.appendingPathComponent("database.sqlite")
        try cancellation.check()
        try copyStore(model: model, source: source, destination: snapshot)
        let check = try openSnapshot(snapshot, model: model)
        defer { try? close(check) }
        let context = check.newBackgroundContext()
        let (references, ids, fallback): (Set<String>, Set<UUID>, UUID?) = try context.performAndWait {
            defer { context.reset() }
            let references = try validateDatabase(context, cancellation: cancellation)
            let query = CDPet.fetchRequest()
            query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
            let pets = try context.fetch(query)
            return (references, Set(pets.compactMap(\.id)), pets.first?.id)
        }
        guard references.count <= maxMediaCount else { throw BackupError.mediaBudget }
        var media: [String: Blob] = [:]
        var total = 0
        var pixels = 0
        for name in references {
            try cancellation.check()
            let url = mediaDirectory.appendingPathComponent(name)
            guard safeName(name), FileManager.default.fileExists(atPath: url.path) else { throw BackupError.missingMedia(name) }
            let limit = url.pathExtension == "pdf" ? MedicalDocumentImporter.maxPDFBytes : maxImageBytes
            let data = try readFile(url, limit: limit)
            pixels += try validateMedia(data, name: name)
            guard pixels <= maxTotalImagePixels else { throw BackupError.mediaBudget }
            total += data.count
            guard total < maxBytes else { throw BackupError.tooLarge }
            media[name] = Blob(data)
        }
        // 关闭副本完成 WAL checkpoint，单文件包含最新页。
        try close(check)
        let backup = PortableBackup(createdAt: now,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
            currentPetID: currentPetID.flatMap { ids.contains($0) ? $0 : nil } ?? fallback,
            database: Blob(try Data(contentsOf: snapshot)), media: media)
        try cancellation.check()
        let data = try JSONEncoder().encode(backup)
        guard data.count <= maxBytes else { throw BackupError.tooLarge }
        try cancellation.check()
        return data
    }

    /// 准备对象只携带文件和 UUID，不跨队列传递 NSManagedObject。
    final class PreparedRestore: @unchecked Sendable {
        let directory: URL
        let mediaDirectory: URL
        let currentPetID: UUID?
        var newFiles: [String] = []
        var committed = false
        var databaseURL: URL { directory.appendingPathComponent("ready.sqlite") }
        init(directory: URL, mediaDirectory: URL, currentPetID: UUID?) {
            self.directory = directory; self.mediaDirectory = mediaDirectory; self.currentPetID = currentPetID
        }
        deinit {
            if !committed { newFiles.forEach { try? FileManager.default.removeItem(at: mediaDirectory.appendingPathComponent($0)) } }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    static func prepareRestore(_ data: Data, model: NSManagedObjectModel,
                               mediaDirectory: URL, cancellation: BackupCancellation = BackupCancellation()) throws -> PreparedRestore {
        try cancellation.check()
        guard data.count <= maxBytes else { throw BackupError.tooLarge }
        guard let archive = try? JSONDecoder().decode(Self.self, from: data), archive.format == "PetPalBackup" else { throw BackupError.damaged }
        guard (1...2).contains(archive.version) else { throw BackupError.unsupportedVersion }
        guard archive.media.count <= maxMediaCount else { throw BackupError.mediaBudget }
        guard archive.database.valid else { throw BackupError.damaged }
        var pixels = 0
        for (name, blob) in archive.media {
            try cancellation.check()
            guard safeName(name), blob.valid else { throw BackupError.damaged }
            pixels += try validateMedia(blob.data, name: name)
            guard pixels <= maxTotalImagePixels else { throw BackupError.mediaBudget }
        }
        let temp = try temporaryDirectory()
        let prepared = PreparedRestore(directory: temp, mediaDirectory: mediaDirectory, currentPetID: archive.currentPetID)
        let source = temp.appendingPathComponent("source.sqlite")
        try archive.database.data.write(to: source, options: .atomic)
        let staged = try openSnapshot(source, model: model)
        defer { try? close(staged) }
        let context = staged.newBackgroundContext()
        try context.performAndWait {
            defer { context.reset() }
            try validateRowBudget(context)
            // 先用 KVC 检查原始 collection，再允许迁移及 typed 属性读取。
            try validateCollections(context, cancellation: cancellation)
            try HealthDataMigration.runIfNeeded(in: context, save: { try context.save() }, checkCancellation: cancellation.check)
            try ReminderTaskMigration.runIfNeeded(in: context, save: { try context.save() })
            let references = try validateDatabase(context, cancellation: cancellation)
            guard references == Set(archive.media.keys) else { throw BackupError.damaged }
            let pets = try context.fetch(CDPet.fetchRequest())
            if let id = archive.currentPetID, !pets.contains(where: { $0.id == id }) { throw BackupError.damaged }
            var renamed: [String: String] = [:]
            for (name, blob) in archive.media {
                try cancellation.check()
                let newName = UUID().uuidString + "." + URL(fileURLWithPath: name).pathExtension
                try blob.data.write(to: mediaDirectory.appendingPathComponent(newName), options: .atomic)
                prepared.newFiles.append(newName)
                renamed[name] = newName
            }
            for pet in pets {
                try cancellation.check()
                pet.avatarFileName = pet.avatarFileName.flatMap { renamed[$0] }
            }
            for record in try context.fetch(CDRecord.fetchRequest()) {
                try cancellation.check()
                record.photoFileNames = (record.photoFileNames ?? []).compactMap { renamed[$0] }
            }
            try CareItemBackup.renameMedicalFiles(in: context, using: renamed)
            try context.save()
        }
        try cancellation.check()
        try copyStore(model: model, source: source, destination: prepared.databaseURL)
        try cancellation.check()
        return prepared
    }

    static func restore(_ data: Data, stack: CoreDataStack = .shared,
                        mediaDirectory: URL = AvatarStore.directory, defaults: UserDefaults = .standard) throws {
        guard !stack.container.viewContext.hasChanges else { throw BackupError.unsavedChanges }
        let prepared = try prepareRestore(data, model: stack.container.managedObjectModel, mediaDirectory: mediaDirectory)
        try commitRestore(prepared, stack: stack, defaults: defaults)
    }

    @MainActor static func restoreAsync(_ data: Data, stack: CoreDataStack = .shared,
                                       mediaDirectory: URL = AvatarStore.directory, defaults: UserDefaults = .standard,
                                       willCommit: () -> Void = {}) async throws {
        try stack.beginBackupOperation()
        defer { stack.endBackupOperation() }
        let model = stack.container.managedObjectModel
        let prepared = try await background { cancellation in
            try prepareRestore(data, model: model, mediaDirectory: mediaDirectory, cancellation: cancellation)
        }
        try Task.checkCancellation()
        willCommit()
        // 提交阶段与主上下文串行；开始替换后完整提交或回滚，不在中途取消。
        try commitRestore(prepared, stack: stack, defaults: defaults)
    }

    private static func commitRestore(_ prepared: PreparedRestore, stack: CoreDataStack, defaults: UserDefaults) throws {
        guard !stack.container.viewContext.hasChanges else { throw BackupError.unsavedChanges }
        try replaceLiveStore(stack: stack, source: prepared.databaseURL)
        prepared.committed = true
        defaults.set(prepared.currentPetID?.uuidString, forKey: "petpal.currentPetID")
        NotificationCenter.default.post(name: .petsDidChange, object: nil)
        NotificationCenter.default.post(name: .recordsDidChange, object: nil)
        NotificationCenter.default.post(name: .weightsDidChange, object: nil)
        NotificationCenter.default.post(name: .backupDidRestore, object: nil)
        CareItemStore.notify()
        // 原照片保留，恢复前数据库副本仍需引用它们。
    }

    static func readFile(_ url: URL, limit: Int = maxBytes) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= limit else { throw limit == maxBytes ? BackupError.tooLarge : BackupError.mediaBudget }
        let data = try Data(contentsOf: url)
        guard data.count <= limit else { throw limit == maxBytes ? BackupError.tooLarge : BackupError.mediaBudget }
        return data
    }

    static func background<T: Sendable>(_ work: @escaping @Sendable (BackupCancellation) throws -> T) async throws -> T {
        let cancellation = BackupCancellation()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            let result = try await Task.detached(priority: .userInitiated) {
                try cancellation.check()
                return try work(cancellation)
            }.value
            try Task.checkCancellation()
            return result
        }, onCancel: { cancellation.cancel() })
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
        for store in container.persistentStoreCoordinator.persistentStores { try container.persistentStoreCoordinator.remove(store) }
    }
    private static func validateRowBudget(_ context: NSManagedObjectContext) throws {
        var remaining = maxDatabaseRows
        for entity in context.persistentStoreCoordinator!.managedObjectModel.entities {
            guard let name = entity.name else { throw BackupError.damaged }
            // count 不物化对象；在迁移、全量校验和媒体写入之前限制总工作量。
            let count = try context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: name))
            guard count >= 0, count <= remaining else { throw BackupError.tooManyRows }
            remaining -= count
        }
    }
    private static func validateCollections(_ context: NSManagedObjectContext, cancellation: BackupCancellation) throws {
        for (entity, keys) in [("CDPet", ["allergens"]), ("CDRecord", ["photoFileNames", "answers"])] {
            for row in try context.fetch(NSFetchRequest<NSManagedObject>(entityName: entity)) {
                try cancellation.check()
                for key in keys {
                    guard let raw = row.value(forKey: key) else { continue }
                    if key == "answers" {
                        guard raw is [String: String] else { throw BackupError.damaged }
                    } else {
                        guard let strings = raw as? [String] else { throw BackupError.damaged }
                        if key == "photoFileNames", strings.count > MediaPolicy.maxPhotos { throw BackupError.damaged }
                    }
                }
            }
        }
    }
    private static func validateDatabase(_ ctx: NSManagedObjectContext, cancellation: BackupCancellation) throws -> Set<String> {
        try validateRowBudget(ctx)
        try validateCollections(ctx, cancellation: cancellation)
        let pets = try ctx.fetch(CDPet.fetchRequest())
        let petIDs = Set(pets.compactMap(\.id))
        guard petIDs.count == pets.count else { throw BackupError.damaged }
        for entity in ctx.persistentStoreCoordinator!.managedObjectModel.entities {
            try cancellation.check()
            guard let name = entity.name else { throw BackupError.damaged }
            let rows = try ctx.fetch(NSFetchRequest<NSManagedObject>(entityName: name))
            let ids = rows.compactMap { $0.value(forKey: "id") as? UUID }
            guard Set(ids).count == rows.count else { throw BackupError.damaged }
            if entity.attributesByName["petID"] != nil {
                guard rows.allSatisfy({ ($0.value(forKey: "petID") as? UUID).map { petIDs.contains($0) } ?? false }) else { throw BackupError.damaged }
            }
        }
        for template in try ctx.fetch(CDCustomTemplate.fetchRequest()) {
            try cancellation.check()
            guard let payload = template.payload, let value = try? JSONDecoder().decode(CustomTemplate.self, from: Data(payload.utf8)),
                  value.id == template.id else { throw BackupError.damaged }
        }
        let records = try ctx.fetch(CDRecord.fetchRequest())
        let recordsByID = Dictionary(uniqueKeysWithValues: records.compactMap { record in record.id.map { ($0, record) } })
        for record in records where record.templateSchemaVersion != 0 || record.templateSnapshot != nil {
            try cancellation.check()
            guard record.templateSchemaVersion == 1, let raw = record.templateSnapshot,
                  let snapshot = try? JSONDecoder().decode(CustomTemplate.self, from: Data(raw.utf8)),
                  snapshot.id == record.templateID else { throw BackupError.damaged }
        }
        var completionKeys = Set<String>()
        for record in records {
            if let date = record.occurredAt, !ReminderRecurrence.isSupportedDate(date) { throw BackupError.damaged }
            if let id = record.completedReminderID {
                guard let due = record.completedDueAt, ReminderRecurrence.isSupportedDate(due),
                      let day = record.completedDay,
                      day == "once:\(due.timeIntervalSinceReferenceDate)" || day.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$"#, options: .regularExpression) != nil,
                      completionKeys.insert(ReminderTaskKey.make(reminderID: id, day: day, type: record.kind ?? "")).inserted else { throw BackupError.damaged }
            } else if record.completedDueAt != nil || record.completedDay != nil { throw BackupError.damaged }
        }
        var weightSources = Set<UUID>()
        for sample in try ctx.fetch(CDWeightSample.fetchRequest()) {
            try cancellation.check()
            guard WeightValidator.isValid(sample.kg) else { throw BackupError.damaged }
            if let source = sample.sourceRecordID {
                guard let record = recordsByID[source], record.petID == sample.petID,
                      record.kind == RecordKind.checkup.rawValue,
                      weightSources.insert(source).inserted else { throw BackupError.damaged }
            }
        }
        let reminders = try ctx.fetch(CDReminder.fetchRequest())
        let reminderPets = Dictionary(uniqueKeysWithValues: reminders.compactMap { r in r.id.map { ($0, r.petID) } })
        for record in records {
            if let id = record.completedReminderID, let pet = reminderPets[id], pet != record.petID { throw BackupError.damaged }
        }
        for r in reminders {
            try cancellation.check()
            if let since = r.trackingSince, !ReminderRecurrence.isSupportedDate(since) || since < Date(timeIntervalSince1970: 0) { throw BackupError.damaged }
            guard ReminderType(rawValue: r.type ?? "") != nil,
                  let advance = AdvanceOption(rawValue: r.advance ?? "准时"),
                  let raw = r.repeatRule, let rule = try? JSONDecoder().decode(RepeatRule.self, from: Data(raw.utf8)),
                  ReminderRecurrence.validationError(rule: rule, hour: Int(r.hour), minute: Int(r.minute), advance: advance) == nil else { throw BackupError.damaged }
            if let source = r.sourceRecordID {
                guard let record = recordsByID[source], record.petID == r.petID else { throw BackupError.damaged }
            }
        }
        let imageFiles = pets.compactMap(\.avatarFileName) + records.flatMap { $0.photoFileNames ?? [] }
        guard imageFiles.allSatisfy({ safeName($0) && URL(fileURLWithPath: $0).pathExtension != "pdf" }) else { throw BackupError.damaged }
        let medicalFiles = try CareItemBackup.validate(in: ctx)
        guard medicalFiles.isDisjoint(with: Set(imageFiles)) else { throw BackupError.damaged }
        let files = imageFiles + Array(medicalFiles)
        guard Set(files).count <= maxMediaCount else { throw BackupError.mediaBudget }
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

/// Core Data perform 队列不继承 Swift Task 的取消状态，显式传递线程安全信号。
final class BackupCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}
