import Foundation
import CoreData
import UserNotifications

// MARK: - 模型
enum ReminderType: String, CaseIterable, Identifiable {
    case feeding = "喂食", vaccine = "疫苗", deworming = "驱虫", checkup = "体检", medication = "服药"
    var id: String { rawValue }
    var action: String { self == .vaccine ? "接种疫苗" : rawValue }
    /// 列表/表单图标（与 M2 记录类型同一套语义；widget 侧因独立编译另有一份字符串映射）
    var symbolName: String {
        switch self {
        case .feeding: return "fork.knife"
        case .vaccine: return "syringe.fill"
        case .deworming: return "pill.fill"
        case .checkup: return "stethoscope"
        case .medication: return "pills.fill"
        }
    }
}


struct Reminder: Identifiable, Equatable {
    var id = UUID()
    var petID: UUID
    var petName = ""                    // 随提醒落库，时区重建/重排时无需回查 M1
    var type: ReminderType
    var hour: Int                       // 0-23
    var minute: Int                     // 0-59
    var repeatRule: RepeatRule = .daily
    var advance: AdvanceOption = .none
    var isEnabled = true
    var sourceRecordID: UUID?
}

// MARK: - 提前量（PRD §4：5分钟/15分钟/30分钟/1小时/1天/3天）

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
    static func concrete(_ date: Date, calendar: Calendar) -> UNCalendarNotificationTrigger {
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        components.calendar = calendar; components.timeZone = calendar.timeZone
        return .init(dateMatching: components, repeats: false)
    }
    static func triggers(rule: RepeatRule, hour: Int, minute: Int,
                         now: Date = Date(), calendar: Calendar = .current) -> [UNCalendarNotificationTrigger] {
        switch rule {
        case .daily: return [.init(dateMatching: .init(hour: hour, minute: minute), repeats: true)]
        case .weekly(let days): return days.sorted().map { .init(dateMatching: .init(hour: hour, minute: minute, weekday: $0), repeats: true) }
        default:
            let end = calendar.date(byAdding: .year, value: 8, to: now) ?? now
            return ReminderRecurrence.dates(rule: rule, hour: hour, minute: minute, after: now, through: end, calendar: calendar)
                .prefix(1).map { concrete($0, calendar: calendar) }
        }
    }
    static func advanceTriggers(rule: RepeatRule, hour: Int, minute: Int, advance: AdvanceOption,
                                calendar: Calendar = .current, now: Date = Date()) -> [UNCalendarNotificationTrigger] {
        guard advance != .none else { return [] }
        switch rule {
        case .daily, .weekly:
            // 在固定无夏令时的日历里只计算星期和钟点，系统按当地时间重复。
            var arithmetic = Calendar(identifier: .gregorian); arithmetic.timeZone = TimeZone(secondsFromGMT: 0)!
            let days: [Int]
            if case .weekly(let selected) = rule { days = selected.sorted() } else { days = [1] }
            return days.compactMap { day in
                guard let base = arithmetic.date(from: DateComponents(year: 2023, month: 1, day: day, hour: hour, minute: minute)) else { return nil }
                let date = advance.fireDate(for: base, calendar: arithmetic)
                var c = arithmetic.dateComponents([.hour, .minute], from: date)
                if case .weekly = rule { c.weekday = arithmetic.component(.weekday, from: date) }
                return .init(dateMatching: c, repeats: true)
            }
        default:
            let end = calendar.date(byAdding: .year, value: 8, to: now) ?? now
            return ReminderRecurrence.dates(rule: rule, hour: hour, minute: minute, after: now, through: end, calendar: calendar)
                .map { advance.fireDate(for: $0, calendar: calendar) }.filter { $0 > now }.prefix(1)
                .map { concrete($0, calendar: calendar) }
        }
    }
}

struct ReminderSchedulePlan {
    var requests: [UNNotificationRequest] = []
    var scheduledThrough: [UUID: Date] = [:]
    var incomplete: Set<UUID> = []
    // 保守地把整个 App 的待发送提醒限制为 64 条，月/年窗口随可用名额滚动。
    static func build(_ reminders: [Reminder], now: Date = Date(), calendar: Calendar = .current,
                      limit: Int = 64) -> Self {
        var plan = Self()
        var finite: [(reminder: Reminder, due: Date, requests: [UNNotificationRequest])] = []
        func request(_ r: Reminder, trigger: UNCalendarNotificationTrigger, suffix: String, early: Bool) -> UNNotificationRequest {
            let content = early
                ? ReminderContentBuilder.advanceContent(type: r.type, petName: r.petName, advance: r.advance, reminderID: r.id, petID: r.petID)
                : ReminderContentBuilder.content(type: r.type, petName: r.petName, reminderID: r.id, petID: r.petID)
            return .init(identifier: "\(r.id)#\(early ? "adv#" : "")\(suffix)", content: content, trigger: trigger)
        }
        for r in reminders.filter({ $0.isEnabled }).sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            guard ReminderRecurrence.validationError(rule: r.repeatRule, hour: r.hour, minute: r.minute, advance: r.advance) == nil else {
                plan.incomplete.insert(r.id); continue
            }
            switch r.repeatRule {
            case .daily, .weekly:
                let main = ReminderTriggerBuilder.triggers(rule: r.repeatRule, hour: r.hour, minute: r.minute)
                let advance = ReminderTriggerBuilder.advanceTriggers(rule: r.repeatRule, hour: r.hour, minute: r.minute, advance: r.advance)
                let group = main.enumerated().map { request(r, trigger: $0.element, suffix: String($0.offset), early: false) }
                    + advance.enumerated().map { request(r, trigger: $0.element, suffix: String($0.offset), early: true) }
                if plan.requests.count + group.count <= limit { plan.requests += group }
                else { plan.incomplete.insert(r.id) }
            default:
                let end: Date
                if case .once(let date) = r.repeatRule { end = date } else { end = calendar.date(byAdding: .year, value: 8, to: now) ?? now }
                for due in ReminderRecurrence.dates(rule: r.repeatRule, hour: r.hour, minute: r.minute, after: now, through: end, calendar: calendar) {
                    let suffix = String(Int(due.timeIntervalSince1970))
                    var group = [request(r, trigger: ReminderTriggerBuilder.concrete(due, calendar: calendar), suffix: suffix, early: false)]
                    let early = r.advance.fireDate(for: due, calendar: calendar)
                    if r.advance != .none, early > now { group.append(request(r, trigger: ReminderTriggerBuilder.concrete(early, calendar: calendar), suffix: suffix, early: true)) }
                    finite.append((r, due, group))
                }
            }
        }
        // 每次实际发生的主提醒和提前提醒一起分配名额，不留下只有提前提醒的半组。
        for item in finite.sorted(by: { $0.due == $1.due ? $0.reminder.id.uuidString < $1.reminder.id.uuidString : $0.due < $1.due }) {
            if plan.incomplete.contains(item.reminder.id) { continue }
            if plan.requests.count + item.requests.count <= limit {
                plan.requests += item.requests; plan.scheduledThrough[item.reminder.id] = item.due
            } else { plan.incomplete.insert(item.reminder.id) }
        }
        return plan
    }
}

// MARK: - 调度边界（UNUserNotificationCenter 协议化，测试用 Mock 替换）
protocol NotificationScheduling: AnyObject {
    func requestAuthorization() async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func authorizationStatus() async -> UNAuthorizationStatus
    func removePending(matchingPrefix prefix: String) async
}

// MARK: - 存储边界（CDReminder：id/petID UUID、type/repeatRule/petName String、hour/minute Int16）
protocol ReminderRepository: AnyObject {
    func reminders(petID: UUID) throws -> [Reminder]
    func allReminders() throws -> [Reminder]   // M-06：时区/日历变更后全量重排用
    func save(_ reminder: Reminder) throws
    func delete(id: UUID) throws               // 单条删除（列表页滑动删除）
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
        try stack.save()
    }
    func deleteAll(petID: UUID) throws {
        let r = CDReminder.fetchRequest(); r.predicate = NSPredicate(format: "petID == %@", petID as CVarArg)
        try ctx.fetch(r).forEach(ctx.delete); try stack.save()
    }
    func delete(id: UUID) throws {
        let r = CDReminder.fetchRequest(); r.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        let items = try ctx.fetch(r)
        let sourceIDs = items.compactMap(\.sourceRecordID)
        let records = CDRecord.fetchRequest(); records.predicate = NSPredicate(format: "id IN %@", sourceIDs)
        let sources = try ctx.fetch(records)
        items.forEach(ctx.delete); sources.forEach { $0.wantsNextReminder = false }
        try stack.save()
        NotificationCenter.default.post(name: .recordsDidChange, object: nil)
    }
}

extension Reminder {
    init(_ e: CDReminder) {
        let rule = e.repeatRule
            .flatMap { try? JSONDecoder().decode(RepeatRule.self, from: Data($0.utf8)) } ?? .daily
        self.init(id: e.id ?? UUID(), petID: e.petID ?? UUID(), petName: e.petName ?? "",
                  type: ReminderType(rawValue: e.type ?? "") ?? .feeding,
                  hour: Int(e.hour), minute: Int(e.minute), repeatRule: rule,
                  advance: AdvanceOption(rawValue: e.advance ?? "") ?? .none,
                  isEnabled: e.isEnabled, sourceRecordID: e.sourceRecordID)
    }
    func apply(to e: CDReminder) {
        e.id = id; e.petID = petID; e.petName = petName; e.type = type.rawValue
        e.hour = Int16(hour); e.minute = Int16(minute)
        e.repeatRule = String(data: (try? JSONEncoder().encode(repeatRule)) ?? Data(), encoding: .utf8)
        e.advance = advance.rawValue; e.isEnabled = isEnabled; e.sourceRecordID = sourceRecordID
    }
}

// MARK: - 编排层（权限 + 存库 + 调度；M1 删除宠物时调用 removeAll）
extension Notification.Name { static let remindersDidChange = Notification.Name("PetPal.remindersDidChange") }

@MainActor final class ReminderService: ObservableObject {
    static let shared = ReminderService(repo: CoreDataReminderRepository(), scheduler: UNNotificationScheduler())
    enum PermissionState { case unknown, granted, denied }
    @Published private(set) var permission: PermissionState = .unknown
    @Published private(set) var configurations: [Reminder] = []
    @Published private(set) var scheduleError: String?
    @Published private(set) var scheduledThrough: [UUID: Date] = [:]
    @Published private(set) var incomplete: Set<UUID> = []
    private let repo: ReminderRepository
    private let scheduler: NotificationScheduling
    private var observers: [NSObjectProtocol] = []
    private var tail: Task<Void, Never>?
    var onDidChange: (() -> Void)?
    init(repo: ReminderRepository, scheduler: NotificationScheduling) {
        self.repo = repo; self.scheduler = scheduler
        for name in [Notification.Name.NSSystemTimeZoneDidChange, .remindersDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.rescheduleAll() }
            })
        }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    private func serial<T: Sendable>(_ work: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = tail
        let job = Task { @MainActor in await previous?.value; return try await work() }
        tail = Task { _ = try? await job.value }
        return try await job.value
    }
    private func refreshPermission() async {
        switch await scheduler.authorizationStatus() {
        case .authorized, .provisional, .ephemeral: permission = .granted
        case .denied: permission = .denied
        default: permission = .unknown
        }
    }
    func requestPermission() async {
        await refreshPermission()
        if permission == .unknown {
            _ = try? await scheduler.requestAuthorization()
            await refreshPermission()
        }
    }
    /// 返回的是配置保存后的送达提示；数据库写入失败则抛错，表单保留草稿。
    @discardableResult func save(_ r: Reminder, petName: String) async throws -> String? {
        try await serial { [self] in
            if let error = ReminderRecurrence.validationError(rule: r.repeatRule, hour: r.hour, minute: r.minute, advance: r.advance) {
                throw NSError(domain: "PetPal.Reminder", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
            }
            var reminder = r; reminder.petName = petName
            try repo.save(reminder)
            await rebuild()
            if permission != .granted { return "提醒已保存。通知权限未开启，请到系统设置允许通知。" }
            return scheduleError.map { "提醒已保存。" + $0 }
        }
    }
    private func rebuild() async {
        await refreshPermission()
        scheduleError = nil; scheduledThrough = [:]; incomplete = []
        do {
            let all = try repo.allReminders(); configurations = all
            // 先等候旧请求查询和撤销完成，再添加；所有重排共用同一条串行队列。
            await scheduler.removePending(matchingPrefix: "")
            guard permission == .granted else { onDidChange?(); return }
            let plan = ReminderSchedulePlan.build(all)
            for request in plan.requests { try await scheduler.add(request) }
            scheduledThrough = plan.scheduledThrough; incomplete = plan.incomplete
            let unarranged = all.contains { $0.isEnabled && plan.incomplete.contains($0.id) && plan.scheduledThrough[$0.id] == nil }
            if unarranged { scheduleError = "部分提醒尚未排入通知，待发送名额已满或配置无效。请减少提醒后重试。" }
        } catch {
            scheduleError = "通知安排失败：" + error.localizedDescription + "。请在提醒列表重试。"
        }
        onDidChange?()
    }
    func rescheduleAll() async {
        _ = try? await serial { [self] in await rebuild() }
    }
    func removeAll(petID: UUID) async throws {
        try await serial { [self] in try repo.deleteAll(petID: petID); await rebuild() }
    }
    func reminders(petID: UUID) -> [Reminder] { (try? repo.reminders(petID: petID)) ?? [] }
    func remove(_ reminder: Reminder) async throws {
        try await serial { [self] in try repo.delete(id: reminder.id); await rebuild() }
    }
}
