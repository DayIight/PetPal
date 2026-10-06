import SwiftUI

struct ReminderListView: View {
    let pet: Pet
    @ObservedObject var service: ReminderService
    @State private var reminders: [Reminder] = []
    @State private var showNew = false
    @State private var editing: Reminder?
    @State private var deleting: Reminder?
    @State private var error: String?
    @State private var busy = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if service.permission == .denied {
                    Section {
                        Text("通知权限未开启，启用的提醒暂时无法送达。")
                        Button("去设置开启通知") {
                            UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                        }
                    }
                }
                if reminders.isEmpty {
                    Text("还没有提醒，点右上角「新建」添加。")
                        .foregroundStyle(.secondary).accessibilityIdentifier("reminders.empty")
                }
                ForEach(reminders) { reminder in
                    VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                        Button { editing = reminder } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("\(reminder.timeText) \(reminder.type.rawValue)").font(.headline)
                                    Text("\(reminder.ruleText) · \(reminder.advance.rawValue)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("reminders.edit.\(reminder.id.uuidString)")
                        Toggle(reminder.isEnabled ? "已启用" : "已暂停", isOn: Binding(
                            get: { reminder.isEnabled },
                            set: { enabled in update(reminder, enabled: enabled) }))
                            .accessibilityIdentifier("reminders.enabled.\(reminder.id.uuidString)")
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) { deleting = reminder }
                            .accessibilityIdentifier("reminders.delete.\(reminder.id.uuidString)")
                    }
                }
            }
            .disabled(busy)
            .navigationTitle("\(pet.nickname)的提醒")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("reminders.done")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("新建") { showNew = true }.accessibilityIdentifier("reminders.add")
                }
            }
            .sheet(isPresented: $showNew, onDismiss: load) { ReminderFormView(pet: pet, service: service) }
            .sheet(item: $editing, onDismiss: load) { ReminderFormView(pet: pet, service: service, editing: $0) }
            .confirmationDialog("删除这条提醒？", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                if let deleting {
                    Button("删除提醒", role: .destructive) { remove(deleting) }
                }
            } message: { Text("删除后将撤销对应通知。") }
            .alert("操作失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(error ?? "请重试") }
            .onReceive(service.$changeVersion) { _ in load() }
            .task { load() }
        }
    }

    private func load() {
        do { reminders = try service.reminders(petID: pet.id) }
        catch { self.error = "提醒加载失败，请关闭后重试。" }
    }
    private func update(_ reminder: Reminder, enabled: Bool) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false; load() }
            do {
                var value = reminder; value.isEnabled = enabled
                if enabled { try await service.requestPermission() }
                try await service.save(value, petName: pet.nickname)
            } catch { self.error = error.localizedDescription }
        }
    }
    private func remove(_ reminder: Reminder) {
        busy = true
        Task { @MainActor in
            defer { busy = false; deleting = nil; load() }
            do { try await service.remove(id: reminder.id) }
            catch { self.error = "删除失败，原提醒已保留，请重试。" }
        }
    }
}
