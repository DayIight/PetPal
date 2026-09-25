import SwiftUI

// MARK: - 提醒表单（类型 + 时间 + 重复规则 + 提前量；M-03：配置一律落库）
// M4 逻辑层已支持 weekly/monthly/yearly 与提前量调度，此处接上 UI 编排
struct ReminderFormView: View {
    let pet: Pet
    @ObservedObject var service: ReminderService
    @State private var type: ReminderType = .feeding
    @State private var time = Date()
    @State private var repeatMode: RepeatMode = .daily
    @State private var weekdays: Set<Int> = [2]        // 每周多选：1=周日...7=周六，默认周一
    @State private var monthDay = 1                    // 每月第几日
    @State private var yearMonth = 1                   // 每年几月
    @State private var yearDay = 1                     // 每年几日
    @State private var advance: AdvanceOption = .none
    @State private var showDeniedAlert = false
    @Environment(\.dismiss) private var dismiss

    /// 重复规则选择器选项（RepeatRule 是关联值枚举，不适合直接进 Picker）
    private enum RepeatMode: String, CaseIterable, Identifiable {
        case daily = "每日", weekly = "每周", monthly = "每月", yearly = "每年"
        var id: String { rawValue }
    }

    /// 展示顺序周一~周日；RepeatRule.weekly 用 1=周日...7=周六（周一至周六 = 2...7）
    private let weekdayChoices: [(label: String, value: Int)] = [
        ("周一", 2), ("周二", 3), ("周三", 4), ("周四", 5), ("周五", 6), ("周六", 7), ("周日", 1)
    ]

    var body: some View {
        NavigationStack {
            Form {
                Picker("提醒类型", selection: $type) {
                    ForEach(ReminderType.allCases) { Text($0.rawValue).tag($0) }
                }
                DatePicker("提醒时间", selection: $time, displayedComponents: .hourAndMinute)
                Picker("重复", selection: $repeatMode) {
                    ForEach(RepeatMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .accessibilityIdentifier("reminder.repeat")
                switch repeatMode {
                case .daily:
                    EmptyView()
                case .weekly:
                    ForEach(weekdayChoices, id: \.value) { choice in
                        Toggle(choice.label, isOn: weekdayBinding(choice.value))
                            .accessibilityIdentifier("reminder.weekday.\(choice.value)")
                    }
                case .monthly:
                    Picker("每月第几日", selection: $monthDay) {
                        ForEach(1...31, id: \.self) { Text("\($0)日").tag($0) }
                    }
                    .accessibilityIdentifier("reminder.monthDay")
                case .yearly:
                    Picker("月份", selection: $yearMonth) {
                        ForEach(1...12, id: \.self) { Text("\($0)月").tag($0) }
                    }
                    .accessibilityIdentifier("reminder.yearMonth")
                    Picker("日期", selection: $yearDay) {
                        ForEach(1...31, id: \.self) { Text("\($0)日").tag($0) }
                    }
                    .accessibilityIdentifier("reminder.yearDay")
                }
                Picker("提前提醒", selection: $advance) {
                    ForEach(AdvanceOption.allCases) { Text($0.rawValue).tag($0) }
                }
                .accessibilityIdentifier("reminder.advance")
            }
            .navigationTitle("提醒")
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }.accessibilityIdentifier("reminder.save")
            } }
            .alert("通知权限未开启", isPresented: $showDeniedAlert) {
                Button("去设置") {
                    UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                    dismiss()   // 提醒已落库；开启权限后回到 App 由 Service 补调度
                }
                Button("稍后", role: .cancel) { dismiss() }
            } message: {
                Text("提醒已保存，但需要允许通知才能准时送达。可在系统设置中随时开启。")
            }
        }
    }

    private func weekdayBinding(_ weekday: Int) -> Binding<Bool> {
        Binding(
            get: { weekdays.contains(weekday) },
            set: { isOn in
                if isOn { weekdays.insert(weekday) } else { weekdays.remove(weekday) }
            })
    }

    /// 保存时组装 RepeatRule；每周至少选一天，否则回退每日（UI 已默认勾选周一，兜底不丢配置）
    private var repeatRule: RepeatRule {
        switch repeatMode {
        case .daily: return .daily
        case .weekly: return weekdays.isEmpty ? .daily : .weekly(weekdays)
        case .monthly: return .monthly(day: monthDay)
        case .yearly: return .yearly(month: yearMonth, day: yearDay)
        }
    }

    private func save() {
        Task {
            await service.requestPermission()
            let c = Calendar.current.dateComponents([.hour, .minute], from: time)
            // 先落库（service 内部权限不足时仅跳过调度），再按权限状态决定去向
            try? await service.save(
                Reminder(petID: pet.id, type: type, hour: c.hour ?? 8, minute: c.minute ?? 0,
                         repeatRule: repeatRule, advance: advance),
                petName: pet.nickname)
            if service.permission == .granted { dismiss() } else { showDeniedAlert = true }
        }
    }
}
