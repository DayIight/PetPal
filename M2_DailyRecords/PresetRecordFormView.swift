import SwiftUI

// MARK: - 预设模板通用动态记录表单（按 kind.fields 渲染全部 7 类预设模板；
// 原写死的 FeedingFormView 由本视图取代，字段 key/校验与 RecordFormViewModel 完全一致）
// 双模式：init(petID:kind:) 新建；init(editing:) 编辑已有记录（详情页入口，update 保留原 createdAt）
struct PresetRecordFormView: View {
    @StateObject var vm: RecordFormViewModel
    private let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    /// date/multi/toggle 字段的本地编辑态，保存时统一序列化进 answers
    @State private var busy = false
    @State private var savedNotice: String?
    @State private var reminderTime = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var dates: [String: Date] = [:]
    @State private var toggles: [String: Bool] = [:]
    @State private var multiSelections: [String: Set<String>] = [:]

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init(petID: UUID, kind: RecordKind, onSaved: @escaping () -> Void = {}) {
        _vm = StateObject(wrappedValue: RecordFormViewModel(
            repo: CoreDataRecordRepository(), petID: petID, kind: kind,
            weightRepo: CoreDataWeightRepository()))
        self.onSaved = onSaved
    }

    init(editing record: Record, onSaved: @escaping () -> Void = {}) {
        _vm = StateObject(wrappedValue: RecordFormViewModel(
            repo: CoreDataRecordRepository(), editing: record,
            weightRepo: CoreDataWeightRepository()))
        self.onSaved = onSaved
        // date/toggle/multi 本地编辑态按模板字段类型从 answers 反序列化回填
        var d: [String: Date] = [:], t: [String: Bool] = [:], m: [String: Set<String>] = [:]
        for field in record.kind.fields {
            let raw = record.answers[field.key] ?? ""
            switch field.kind {
            case .date:
                if let date = Self.dayFormatter.date(from: raw) { d[field.key] = date }
            case .toggle:
                t[field.key] = raw == "true"
            case .multi:
                m[field.key] = Set(raw.split(separator: ",").map(String.init))
            default:
                break
            }
        }
        _dates = State(initialValue: d)
        _reminderTime = State(initialValue: Calendar.current.date(bySettingHour: record.nextReminderHour, minute: record.nextReminderMinute, second: 0, of: Date()) ?? Date())
        _toggles = State(initialValue: t)
        _multiSelections = State(initialValue: m)
    }

    var body: some View {
        Form {
            ForEach(vm.draft.kind.fields, id: \.key) { field in
                Section(field.title) {
                    fieldView(field)
                }
            }
            if vm.draft.kind == .vaccine || vm.draft.kind == .deworming {
                Section("下次提醒") {
                    Toggle("按下次日期设置一次性提醒", isOn: $vm.draft.wantsNextReminder)
                        .accessibilityIdentifier("record.nextReminder")
                    if vm.draft.wantsNextReminder {
                        DatePicker("通知时间", selection: $reminderTime, displayedComponents: .hourAndMinute)
                        Text("提醒与这条记录关联；修改下次日期会更新提醒，删除记录会一并取消。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Section("备注与心情") {
                TextField("备注（≤200字）", text: $vm.draft.note)
                    .accessibilityIdentifier("record.note")
                MoodPicker(mood: $vm.draft.mood, a11yPrefix: "record.mood")
            }
            Section("照片（选填，最多9张）") {
                RecordPhotoPicker(
                    savedFileNames: vm.draft.photoFileNames,
                    pickedImages: vm.pickedImages,
                    a11yPrefix: "record.photo",
                    onAddData: { vm.addPhoto($0) },
                    onAddImage: { vm.addPhoto($0) },
                    onRemoveSaved: { vm.removeSavedPhoto($0) },
                    onRemovePicked: { vm.removePickedPhoto(at: $0) }
                )
            }
            if !vm.errors.isEmpty {
                Section {
                    ForEach(vm.errors, id: \.self) {
                        Text($0).font(.footnote).foregroundStyle(.red)
                    }
                }
                .accessibilityIdentifier("record.errors")
            }
        }
        .disabled(busy)
        .interactiveDismissDisabled(busy)
        .alert("记录已保存", isPresented: Binding(get: { savedNotice != nil }, set: { if !$0 { savedNotice = nil } })) {
            Button("知道了") { finish() }
        } message: { Text(savedNotice ?? "") }
        .navigationTitle(vm.isEditing ? "编辑\(vm.draft.kind.rawValue)记录" : "\(vm.draft.kind.rawValue)记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(busy ? "保存中…" : "保存") { save() }.disabled(busy)
                    .accessibilityIdentifier("record.save")
            }
        }
    }

    @ViewBuilder private func fieldView(_ field: TemplateField) -> some View {
        switch field.kind {
        case .text:
            TextField(field.title, text: answer(field.key))
                .accessibilityIdentifier("record.field.\(field.key)")
        case .multiline:
            TextEditor(text: answer(field.key))
                .frame(minHeight: 80)
                .accessibilityIdentifier("record.field.\(field.key)")
        case .number:
            TextField("数字", text: answer(field.key))
                .keyboardType(.decimalPad)
                .accessibilityIdentifier("record.field.\(field.key)")
        case .single(let options):
            Picker(field.title, selection: answer(field.key)) {
                Text("未选择").tag("")
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .accessibilityIdentifier("record.field.\(field.key)")
        case .multi(let options):
            let selected = multiSelections[field.key] ?? []
            ForEach(options, id: \.self) { option in
                Toggle(option, isOn: multiToggleBinding(field.key, option: option, selected: selected))
                    .accessibilityIdentifier("record.field.\(field.key).\(option)")
            }
        case .toggle:
            Toggle(field.title, isOn: toggleBinding(field.key))
                .accessibilityIdentifier("record.field.\(field.key)")
        case .date:
            Toggle("填写日期", isOn: Binding(get: { dates[field.key] != nil }, set: { if $0 { dates[field.key] = Date() } else { dates[field.key] = nil } }))
            if dates[field.key] != nil { DatePicker(field.title, selection: dateBinding(field.key), displayedComponents: .date)
                .accessibilityIdentifier("record.field.\(field.key)") }
        }
    }

    private func answer(_ key: String) -> Binding<String> {
        Binding(get: { vm.draft.answers[key] ?? "" },
                set: { vm.draft.answers[key] = $0 })
    }

    private func dateBinding(_ key: String) -> Binding<Date> {
        Binding(get: { dates[key] ?? Date() }, set: { dates[key] = $0 })
    }

    private func toggleBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { toggles[key] ?? false }, set: { toggles[key] = $0 })
    }

    private func multiToggleBinding(_ key: String, option: String,
                                    selected: Set<String>) -> Binding<Bool> {
        Binding(
            get: { selected.contains(option) },
            set: { isOn in
                var s = multiSelections[key] ?? []
                if isOn { s.insert(option) } else { s.remove(option) }
                multiSelections[key] = s
            })
    }

    private func finish() { dismiss(); onSaved() }

    private func save() {
        var answers = vm.draft.answers
        for field in vm.draft.kind.fields {
            switch field.kind {
            case .date:
                answers[field.key] = dates[field.key].map { Self.dayFormatter.string(from: $0) } ?? ""
            case .toggle:
                answers[field.key] = toggles[field.key] == true ? "true" : "false"
            case .multi:
                answers[field.key] = (multiSelections[field.key] ?? []).sorted().joined(separator: ",")
            default:
                break   // text/number/single 已直接写入 draft.answers
            }
        }
        vm.draft.answers = answers
        let components = Calendar.current.dateComponents([.hour, .minute], from: reminderTime)
        vm.draft.nextReminderHour = components.hour ?? 9; vm.draft.nextReminderMinute = components.minute ?? 0
        guard vm.save() else { return }
        if vm.draft.wantsNextReminder {
            busy = true
            Task {
                await ReminderService.shared.requestPermission()
                await ReminderService.shared.rescheduleAll()
                busy = false
                if ReminderService.shared.permission != .granted { savedNotice = "下次提醒已保存。请在系统设置允许通知后查看提醒列表。" }
                else if let error = ReminderService.shared.scheduleError { savedNotice = error }
                else { finish() }
            }
        } else { finish() }
    }
}
