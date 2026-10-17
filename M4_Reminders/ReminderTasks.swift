import Foundation
import CoreData
import SwiftUI

/// 一条提醒每天最多发生一次；按当地日历日期标识，跨时区后同一天不重新打卡。
struct ReminderTask: Identifiable {
    let reminder: Reminder
    let due: Date
    let day: String
    var record: Record?
    var id: String { ReminderTaskKey.make(reminderID: reminder.id, day: day, type: reminder.type.rawValue) }
    enum Status: String { case pending = "待完成", overdue = "逾期", done = "已完成", skipped = "已跳过（未服药）" }
    func status(now: Date) -> Status {
        if let record { return record.answers["administrationStatus"] == "skipped" ? .skipped : .done }
        return due <= now ? .overdue : .pending
    }
}

extension Record {
    var completionKey: String? {
        guard let id = completedReminderID, let day = completedDay else { return nil }
        return ReminderTaskKey.make(reminderID: id, day: day, type: kind.rawValue)
    }
}

extension ReminderType {
    var recordKind: RecordKind {
        switch self {
        case .feeding: return .feeding
        case .vaccine: return .vaccine
        case .deworming: return .deworming
        case .checkup: return .checkup
        case .medication: return .medication
        }
    }
}

enum ReminderTaskBuilder {
    /// 保留从启用日起漏做的任务；旧版本的重复提醒从升级当天开始，不捏造过去的完成状态。
    static func tasks(reminders: [Reminder], records: [Record], petID: UUID,
                      now: Date = Date(), calendar: Calendar = .current) -> [ReminderTask] {
        let startOfToday = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) else { return [] }
        let completions = Dictionary(records.filter { $0.petID == petID }.compactMap { record in
            record.completionKey.map { ($0, record) }
        }, uniquingKeysWith: { first, _ in first })
        var tasks: [ReminderTask] = []
        for reminder in reminders where reminder.petID == petID && reminder.isEnabled {
            let start = calendar.startOfDay(for: max(reminder.trackingSince ?? now, Date(timeIntervalSince1970: 0)))
            let dates: [Date]
            if case .once(let due) = reminder.repeatRule {
                dates = ReminderRecurrence.isSupportedDate(due) && due < tomorrow ? [due] : []
            } else {
                dates = ReminderRecurrence.dates(rule: reminder.repeatRule, hour: reminder.hour, minute: reminder.minute,
                    after: start.addingTimeInterval(-1), through: tomorrow.addingTimeInterval(-1), calendar: calendar)
            }
            for due in dates {
                let day = ReminderTaskKey.day(rule: reminder.repeatRule, due: due, calendar: calendar)
                let record = completions[ReminderTaskKey.make(reminderID: reminder.id, day: day, type: reminder.type.rawValue)]
                // 历史已完成任务留在记录页；今天补做的逾期任务仍在今日显示。
                if let record, due < startOfToday && record.createdAt < startOfToday { continue }
                tasks.append(.init(reminder: reminder, due: due, day: day, record: record))
            }
        }
        return tasks.sorted {
            if ($0.record == nil) != ($1.record == nil) { return $0.record == nil }
            return $0.due == $1.due ? $0.id < $1.id : $0.due < $1.due
        }
    }
}

/// 可轻量迁移的可选字段由这里补齐；与旧体重迁移使用独立的数据库标记。
enum ReminderTaskMigration {
    static let metadataKey = "PetPal.reminderTaskMigrationVersion"
    static func runIfNeeded(in context: NSManagedObjectContext, now: Date = Date(), save: () throws -> Void) throws {
        guard let coordinator = context.persistentStoreCoordinator,
              let store = coordinator.persistentStores.first else { return }
        var metadata = coordinator.metadata(for: store)
        guard (metadata[metadataKey] as? Int ?? 0) < 1 else { return }
        let query = CDReminder.fetchRequest()
        query.predicate = NSPredicate(format: "trackingSince == nil")
        for reminder in try context.fetch(query) { reminder.trackingSince = now }
        if context.hasChanges { try save() }
        metadata[metadataKey] = 1
        coordinator.setMetadata(metadata, for: store)
    }
}

/// 首页和提醒管理页共用任务列表；保存表单和完成状态在同一个数据库事务中提交。
@MainActor struct ReminderTasksSection: View {
    let pet: Pet
    @ObservedObject var service: ReminderService
    let onSelect: (ReminderTask) -> Void
    var body: some View {
        Section("今日与逾期待办") {
            TimelineView(.periodic(from: Date(), by: 60)) { context in
                let tasks = ReminderTaskBuilder.tasks(reminders: service.configurations,
                    records: service.completedRecords, petID: pet.id, now: context.date)
                if tasks.isEmpty {
                    Text("暂无待办，记录页可回看历史完成记录").foregroundStyle(.secondary)
                } else {
                    ForEach(tasks) { task in
                        Button { onSelect(task) } label: {
                            HStack {
                                Image(systemName: task.record == nil ? "circle" : "checkmark.circle.fill")
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(taskTitle(task)).font(.headline)
                                    Text(task.due.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(task.status(now: context.date).rawValue)
                                    .foregroundStyle(task.record != nil ? .green : (task.due <= context.date ? .red : .secondary))
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("tasks.row.\(task.id)")
                        .accessibilityHint(task.record == nil ? "填写并保存记录后完成本次任务" : "查看完成记录")
                    }
                }
            }
            if let error = service.taskError { Text(error).foregroundStyle(.red) }
            Text("点待办填写记录，保存后完成本次任务；删除完成记录会恢复待办。暂停提醒会隐藏对应待办。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
    private func taskTitle(_ task: ReminderTask) -> String {
        if task.reminder.type == .medication,
           let course = try? MedicationCourseStore().course(reminderID: task.reminder.id, petID: pet.id) {
            return "服药 · " + course.drugName
        }
        return task.reminder.type.rawValue
    }
}

/// 弹窗由列表页面承载；Section 只提供行，避免 List 的 Section 容器吞掉展示请求。
@MainActor struct ReminderTaskSheet: View {
    let task: ReminderTask
    @ObservedObject var service: ReminderService = .shared
    var body: some View {
        if let record = task.record { RecordDetailView(record: record) }
        else if let course = try? MedicationCourseStore().course(reminderID: task.reminder.id, petID: task.reminder.petID) {
            MedicationCourseTaskView(task: task, course: course, service: service)
        }
        else { NavigationStack { PresetRecordFormView(completing: task) } }
    }
}
