import SwiftUI
import Combine

/// 历史事实与下一次计划分开展示，完成记录永远不会因为下次日期过去而变成“未完成”。
struct HealthEvent: Identifiable {
    enum Status: String { case done = "已完成", pending = "待进行", overdue = "已逾期" }
    let id: UUID
    let title: String
    let detail: String
    let date: Date
    let status: Status = .done
    let nextDue: Date?
    let nextCompleted: Bool
    let nextPaused: Bool
    let hasNotification: Bool
    func nextStatus(now: Date = Date(), calendar: Calendar = .current) -> Status? {
        guard let nextDue else { return nil }
        if nextCompleted { return .done }
        // 未设置通知钟点的日期按整天判定；明确的提醒则按实际时刻判定。
        return nextDue < (hasNotification ? now : calendar.startOfDay(for: now)) ? .overdue : .pending
    }
    static func build(records: [Record], reminders: [Reminder]) -> [HealthEvent] {
        records.filter { [.vaccine, .deworming, .checkup].contains($0.kind) }
            .sorted { $0.eventDate < $1.eventDate }
            .map { record in
                let reminder = reminders.first { $0.sourceRecordID == record.id }
                let due: Date?
                if let reminder, case .once(let date) = reminder.repeatRule { due = date }
                else { due = record.answers["nextDue"].flatMap(RecordAnswerDate.parse) }
                let completed = reminder.map { reminder in
                    guard let due else { return false }
                    let key = ReminderTaskKey.make(reminderID: reminder.id,
                        day: ReminderTaskKey.day(rule: reminder.repeatRule, due: due), type: reminder.type.rawValue)
                    return records.contains { $0.completionKey == key }
                } ?? false
                let title: String
                switch record.kind {
                case .vaccine: title = record.answers["vaccineName"] ?? "疫苗接种"
                case .deworming: title = "驱虫 · " + (record.answers["drug"] ?? "")
                default: title = "体检"
                }
                let detail = [record.answers["hospital"], record.answers["conclusion"]]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                return .init(id: record.id, title: title, detail: detail, date: record.eventDate,
                    nextDue: due, nextCompleted: completed, nextPaused: reminder?.isEnabled == false,
                    hasNotification: reminder != nil)
            }
    }
}

@MainActor final class HealthTimelineModel: ObservableObject {
    @Published private(set) var events: [HealthEvent] = []
    private var bag = Set<AnyCancellable>()
    private let repo: RecordRepository
    private let reminderRepo: ReminderRepository
    private var records: [Record] = []
    private let petID: UUID
    init(repo: RecordRepository, petID: UUID, reminderRepo: ReminderRepository = CoreDataReminderRepository()) {
        self.repo = repo; self.petID = petID; self.reminderRepo = reminderRepo
        repo.recordsPublisher(petID: petID).receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.records = $0; self?.refresh() }.store(in: &bag)
        NotificationCenter.default.publisher(for: .remindersDidChange).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &bag)
    }
    private func refresh() {
        events = HealthEvent.build(records: records, reminders: (try? reminderRepo.reminders(petID: petID)) ?? [])
    }
}
