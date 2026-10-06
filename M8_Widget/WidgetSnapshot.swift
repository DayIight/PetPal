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
        var repeatRule: RepeatRule?
        var advance: AdvanceOption?
        var isEnabled: Bool?
        var fireDate: Date?
        var isAdvance: Bool?
        var occurrenceKey: String { "\(id)#\(fireDate?.timeIntervalSince1970 ?? 0)#\(isAdvance == true)" }
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

    static func pruneAvatars(keeping names: Set<String>, in directory: URL) throws {
        let avatars = directory.appendingPathComponent(avatarsDirName)
        guard FileManager.default.fileExists(atPath: avatars.path) else { return }
        for url in try FileManager.default.contentsOfDirectory(at: avatars, includingPropertiesForKeys: nil) {
            if !names.contains(url.lastPathComponent) { try FileManager.default.removeItem(at: url) }
        }
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
    /// 保留规则并在 Widget 中重新计算，跨天无需依赖 App 更新快照。
    static func remainingReminders(in snapshot: WidgetSnapshot, now: Date = Date(),
                                   calendar: Calendar = .current) -> [WidgetSnapshot.ReminderEntry] {
        guard let pet = currentPet(in: snapshot) else { return [] }
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start),
              let searchEnd = calendar.date(byAdding: .day, value: 3, to: end) else { return [] }
        var events: [WidgetSnapshot.ReminderEntry] = []
        for reminder in snapshot.reminders where reminder.petID == pet.id && reminder.isEnabled != false {
            // 旧版快照只含生成当天的项目，跨天必须失效，防止周一提醒出现在周二。
            if reminder.repeatRule == nil && !calendar.isDate(snapshot.generatedAt, inSameDayAs: now) { continue }
            let rule = reminder.repeatRule ?? .daily
            let dates = ReminderRecurrence.dates(rule: rule, hour: reminder.hour, minute: reminder.minute,
                                                 after: start.addingTimeInterval(-1), through: searchEnd, calendar: calendar)
            for due in dates {
                let advance = reminder.advance ?? .none
                let early = advance.fireDate(for: due, calendar: calendar)
                for (date, isAdvance) in [(due, false), (early, true)] {
                    guard !isAdvance || advance != .none, date > now, date < end else { continue }
                    var event = reminder
                    event.fireDate = date; event.isAdvance = isAdvance
                    event.hour = calendar.component(.hour, from: date); event.minute = calendar.component(.minute, from: date)
                    if isAdvance { event.type = "\(reminder.type)（\(advance.rawValue)）" }
                    events.append(event)
                }
            }
        }
        return events.sorted { ($0.fireDate ?? .distantFuture) < ($1.fireDate ?? .distantFuture) }
    }
    static func timelineDates(in snapshot: WidgetSnapshot, now: Date, calendar: Calendar = .current) -> [Date] {
        var dates: Set<Date> = [now]
        for offset in 0...2 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) else { continue }
            if day > now { dates.insert(day) }
            let events = remainingReminders(in: snapshot, now: day, calendar: calendar)
            for event in events { if let date = event.fireDate, date > now { dates.insert(date) } }
        }
        return dates.sorted()
    }
    static func nextReminder(in snapshot: WidgetSnapshot,
                             now: Date = Date(),
                             calendar: Calendar = .current) -> WidgetSnapshot.ReminderEntry? {
        remainingReminders(in: snapshot, now: now, calendar: calendar).first
    }
}
