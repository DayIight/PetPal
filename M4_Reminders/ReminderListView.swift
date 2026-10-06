import SwiftUI

struct ReminderListView: View {
    let pet: Pet
    @ObservedObject var service: ReminderService
    @State private var reminders: [Reminder] = []
    @State private var showForm = false
    @State private var editing: Reminder?
    @State private var busy = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if service.permission != .granted {
                    Section {
                        Text("通知权限未开启，已保存的提醒暂不能发送。")
                        Button("开启通知") { Task { await service.requestPermission(); await service.rescheduleAll() } }
                        Button("系统通知设置") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                    }
                }
                if let message = error ?? service.scheduleError {
                    Section { Text(message).foregroundStyle(.red); Button("重新安排通知") { Task { await service.rescheduleAll() } } }
                }
                if reminders.isEmpty {
                    Text("还没有提醒，点右上角「+」为\(pet.nickname)设置提醒。")
                        .foregroundStyle(.secondary).accessibilityIdentifier("reminders.empty")
                } else {
                    ForEach(reminders) { r in
                        VStack(alignment: .leading, spacing: 6) {
                            Button { editing = r } label: {
                                HStack {
                                    Image(systemName: r.type.symbolName).foregroundStyle(Color.accentColor)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(r.type.rawValue).font(.headline)
                                        Text(r.repeatRule.label).font(.caption).foregroundStyle(.secondary)
                                        Text(scheduleText(r)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing) {
                                        Text(String(format: "%02d:%02d", r.hour, r.minute)).monospacedDigit()
                                        if r.advance != .none { Text(r.advance.rawValue).font(.caption) }
                                    }
                                }
                            }
                            .buttonStyle(.plain).accessibilityIdentifier("reminders.row.\(r.type.rawValue)")
                            Toggle("启用", isOn: Binding(get: { r.isEnabled }, set: { value in changeEnabled(r, value) }))
                                .accessibilityIdentifier("reminders.enabled.\(r.type.rawValue)")
                        }
                    }
                    .onDelete { indices in
                        let selected = indices.map { reminders[$0] }; busy = true
                        Task {
                            do { for r in selected { try await service.remove(r) }; error = nil }
                            catch { self.error = "删除失败：" + error.localizedDescription }
                            busy = false; reload()
                        }
                    }
                }
                if reminders.contains(where: { $0.repeatRule.usesRollingSchedule }) {
                    Text("月/年通知滚动预排，请在显示的截止日期前打开 App 补排。提醒数量、提前提醒会影响窗口长度。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .disabled(busy).navigationTitle("提醒")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button { showForm = true } label: { Image(systemName: "plus") }.accessibilityIdentifier("reminders.add") }
            }
            .sheet(isPresented: $showForm, onDismiss: reload) { ReminderFormView(pet: pet, service: service) }
            .sheet(item: $editing, onDismiss: reload) { ReminderFormView(pet: pet, service: service, editing: $0) }
            .task { await service.rescheduleAll(); reload() }
        }
    }
    private func scheduleText(_ r: Reminder) -> String {
        if !r.isEnabled { return "已暂停" }
        if case .once(let due) = r.repeatRule, due <= Date() { return "已到期" }
        if service.permission != .granted { return "待开启通知权限" }
        if let date = service.scheduledThrough[r.id] { return "通知已安排至 " + date.formatted(date: .abbreviated, time: .shortened) }
        if service.incomplete.contains(r.id) || service.scheduleError != nil { return "尚未完成通知安排，请重试" }
        return "系统重复通知已安排"
    }
    private func changeEnabled(_ r: Reminder, _ enabled: Bool) {
        var updated = r; updated.isEnabled = enabled; busy = true
        Task {
            do { _ = try await service.save(updated, petName: pet.nickname); error = nil }
            catch { self.error = "修改失败：" + error.localizedDescription }
            busy = false; reload()
        }
    }
    private func reload() { reminders = service.reminders(petID: pet.id).sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) } }
}
