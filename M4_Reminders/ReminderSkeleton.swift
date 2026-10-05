import Foundation
import CoreData
import UserNotifications
import Combine

// MARK: - 模型
enum ReminderType: String, CaseIterable, Identifiable {
    case feeding = "喂食", vaccine = "疫苗", deworming = "驱虫", checkup = "体检", medication = "服药"
    var id: String { rawValue }
    var action: String { self == .vaccine ? "接种疫苗" : rawValue }
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
    func shifting(_ date: Date, calendar: Calendar) -> Date? {
        switch self {
        case .d1: return calendar.date(byAdding: .day, value: -1, to: date)
        case .d3: return calendar.date(byAdding: .day, value: -3, to: date)
        default: return date.addingTimeInterval(-seconds)
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
        rule.matchingComponents(hour: hour, minute: minute)
            .map { .init(dateMatching: $0, repeats: true) }
    }
    /// 日/周可重复；月/年按实际日期预排 12 次，回前台/时区变更时补齐滚动窗口。
    /// 固定重复的 day/month 无法表达不同月长及闰年的提前日期。
    static func advanceTriggers(rule: RepeatRule, hour: Int, minute: Int,
                                advance: AdvanceOption,
                                now: Date = Date(), occurrenceCount: Int = 12,
                                calendar: Calendar = .current) -> [UNCalendarNotificationTrigger] {
        guard advance != .none, rule.isValid,
              (0...23).contains(hour), (0...59).contains(minute) else { return [] }
        func shifted(_ matching: DateComponents, extract: [Calendar.Component]) -> DateComponents? {
            guard let next = calendar.nextDate(after: now, matching: matching,
                                               matchingPolicy: .strict),
                  let shiftedDate = advance.shifting(next, calendar: calendar) else { return nil }
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
        case .monthly, .yearly:
            return ReminderOccurrenceBuilder.dates(rule: rule, hour: hour, minute: minute,
                                                   after: now, count: occurrenceCount + 1,
                                                   calendar: calendar)
                .compactMap { advance.shifting($0, calendar: calendar) }
                .filter { $0 > now }
                .prefix(max(0, occurrenceCount))
                .map { date in
                    var d = calendar.dateComponents([.era, .year, .month, .day, .hour, .minute, .second], from: date)
                    d.calendar = calendar; d.timeZone = calendar.timeZone
                    return .init(dateMatching: d, repeats: false)
                }
        }
    }
}

// MARK: - 调度边界（UNUserNotificationCenter 协议化，测试用 Mock 替换）
@MainActor protocol NotificationScheduling: AnyObject {
    func requestAuthorization() async throws -> Bool
    func authorizationStatus() async -> UNAuthorizationStatus
    func pendingRequests() async -> [UNNotificationRequest]
    func add(_ request: UNNotificationRequest) async throws
    func removePending(matchingPrefix prefix: String) async
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
        try stack.transaction {
            reminder.apply(to: try ctx.fetch(r).first ?? stack.insert(CDReminder.self))
        }
    }
    func deleteAll(petID: UUID) throws {
        let r = CDReminder.fetchRequest(); r.predicate = NSPredicate(format: "petID == %@", petID as CVarArg)
        try stack.transaction { try ctx.fetch(r).forEach(ctx.delete) }
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

enum ReminderServiceError: LocalizedError {
    case invalidConfiguration, capacityExceeded, schedulingFailed
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "请选择有效的日期、时间和至少一个重复星期。"
        case .capacityExceeded: return "提醒已保存，但通知数量已达系统上限，无法安排全部通知。请减少提醒后重试。"
        case .schedulingFailed: return "提醒已保存，但通知安排失败。请重试；回到 App 时也会自动补排。"
        }
    }
}

// MARK: - 编排层（异步操作串行化，配置与送达能力分离）
@MainActor final class ReminderService: ObservableObject {
    enum PermissionState { case unknown, granted, denied }
    @Published private(set) var permission: PermissionState = .unknown
    @Published var errorMessage: String?
    private let repo: ReminderRepository
    private let scheduler: NotificationScheduling
    private let now: () -> Date
    private let calendar: () -> Calendar
    private var operationTail: Task<Void, Error>?
    private var timezoneObserver: NSObjectProtocol?
    /// L-01：提醒数据变更钩子（WidgetSnapshotSyncer 注入，重建 widget 快照）
    var onDidChange: (() -> Void)?
    init(repo: ReminderRepository, scheduler: NotificationScheduling,
         now: @escaping () -> Date = Date.init,
         calendar: @escaping () -> Calendar = { .current }) {
        self.repo = repo; self.scheduler = scheduler
        self.now = now; self.calendar = calendar
        // M-06（PRD §4 要求）：时区变更后按库中配置全量重排，避免提醒漂移
        timezoneObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSSystemTimeZoneDidChange, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in await self?.rescheduleAll() } }
    }
    deinit { if let o = timezoneObserver { NotificationCenter.default.removeObserver(o) } }
    func requestPermission() async throws {
        let status = await scheduler.authorizationStatus()
        if status == .notDetermined {
            permission = try await scheduler.requestAuthorization() ? .granted : .denied
        } else {
            applyPermission(status)
        }
    }
    private func applyPermission(_ status: UNAuthorizationStatus) {
        permission = [.authorized, .provisional, .ephemeral].contains(status) ? .granted : .denied
    }
    private func enqueue(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        let previous = operationTail
        let task = Task { @MainActor in
            _ = try? await previous?.value
            try await operation()
        }
        operationTail = task
        try await task.value
    }
    /// M-03：提醒配置一律落库（用户数据），送达能力与配置解耦——权限不足时仅不调度
    func save(_ r: Reminder, petName: String) async throws {
        var reminder = r; reminder.petName = petName
        guard reminder.repeatRule.isValid, (0...23).contains(reminder.hour),
              (0...59).contains(reminder.minute) else { throw ReminderServiceError.invalidConfiguration }
        let saved = reminder
        try await enqueue { [self] in
            applyPermission(await scheduler.authorizationStatus())
            try repo.save(saved)
            // 即使调度失败，数据库已经保存，应更新快照而不是让它保持旧状态。
            defer { onDidChange?() }
            guard permission == .granted else { return }
            try await schedule(saved)
        }
    }
    private func schedule(_ r: Reminder) async throws {
        var requests: [UNNotificationRequest] = []
        for (i, t) in ReminderTriggerBuilder.triggers(rule: r.repeatRule,
                                                      hour: r.hour, minute: r.minute).enumerated() {
            let content = ReminderContentBuilder.content(type: r.type, petName: r.petName,
                                                         reminderID: r.id, petID: r.petID)
            requests.append(UNNotificationRequest(
                identifier: "\(r.id.uuidString)#\(i)", content: content, trigger: t))
        }
        // 提前量：主触发器之外再挂一组前移触发器（identifier 加 adv 段，随前缀一并撤销）
        for (i, t) in ReminderTriggerBuilder.advanceTriggers(rule: r.repeatRule, hour: r.hour,
                                                             minute: r.minute, advance: r.advance,
                                                             now: now(), calendar: calendar()).enumerated() {
            let content = ReminderContentBuilder.advanceContent(type: r.type, petName: r.petName,
                                                                advance: r.advance,
                                                                reminderID: r.id, petID: r.petID)
            requests.append(UNNotificationRequest(
                identifier: "\(r.id.uuidString)#adv#\(i)", content: content, trigger: t))
        }
        let prefix = r.id.uuidString + "#"
        let pending = await scheduler.pendingRequests()
        let previous = pending.filter { $0.identifier.hasPrefix(prefix) }
        guard pending.count - previous.count + requests.count <= 64 else {
            throw ReminderServiceError.capacityExceeded
        }
        // 必须等待查询/撤销结束，再新增相同 id 的请求；串行队列还防止重排与保存互相覆盖。
        await scheduler.removePending(matchingPrefix: prefix)
        do {
            for request in requests { try await scheduler.add(request) }
        } catch {
            await scheduler.removePending(matchingPrefix: prefix)
            for request in previous { try? await scheduler.add(request) }
            throw ReminderServiceError.schedulingFailed
        }
    }
    /// M-06：时区/日历变更后的全量重排（权限被拒时跳过，权限回补后可手动再触发）
    func rescheduleAll() async {
        do {
            try await enqueue { [self] in
                applyPermission(await scheduler.authorizationStatus())
                guard permission == .granted else { return }
                let all = try repo.allReminders()
                defer { onDidChange?() }
                var failure: Error?
                for r in all {
                    do { try await schedule(r) } catch { failure = failure ?? error }
                }
                if let failure { throw failure }
            }
            errorMessage = nil
        } catch {
            errorMessage = "部分提醒未能安排，请重试。\(error.localizedDescription)"
        }
    }
    func reminderIDs(petID: UUID) throws -> [UUID] {
        try repo.reminders(petID: petID).map(\.id)
    }
    func cancel(reminderIDs: [UUID]) async {
        try? await enqueue { [self] in
            for id in reminderIDs { await scheduler.removePending(matchingPrefix: id.uuidString + "#") }
            onDidChange?()
        }
    }
    func removeAll(petID: UUID) async throws {
        try await enqueue { [self] in
            let ids = try reminderIDs(petID: petID)
            try repo.deleteAll(petID: petID)
            for id in ids { await scheduler.removePending(matchingPrefix: id.uuidString + "#") }
            onDidChange?()
        }
    }
}
