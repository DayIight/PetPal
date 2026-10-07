import SwiftUI

struct ReminderFormView: View {
    let pet: Pet
    @ObservedObject var service: ReminderService
    private let original: Reminder?
    @State private var reminderID: UUID
    @State private var type: ReminderType
    @State private var time: Date
    @State private var repeatMode: RepeatMode
    @State private var weekdays: Set<Int>
    @State private var monthDay: Int
    @State private var yearMonth: Int
    @State private var yearDay: Int
    @State private var advance: AdvanceOption
    @State private var enabled: Bool
    @State private var busy = false
    @State private var error: String?
    @State private var savedNotice: String?
    @Environment(\.dismiss) private var dismiss

    private enum RepeatMode: String, CaseIterable, Identifiable {
        case once = "仅一次", daily = "每日", weekly = "每周", monthly = "每月", yearly = "每年"
        var id: String { rawValue }
    }
    init(pet: Pet, service: ReminderService, editing: Reminder? = nil) {
        self.pet = pet; self.service = service; original = editing
        let r = editing ?? Reminder(petID: pet.id, type: .feeding, hour: 8, minute: 0)
        _reminderID = State(initialValue: r.id); _type = State(initialValue: r.type)
        _time = State(initialValue: Calendar.current.date(bySettingHour: r.hour, minute: r.minute, second: 0, of: Date()) ?? Date())
        _weekdays = State(initialValue: [2]); _monthDay = State(initialValue: 1)
        _yearMonth = State(initialValue: 1); _yearDay = State(initialValue: 1)
        _advance = State(initialValue: r.advance); _enabled = State(initialValue: r.isEnabled)
        switch r.repeatRule {
        case .daily: _repeatMode = State(initialValue: .daily)
        case .weekly(let days): _repeatMode = State(initialValue: .weekly); _weekdays = State(initialValue: days)
        case .monthly(let day): _repeatMode = State(initialValue: .monthly); _monthDay = State(initialValue: day)
        case .yearly(let month, let day): _repeatMode = State(initialValue: .yearly); _yearMonth = State(initialValue: month); _yearDay = State(initialValue: day)
        case .once(let date): _repeatMode = State(initialValue: .once); _time = State(initialValue: date)
        }
    }
    private let weekdayChoices = [("周一", 2), ("周二", 3), ("周三", 4), ("周四", 5), ("周五", 6), ("周六", 7), ("周日", 1)]
    private var advanceChoices: [AdvanceOption] { repeatMode == .daily ? [.none, .m5, .m15, .m30, .h1] : AdvanceOption.allCases }
    var body: some View {
        NavigationStack {
            Form {
                if original?.sourceRecordID != nil {
                    Text("日期和类型由来源记录管理，请在记录详情修改。这里可调整提前提醒或暂停。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Picker("提醒类型", selection: $type) { ForEach(ReminderType.allCases) { Text($0.rawValue).tag($0) } }
                    .disabled(original?.sourceRecordID != nil)
                if ReminderRecurrence.isSupportedDate(time) {
                    DatePicker("提醒时间", selection: $time, in: Date.distantPast...Date.distantFuture,
                               displayedComponents: repeatMode == .once ? [.date, .hourAndMinute] : [.hourAndMinute])
                        .disabled(original?.sourceRecordID != nil)
                } else {
                    Text("这条提醒的日期无效。可返回列表暂停或删除，并重新创建提醒。")
                        .foregroundStyle(.red).accessibilityIdentifier("reminder.invalidDate")
                }
                Picker("重复", selection: $repeatMode) { ForEach(RepeatMode.allCases) { Text($0.rawValue).tag($0) } }
                    .accessibilityIdentifier("reminder.repeat")
                    .disabled(original?.sourceRecordID != nil)
                switch repeatMode {
                case .once, .daily: EmptyView()
                case .weekly:
                    ForEach(weekdayChoices, id: \.1) { choice in
                        Toggle(choice.0, isOn: weekdayBinding(choice.1)).accessibilityIdentifier("reminder.weekday.\(choice.1)")
                    }
                    Text("至少选择一天").font(.footnote).foregroundStyle(.secondary)
                case .monthly:
                    Picker("每月第几日", selection: $monthDay) { ForEach(1...31, id: \.self) { Text("\($0)日").tag($0) } }
                        .accessibilityIdentifier("reminder.monthDay")
                    rollingExplanation
                case .yearly:
                    Picker("月份", selection: $yearMonth) { ForEach(1...12, id: \.self) { Text("\($0)月").tag($0) } }
                        .accessibilityIdentifier("reminder.yearMonth")
                    Picker("日期", selection: $yearDay) { ForEach(1...maxYearDay, id: \.self) { Text("\($0)日").tag($0) } }
                        .accessibilityIdentifier("reminder.yearDay")
                    rollingExplanation
                }
                Picker("提前提醒", selection: $advance) { ForEach(advanceChoices) { Text($0.rawValue).tag($0) } }
                    .accessibilityIdentifier("reminder.advance")
                Toggle("启用提醒", isOn: $enabled)
                if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("reminder.error") }
                if busy { ProgressView("正在保存与安排通知…") }
            }
            .disabled(busy)
            .navigationTitle(original == nil ? "新增提醒" : "编辑提醒")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(busy || !ReminderRecurrence.isSupportedDate(time)).accessibilityIdentifier("reminder.save") }
            }
            .interactiveDismissDisabled(busy)
            .onChange(of: repeatMode) { _ in if !advanceChoices.contains(advance) { advance = .h1 } }
            .onChange(of: yearMonth) { _ in yearDay = min(yearDay, maxYearDay) }
            .alert("提醒已保存", isPresented: Binding(get: { savedNotice != nil }, set: { if !$0 { savedNotice = nil } })) {
                if service.permission != .granted {
                    Button("去设置") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!); dismiss() }
                }
                Button("知道了") { dismiss() }
            } message: { Text(savedNotice ?? "") }
        }
    }
    private var rollingExplanation: some View {
        Text("遇到不存在的日期，改到当月最后一天。通知按实际日期滚动预排，列表会显示截止日期；请在截止前打开 App 补排。")
            .font(.footnote).foregroundStyle(.secondary)
    }
    private var maxYearDay: Int {
        let cal = Calendar(identifier: .gregorian)
        return cal.date(from: DateComponents(year: 2000, month: yearMonth, day: 1))
            .flatMap { cal.range(of: .day, in: .month, for: $0)?.count } ?? 31
    }
    private func weekdayBinding(_ value: Int) -> Binding<Bool> {
        Binding(get: { weekdays.contains(value) }, set: { if $0 { weekdays.insert(value) } else { weekdays.remove(value) } })
    }
    private var rule: RepeatRule {
        switch repeatMode {
        case .once: return .once(at: time)
        case .daily: return .daily
        case .weekly: return .weekly(weekdays)
        case .monthly: return .monthly(day: monthDay)
        case .yearly: return .yearly(month: yearMonth, day: yearDay)
        }
    }
    private func save() {
        guard ReminderRecurrence.isSupportedDate(time) else { error = "一次性提醒日期超出支持范围"; return }
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        if let message = ReminderRecurrence.validationError(rule: rule, hour: c.hour ?? 8, minute: c.minute ?? 0, advance: advance) { error = message; return }
        if enabled, case .once(let due) = rule, due <= Date() { error = "一次性提醒请选择未来时间"; return }
        busy = true; error = nil
        let reminder = Reminder(id: reminderID, petID: pet.id, type: type, hour: c.hour ?? 8, minute: c.minute ?? 0,
                                repeatRule: rule, advance: advance, isEnabled: enabled, sourceRecordID: original?.sourceRecordID)
        Task {
            if enabled { await service.requestPermission() }
            do {
                let notice = try await service.save(reminder, petName: pet.nickname)
                busy = false
                if let notice, enabled { savedNotice = notice } else { dismiss() }
            } catch { busy = false; self.error = "保存失败：" + error.localizedDescription }
        }
    }
}
