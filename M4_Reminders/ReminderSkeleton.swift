import Foundation
import CoreData
import UserNotifications

// MARK: - 模型
enum ReminderType: String, CaseIterable, Identifiable {
    case feeding = "喂食", vaccine = "疫苗", deworming = "驱虫", checkup = "体检", medication = "服药"
    var id: String { rawValue }
    var action: String { self == .vaccine ? "接种疫苗" : rawValue }
}

enum RepeatRule: Codable, Equatable {   // 每周多选/提前量 UI 编排为延后项，规则已全量支持
    case daily
    case weekly(Set<Int>)               // 1=周日 ... 7=周六
    case monthly(day: Int)
    case yearly(month: Int, day: Int)
}

struct Reminder: Identifiable, Equatable {
    var id = UUID()
    var petID: UUID
    var petName = ""                    // 随提醒落库，时区重建/重排时无需回查 M1
    var type: ReminderType
    var hour: Int                       // 0-23
    var minute: Int                     // 0-59
    var repeatRule: RepeatRule = .daily
    var advance: AdvanceOption = .none  // 提前提醒量
}

// MARK: - 提前量（PRD §4：5分钟/15分钟/30分钟/1小时/1天/3天）
enum AdvanceOption: String, Codable, CaseIterable, Identifiable {
    case none = "准时", m5 = "提前5分钟", m15 = "提前15分钟", m30 = "提前30分钟"
    case h1 = "提前1小时", d1 = "提前1天", d3 = "提前3天"
    var id: String { rawValue }
    var seconds: TimeInterval {
        switch self {
        case .none: return 0
        case .m5: return 300; case .m15: return 900; case .m30: return 1800
        case .h1: return 3600; case .d1: return 86400; case .d3: return 259200
        }
    }
}

// MARK: - 通知内容/触发器（纯函数，独立可测）
enum ReminderContentBuilder {
    static func content(type: ReminderType, petName: String,
                        reminderID: UUID, petID: UUID) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = "\(type.rawValue)提醒"
        c.body = "该给【\(petName)】\(type.action)了"
        c.sound = .default
        c.userInfo = ["route": "reminder", "reminderID": reminderID.uuidString,
                      "petID": petID.uuidString]
        return c
    }
    /// 提前提醒变体：正文同样必含【昵称】，并标注提前量
    static func advanceContent(type: ReminderType, petName: String, advance: AdvanceOption,
                               reminderID: UUID, petID: UUID) -> UNMutableNotificationContent {
        let c = content(type: type, petName: petName, reminderID: reminderID, petID: petID)
        c.body = "\(advance.rawValue)：该给【\(petName)】\(type.action)了"
        return c
    }
}

enum ReminderTriggerBuilder {
    static func triggers(rule: RepeatRule, hour: Int, minute: Int) -> [UNCalendarNotificationTrigger] {
        let base = DateComponents(hour: hour, minute: minute)
        switch rule {
        case .daily:
            return [.init(dateMatching: base, repeats: true)]
        case .weekly(let days):
            return days.sorted().map { var d = base; d.weekday = $0
                return .init(dateMatching: d, repeats: true) }
        case .monthly(let day):
            var d = base; d.day = day; return [.init(dateMatching: d, repeats: true)]
        case .yearly(let month, let day):
            var d = base; d.month = month; d.day = day; return [.init(dateMatching: d, repeats: true)]
        }
    }
    /// 提前量触发器：把每个主触发器对应的日期成分整体前移 advance，
    /// 用真实日历计算（周几回绕、跨月/跨年由 Calendar 处理），再重建为重复触发器
    static func advanceTriggers(rule: RepeatRule, hour: Int, minute: Int,
                                advance: AdvanceOption,
                                calendar: Calendar = .current) -> [UNCalendarNotificationTrigger] {
        guard advance != .none else { return [] }
        func shifted(_ matching: DateComponents, extract: [Calendar.Component]) -> DateComponents? {
            guard let next = calendar.nextDate(after: Date(), matching: matching,
                                               matchingPolicy: .nextTime) else { return nil }
            let shiftedDate = next.addingTimeInterval(-advance.seconds)
            return calendar.dateComponents(Set(extract), from: shiftedDate)
        }
        switch rule {
        case .daily:
            guard let d = shifted(.init(hour: hour, minute: minute), extract: [.hour, .minute]) else { return [] }
            return [.init(dateMatching: d, repeats: true)]
        case .weekly(let days):
            return days.sorted().compactMap { weekday in
                shifted(.init(hour: hour, minute: minute, weekday: weekday),
                        extract: [.weekday, .hour, .minute])
            }.map { UNCalendarNotificationTrigger(dateMatching: $0, repeats: true) }
        case .monthly(let day):
            guard let d = shifted(.init(day: day, hour: hour, minute: minute),
                                  extract: [.day, .hour, .minute]) else { return [] }
            return [.init(dateMatching: d, repeats: true)]
        case .yearly(let month, let day):
            guard let d = shifted(.init(month: month, day: day, hour: hour, minute: minute),
                                  extract: [.month, .day, .hour, .minute]) else { return [] }
            return [.init(dateMatching: d, repeats: true)]
        }
    }
}

// MARK: - 调度边界（UNUserNotificationCenter 协议化，测试用 Mock 替换）
protocol NotificationScheduling: AnyObject {
    func requestAuthorization() async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func removePending(matchingPrefix prefix: String)
}

// MARK: - 存储边界（CDReminder：id/petID UUID、type/repeatRule/petName String、hour/minute Int16）
protocol ReminderRepository: AnyObject {
    func reminders(petID: UUID) throws -> [Reminder]
    func allReminders() throws -> [Reminder]   // M-06：时区/日历变更后全量重排用
    func save(_ reminder: Reminder) throws
    func deleteAll(petID: UUID) throws
}

final class CoreDataReminderRepository: ReminderRepository {
    private let stack: CoreDataStack
    init(stack: CoreDataStack = .shared) { self.stack = stack }
    private var ctx: NSManagedObjectContext { stack.container.viewContext }
    func reminders(petID: UUID) throws -> [Reminder] {
        let r = CDReminder.fetchRequest(); r.predicate = NSPredicate(format: "petID == %@", petID as CVarArg)
        return try ctx.fetch(r).map(Reminder.init)
    }
    func allReminders() throws -> [Reminder] {
        try ctx.fetch(CDReminder.fetchRequest()).map(Reminder.init)
    }
    func save(_ reminder: Reminder) throws {
        let r = CDReminder.fetchRequest(); r.predicate = NSPredicate(format: "id == %@", reminder.id as CVarArg)
        reminder.apply(to: try ctx.fetch(r).first ?? stack.insert(CDReminder.self))
        try ctx.save()
    }
    func deleteAll(petID: UUID) throws {
        let r = CDReminder.fetchRequest(); r.predicate = NSPredicate(format: "petID == %@", petID as CVarArg)
        try ctx.fetch(r).forEach(ctx.delete); try ctx.save()
    }
}

private extension Reminder {
    init(_ e: CDReminder) {
        let rule = e.repeatRule
            .flatMap { try? JSONDecoder().decode(RepeatRule.self, from: Data($0.utf8)) } ?? .daily
        self.init(id: e.id ?? UUID(), petID: e.petID ?? UUID(), petName: e.petName ?? "",
                  type: ReminderType(rawValue: e.type ?? "") ?? .feeding,
                  hour: Int(e.hour), minute: Int(e.minute), repeatRule: rule,
                  advance: AdvanceOption(rawValue: e.advance ?? "") ?? .none)
    }
    func apply(to e: CDReminder) {
        e.id = id; e.petID = petID; e.petName = petName; e.type = type.rawValue
        e.hour = Int16(hour); e.minute = Int16(minute)
        e.repeatRule = String(data: (try? JSONEncoder().encode(repeatRule)) ?? Data(), encoding: .utf8)
        e.advance = advance.rawValue
    }
}

// MARK: - 编排层（权限 + 存库 + 调度；M1 删除宠物时调用 removeAll）
@MainActor final class ReminderService: ObservableObject {
    enum PermissionState { case unknown, granted, denied }
    @Published private(set) var permission: PermissionState = .unknown
    private let repo: ReminderRepository
    private let scheduler: NotificationScheduling
    private var timezoneObserver: NSObjectProtocol?
    /// L-01：提醒数据变更钩子（WidgetSnapshotSyncer 注入，重建 widget 快照）
    var onDidChange: (() -> Void)?
    init(repo: ReminderRepository, scheduler: NotificationScheduling) {
        self.repo = repo; self.scheduler = scheduler
        // M-06（PRD §4 要求）：时区变更后按库中配置全量重排，避免提醒漂移
        timezoneObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSSystemTimeZoneDidChange, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in await self?.rescheduleAll() } }
    }
    deinit { if let o = timezoneObserver { NotificationCenter.default.removeObserver(o) } }
    func requestPermission() async {
        let ok = (try? await scheduler.requestAuthorization()) ?? false
        permission = ok ? .granted : .denied   // denied → UI 弹 Alert 引导跳系统设置
    }
    /// M-03：提醒配置一律落库（用户数据），送达能力与配置解耦——权限不足时仅不调度
    func save(_ r: Reminder, petName: String) async throws {
        var reminder = r; reminder.petName = petName
        try repo.save(reminder)
        guard permission == .granted else { onDidChange?(); return }
        try await schedule(reminder)
        onDidChange?()
    }
    private func schedule(_ r: Reminder) async throws {
        scheduler.removePending(matchingPrefix: r.id.uuidString)   // 覆盖旧调度
        for (i, t) in ReminderTriggerBuilder.triggers(rule: r.repeatRule,
                                                      hour: r.hour, minute: r.minute).enumerated() {
            let content = ReminderContentBuilder.content(type: r.type, petName: r.petName,
                                                         reminderID: r.id, petID: r.petID)
            try await scheduler.add(UNNotificationRequest(
                identifier: "\(r.id.uuidString)#\(i)", content: content, trigger: t))
        }
        // 提前量：主触发器之外再挂一组前移触发器（identifier 加 adv 段，随前缀一并撤销）
        for (i, t) in ReminderTriggerBuilder.advanceTriggers(rule: r.repeatRule, hour: r.hour,
                                                             minute: r.minute, advance: r.advance).enumerated() {
            let content = ReminderContentBuilder.advanceContent(type: r.type, petName: r.petName,
                                                                advance: r.advance,
                                                                reminderID: r.id, petID: r.petID)
            try await scheduler.add(UNNotificationRequest(
                identifier: "\(r.id.uuidString)#adv#\(i)", content: content, trigger: t))
        }
    }
    /// M-06：时区/日历变更后的全量重排（权限被拒时跳过，权限回补后可手动再触发）
    func rescheduleAll() async {
        guard permission == .granted,
              let all = try? repo.allReminders() else { return }
        for r in all { try? await schedule(r) }
        onDidChange?()
    }
    func removeAll(petID: UUID) throws {
        for r in try repo.reminders(petID: petID) {   // 先撤销 pending 通知
            scheduler.removePending(matchingPrefix: r.id.uuidString)
        }
        try repo.deleteAll(petID: petID)              // 再清库
        onDidChange?()
    }
}
