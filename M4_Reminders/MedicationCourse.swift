import Foundation
import CoreData

enum MedicationCourseStatus: String, Codable, CaseIterable, Identifiable {
    case active, paused, ended
    var id: String { rawValue }
    var label: String {
        switch self { case .active: return "进行中"; case .paused: return "已暂停"; case .ended: return "已结束" }
    }
}

struct MedicationTime: Codable, Equatable, Identifiable {
    var hour: Int
    var minute: Int
    var reminderID = UUID()
    var id: UUID { reminderID }
    var label: String { String(format: "%02d:%02d", hour, minute) }
    fileprivate var clockKey: Int { hour * 60 + minute }
}

/// 用量是主人填写的安排快照，实际服药仍由每次记录确认。
struct MedicationCourse: Codable, Equatable, Identifiable {
    var id = UUID()
    var petID: UUID
    var drugName: String
    var doseInstructions: String
    var startDate: Date
    var endDate: Date
    var times: [MedicationTime]
    var status: MedicationCourseStatus = .active
    var archivedReminderIDs: [UUID] = []
    var reminderIDs: [UUID] { times.map(\.reminderID) + archivedReminderIDs }
    var validationError: String? {
        guard !drugName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, drugName.count <= 80 else { return "请填写药名（最多80字）" }
        guard !doseInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, doseInstructions.count <= 500 else { return "请填写主人记录的单次用量／说明（最多500字）" }
        guard ReminderRecurrence.isSupportedDate(startDate), ReminderRecurrence.isSupportedDate(endDate) else { return "疗程日期无效" }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: startDate), end = calendar.startOfDay(for: endDate)
        guard let days = calendar.dateComponents([.day], from: start, to: end).day, (0...179).contains(days) else { return "疗程须为1至180个日历日（含首尾）" }
        guard (1...6).contains(times.count), times.allSatisfy({ (0...23).contains($0.hour) && (0...59).contains($0.minute) }),
              Set(times.map(\.clockKey)).count == times.count else { return "每天请选择1至6个不重复的有效时间" }
        guard Set(reminderIDs).count == reminderIDs.count else { return "疗程提醒关联重复" }
        return nil
    }
    func isActive(at date: Date = Date()) -> Bool {
        guard status == .active, validationError == nil, ReminderRecurrence.isSupportedDate(date) else { return false }
        let calendar = Calendar.current, day = calendar.startOfDay(for: date)
        return day >= calendar.startOfDay(for: startDate) && day <= calendar.startOfDay(for: endDate)
    }
    var careCardSummary: String {
        "药名：\(drugName)\n主人填写的单次用量／说明：\(doseInstructions)\n日期：\(startDate.formatted(date: .abbreviated, time: .omitted)) 至 \(endDate.formatted(date: .abbreviated, time: .omitted))（含首尾）\n每日：\(times.sorted { $0.clockKey < $1.clockKey }.map(\.label).joined(separator: "、"))"
    }
}

enum MedicationCourseError: LocalizedError {
    case invalid(String), missing, ended, managedReminder
    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .missing: return "疗程或提醒已变更，请重新打开。"
        case .ended: return "已结束的疗程不能恢复，请新建疗程。"
        case .managedReminder: return "这条提醒由用药疗程管理，请在疗程中修改。"
        }
    }
}

/// Course 和所有关联提醒在同一 context、一次 save 中变更；记录独立保留。
@MainActor final class MedicationCourseStore {
    private let stack: CoreDataStack
    private let care: CareItemStore
    private var context: NSManagedObjectContext { stack.container.viewContext }
    init(stack: CoreDataStack = .shared) { self.stack = stack; care = CareItemStore(stack: stack) }

    func courses(petID: UUID) throws -> [MedicationCourse] {
        let values = try care.items(MedicationCourse.self, category: .medicationCourse, petID: petID)
        if let message = values.compactMap(\.validationError).first { throw MedicationCourseError.invalid(message) }
        return values
    }
    func course(reminderID: UUID, petID: UUID) throws -> MedicationCourse? {
        try courses(petID: petID).first { $0.reminderIDs.contains(reminderID) }
    }
    private func require(courseID: UUID, petID: UUID) throws -> MedicationCourse {
        guard let value = try courses(petID: petID).first(where: { $0.id == courseID }) else { throw MedicationCourseError.missing }
        return value
    }
    private func reminderEntities(_ ids: [UUID], petID: UUID) throws -> [CDReminder] {
        guard !ids.isEmpty else { return [] }
        let request = CDReminder.fetchRequest(); request.predicate = NSPredicate(format: "id IN %@", ids)
        let rows = try context.fetch(request)
        guard rows.count == ids.count, rows.allSatisfy({ $0.petID == petID && $0.type == ReminderType.medication.rawValue && $0.sourceRecordID == nil }) else { throw MedicationCourseError.missing }
        return rows
    }
    @discardableResult func save(_ draft: MedicationCourse, petName: String) throws -> MedicationCourse {
        do {
            if let message = draft.validationError { throw MedicationCourseError.invalid(message) }
            let previous = try courses(petID: draft.petID).first { $0.id == draft.id }
            if previous?.status == .ended && draft.status != .ended { throw MedicationCourseError.ended }
            var updated = draft
            let calendar = Calendar.current
            updated.startDate = calendar.startOfDay(for: draft.startDate)
            updated.endDate = calendar.startOfDay(for: draft.endDate)
            let oldRows = try reminderEntities(previous?.reminderIDs ?? [], petID: draft.petID)
            let oldByID = Dictionary(uniqueKeysWithValues: oldRows.compactMap { row in row.id.map { ($0, row) } })
            // 时刻是身份匹配依据，不能把旧时刻的 ID 搬给新时刻。
            updated.times = draft.times.sorted { $0.clockKey < $1.clockKey }.map { time in
                var slot = time
                slot.reminderID = previous?.times.first { $0.clockKey == time.clockKey }?.reminderID ?? UUID()
                return slot
            }
            let currentIDs = Set(updated.times.map(\.reminderID))
            updated.archivedReminderIDs = (previous?.reminderIDs ?? []).filter { !currentIDs.contains($0) }
            for row in oldRows where !currentIDs.contains(row.id!) { row.isEnabled = false }
            let rule = RepeatRule.dailyWindow(start: updated.startDate, end: updated.endDate)
            for time in updated.times {
                let existing = oldByID[time.reminderID]
                let old = existing.map(Reminder.init)
                let changed = old?.repeatRule != rule || old?.isEnabled != (updated.status == .active)
                let reminder = Reminder(id: time.reminderID, petID: updated.petID, petName: petName, type: .medication,
                    hour: time.hour, minute: time.minute, repeatRule: rule, isEnabled: updated.status == .active,
                    trackingSince: changed ? Date() : old?.trackingSince ?? Date())
                reminder.apply(to: existing ?? stack.insert(CDReminder.self))
            }
            try care.upsert(updated, id: updated.id, petID: updated.petID, category: .medicationCourse, commit: false)
            try stack.save(); notify()
            return updated
        } catch { context.rollback(); throw error }
    }
    @discardableResult func setStatus(_ status: MedicationCourseStatus, courseID: UUID, petID: UUID) throws -> MedicationCourse {
        var value = try require(courseID: courseID, petID: petID)
        if value.status == .ended && status != .ended { throw MedicationCourseError.ended }
        value.status = status
        let rows = try reminderEntities(value.reminderIDs, petID: petID)
        return try save(value, petName: rows.first?.petName ?? "")
    }
    func delete(courseID: UUID, petID: UUID) throws {
        do {
            let value = try require(courseID: courseID, petID: petID)
            try reminderEntities(value.reminderIDs, petID: petID).forEach { $0.isEnabled = false }
            try care.delete(id: courseID, commit: false)
            try stack.save(); notify()
        } catch { context.rollback(); throw error }
    }
    func history(for course: MedicationCourse) throws -> [Record] {
        let request = CDRecord.fetchRequest()
        request.predicate = NSPredicate(format: "petID == %@ AND completedReminderID IN %@", course.petID as CVarArg, course.reminderIDs)
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        return try context.fetch(request).map(Record.init)
    }
    @discardableResult func skip(task: ReminderTask, courseID: UUID) throws -> Record {
        let course = try require(courseID: courseID, petID: task.reminder.petID)
        guard course.status == .active, course.times.contains(where: { $0.reminderID == task.reminder.id }), task.record == nil else { throw MedicationCourseError.missing }
        let record = Record(petID: course.petID, kind: .medication,
            answers: ["drug": course.drugName + "（跳过，未服药）", "dose": "未服药（已跳过）", "administrationStatus": "skipped"],
            note: "主人将本次计划标记为跳过；未记录实际服药。", occurredAt: Date(),
            completedReminderID: task.reminder.id, completedDueAt: task.due, completedDay: task.day)
        try CoreDataRecordRepository(stack: stack).create(record)
        NotificationCenter.default.post(name: .remindersDidChange, object: nil)
        return record
    }
    private func notify() {
        CareItemStore.notify()
        NotificationCenter.default.post(name: .remindersDidChange, object: nil)
        NotificationCenter.default.post(name: .recordsDidChange, object: nil)
    }
}
