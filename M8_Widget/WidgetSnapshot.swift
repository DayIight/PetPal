import Foundation

// MARK: - Widget 快照模型（L-01；App 与 Widget Extension 共享编译，本文件不得 import WidgetKit/SwiftUI）
// 快照保存完整重复规则，Widget 独立计算任意日期，不依赖 App 每日打开。
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
        var repeatRule: RepeatRule? = nil // nil 兼容旧版当天快照；过期后不再沿用
    }
    var generatedAt: Date
    var currentPetID: UUID?
    var pets: [PetEntry]
    var reminders: [ReminderEntry]
}

struct WidgetReminderState: Equatable {
    var date: Date
    var remaining: [WidgetSnapshot.ReminderEntry]
}

struct WidgetReminderTimeline {
    var states: [WidgetReminderState]
    var refreshAfter: Date
}

// MARK: - 共享容器读写（两端只使用 App Group，私有 Documents 无法跨进程共享）
enum WidgetSnapshotStoreError: LocalizedError {
    case sharedContainerUnavailable
    var errorDescription: String? { "小组件共享容器不可用，请检查应用和扩展的 App Group 配置与构建签名。" }
}

enum WidgetSnapshotStore {
    static let appGroupID = "group.com.petpal.prototype"
    static let snapshotFileName = "widget-snapshot.json"
    static let avatarsDirName = "avatars"

    /// 未获得共享权限时返回 nil，不能用只有 App 可读的 Documents 假装同步成功。
    static var sharedDirectory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
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
    private static func fires(_ reminder: WidgetSnapshot.ReminderEntry, in snapshot: WidgetSnapshot,
                              on date: Date, calendar: Calendar) -> Bool {
        reminder.repeatRule?.fires(on: date, calendar: calendar)
            ?? calendar.isDate(date, inSameDayAs: snapshot.generatedAt)
    }

    /// 按查询日期过滤规则，再过滤已过时刻；旧快照仅允许在其生成当天使用。
    static func remainingReminders(in snapshot: WidgetSnapshot,
                                   now: Date = Date(),
                                   calendar: Calendar = .current) -> [WidgetSnapshot.ReminderEntry] {
        guard let pet = currentPet(in: snapshot) else { return [] }
        return snapshot.reminders
            .filter { r in
                guard r.petID == pet.id, fires(r, in: snapshot, on: now, calendar: calendar),
                      let date = ReminderOccurrenceBuilder.time(hour: r.hour, minute: r.minute,
                                                                on: now, calendar: calendar) else { return false }
                return date > now
            }
            .sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
    }
    static func nextReminder(in snapshot: WidgetSnapshot,
                             now: Date = Date(),
                             calendar: Calendar = .current) -> WidgetSnapshot.ReminderEntry? {
        remainingReminders(in: snapshot, now: now, calendar: calendar).first
    }

    /// 为未来一周的过点和午夜预生成状态；系统只负责按时间展示，不需要 App 刷新快照。
    static func timeline(in snapshot: WidgetSnapshot, now: Date = Date(),
                         days: Int = 7, calendar: Calendar = .current) -> WidgetReminderTimeline {
        let start = calendar.startOfDay(for: now)
        let horizon = max(1, days)
        let end = calendar.date(byAdding: .day, value: horizon, to: start) ?? now.addingTimeInterval(86400)
        var changes = Set([now])
        let petID = currentPet(in: snapshot)?.id
        for offset in 0..<horizon {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            if day > now { changes.insert(day) }
            for r in snapshot.reminders where r.petID == petID {
                guard fires(r, in: snapshot, on: day, calendar: calendar),
                      let fireDate = ReminderOccurrenceBuilder.time(hour: r.hour, minute: r.minute,
                                                                    on: day, calendar: calendar),
                      fireDate > now, fireDate < end else { continue }
                changes.insert(fireDate)
            }
        }
        return WidgetReminderTimeline(states: changes.sorted().map {
            .init(date: $0, remaining: remainingReminders(in: snapshot, now: $0, calendar: calendar))
        }, refreshAfter: end)
    }
}
