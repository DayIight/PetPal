import Foundation

// MARK: - Widget 快照模型（L-01；App 与 Widget Extension 共享编译，本文件不得 import WidgetKit/SwiftUI）
// 契约：reminders 仅含「当天会触发」的提醒（Syncer 已按 RepeatRule 与当天日历过滤），
// Widget 侧只需再按当前时刻过滤「未过」项即可。
struct WidgetSnapshot: Codable, Equatable {
    struct PetEntry: Codable, Equatable, Identifiable {
        var id: UUID
        var nickname: String
        var species: String            // PetSpecies.rawValue
        var avatarFileName: String?    // 文件名；实体文件在共享容器 avatars/ 下
    }
    struct ReminderEntry: Codable, Equatable, Identifiable {
        var id: UUID
        var petID: UUID
        var petName: String
        var type: String               // ReminderType.rawValue
        var hour: Int                  // 0-23
        var minute: Int                // 0-59
    }
    var generatedAt: Date
    var currentPetID: UUID?
    var pets: [PetEntry]
    var reminders: [ReminderEntry]
}

// MARK: - 共享容器读写（App Group 不可用时回退 Documents，widget 侧读到 nil 走引导态，不崩）
enum WidgetSnapshotStore {
    static let appGroupID = "group.com.petpal.prototype"
    static let snapshotFileName = "widget-snapshot.json"
    static let avatarsDirName = "avatars"

    /// App Group 共享容器；未签名/沙箱限制导致 nil 时回退 Documents（仅 App 可读，widget 显示空态）
    static var sharedDirectory: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func write(_ snapshot: WidgetSnapshot, to directory: URL) throws {
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: directory.appendingPathComponent(snapshotFileName), options: .atomic)
    }

    static func read(from directory: URL) -> WidgetSnapshot? {
        let url = directory.appendingPathComponent(snapshotFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    /// 把 App Documents 中的头像复制进共享容器 avatars/（widget 无法读 App 私有目录）
    static func copyAvatar(fileName: String, from sourceDir: URL, to directory: URL) {
        guard !fileName.isEmpty else { return }
        let destDir = directory.appendingPathComponent(avatarsDirName)
        let dest = destDir.appendingPathComponent(fileName)
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: sourceDir.appendingPathComponent(fileName), to: dest)
    }

    static func avatarURL(fileName: String, in directory: URL) -> URL {
        directory.appendingPathComponent(avatarsDirName).appendingPathComponent(fileName)
    }
}

// MARK: - 查询（纯函数，独立可测）
enum WidgetSnapshotQueries {
    static func currentPet(in snapshot: WidgetSnapshot) -> WidgetSnapshot.PetEntry? {
        if let id = snapshot.currentPetID, let p = snapshot.pets.first(where: { $0.id == id }) { return p }
        return snapshot.pets.first
    }
    /// 当前宠物今日「未过」的提醒，按时分升序（snapshot.reminders 已是当天会触发的全集）
    static func remainingReminders(in snapshot: WidgetSnapshot,
                                   now: Date = Date(),
                                   calendar: Calendar = .current) -> [WidgetSnapshot.ReminderEntry] {
        guard let pet = currentPet(in: snapshot) else { return [] }
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        return snapshot.reminders
            .filter { $0.petID == pet.id && ($0.hour, $0.minute) > (hour, minute) }
            .sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
    }
    static func nextReminder(in snapshot: WidgetSnapshot,
                             now: Date = Date(),
                             calendar: Calendar = .current) -> WidgetSnapshot.ReminderEntry? {
        remainingReminders(in: snapshot, now: now, calendar: calendar).first
    }
}
