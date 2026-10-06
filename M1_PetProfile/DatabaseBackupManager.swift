import Foundation
import CoreData

// MARK: - 每周完整备份（Documents/Backups，保留最新 2 份）
// 安全复制：用独立 coordinator 调 replacePersistentStore（API 层处理 WAL checkpoint），
// 不直接 FileManager 拷贝主库，避免丢失 -wal 中未落盘数据；不干扰在线 store。
// 启动/回前台生成完整备份（数据库与媒体），满 7 天执行一次；失败状态在备份页展示。
// 旧 sqlite-only 方法保留以读取历史备份与测试，用户恢复只接受完整 .petpalbackup。
enum DatabaseBackupManager {
    static let keepCount = 2
    static let interval: TimeInterval = 7 * 24 * 3600
    private static let lastBackupKey = "PetPal.lastCompleteBackupDate"

    /// 距上次备份满一周才执行；inMemory stack（storeURL 为 nil）跳过
    static func backupIfDue(stack: CoreDataStack = .shared,
                            defaults: UserDefaults = .standard,
                            now: Date = Date(), directory: URL? = nil,
                            mediaDirectory: URL = AvatarStore.directory) {
        guard stack.storeURL != nil, stack.loadError == nil else { return }
        if let last = defaults.object(forKey: lastBackupKey) as? Date,
           now.timeIntervalSince(last) < interval { return }
        do {
            let data = try PortableBackup.create(stack: stack, mediaDirectory: mediaDirectory, defaults: defaults, now: now)
            let dir = try directory ?? backupDirectory()
            let url = dir.appendingPathComponent("PetPal-\(timestamp(now))-\(UUID().uuidString).petpalbackup")
            try data.write(to: url, options: .atomic)
            let files = try completeBackups(in: dir)
            for old in files.dropFirst(keepCount) { try FileManager.default.removeItem(at: old) }
            defaults.set(now, forKey: lastBackupKey)
            defaults.removeObject(forKey: "PetPal.lastBackupError")
        } catch {
            defaults.set(error.localizedDescription, forKey: "PetPal.lastBackupError")
        }
    }

    static func completeBackups(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "petpalbackup" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Documents/Backups（不存在则创建）
    static func backupDirectory() throws -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 执行一次备份并裁剪旧文件；model/storeURL/directory 可注入，便于测试
    static func backup(model: NSManagedObjectModel, storeURL: URL, to directory: URL,
                       now: Date = Date()) throws {
        let name = "PetPal-\(timestamp(now)).sqlite"
        let destination = directory.appendingPathComponent(name)
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.replacePersistentStore(
            at: destination,
            destinationOptions: nil,
            withPersistentStoreFrom: storeURL,
            sourceOptions: [NSReadOnlyPersistentStoreOption: true],
            ofType: NSSQLiteStoreType)
        try prune(directory: directory)
    }

    /// 文件名时间戳（yyyyMMddHHmmss，字典序即时间序）
    static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMddHHmmss"
        return f.string(from: date)
    }

    /// 仅保留最新 keepCount 份备份
    static func prune(directory: URL, keep: Int = keepCount) throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }   // 新→旧
        for url in files.dropFirst(max(0, keep)) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
