import SwiftUI

// MARK: - 自定义模板：管理列表 + 新建/编辑表单（M2 CoreDataCustomTemplateRepository 的 UI 落点）
// 记录入口在记录主页「+」模板选择：自定义模板 → CustomRecordFormView

struct TemplateListView: View {
    @State private var templates: [CustomTemplate] = []
    @State private var editing: CustomTemplate?
    @State private var showForm = false
    @State private var loadError = false
    private let repo = CoreDataCustomTemplateRepository()

    var body: some View {
        NavigationStack {
            Group {
                if templates.isEmpty && !loadError {
                    // iOS 16 无 ContentUnavailableView，等效自绘空态引导
                    VStack(spacing: DS.Spacing.md) {
                        Image(systemName: "rectangle.stack.badge.plus")
                            .font(.largeTitle).foregroundStyle(.secondary)
                        Text("还没有自定义模板").font(.headline)
                        Text("点右上角「新建模板」，组合出喂食、用药等专属记录格式")
                            .font(.body).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(DS.Spacing.lg)
                    .accessibilityIdentifier("template.empty")
                } else if loadError {
                    VStack(spacing: DS.Spacing.md) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                        Text("模板加载失败").font(.headline)
                        Button("重试") { load() }
                            .accessibilityIdentifier("template.retry")
                    }
                    .padding(DS.Spacing.lg)
                } else {
                    List {
                        ForEach(templates) { template in
                            Button {
                                editing = template; showForm = true
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                                        Text(template.name).font(.body)
                                        Text("\(template.fields.count) 个字段")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .a11y("编辑模板\(template.name)", hint: "修改字段或选项")
                            .accessibilityIdentifier("template.row.\(template.name)")
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .background(Color.pageBackground)
            .navigationTitle("自定义模板")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("新建模板") { editing = nil; showForm = true }
                        .a11y("新建模板", hint: "创建新的自定义记录模板")
                        .accessibilityIdentifier("template.add")
                }
            }
            .sheet(isPresented: $showForm, onDismiss: load) {
                TemplateFormView(template: editing, onSave: load)
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        do {
            templates = try repo.all()
            loadError = false
        } catch {
            loadError = true
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            try? repo.delete(id: templates[index].id)
        }
        load()
    }
}

// MARK: - 新建/编辑模板表单
struct TemplateFormView: View {
    @State private var name: String
    @State private var fields: [CustomTemplate.Field]
    @State private var error: String?
    @State private var showLimitAlert = false
    private let existing: CustomTemplate?
    private let repo = CoreDataCustomTemplateRepository()
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    init(template: CustomTemplate? = nil, onSave: @escaping () -> Void = {}) {
        self.existing = template
        self.onSave = onSave
        _name = State(initialValue: template?.name ?? "")
        _fields = State(initialValue: template?.fields ?? [CustomTemplate.Field(title: "", type: .text)])
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("模板名") {
                    TextField("模板名", text: $name)
                        .accessibilityIdentifier("template.name")
                }
                Section("字段") {
                    ForEach($fields) { $field in
                        fieldEditor($field)
                    }
                    .onDelete { fields.remove(atOffsets: $0) }
                    Button("添加字段") { fields.append(CustomTemplate.Field(title: "", type: .text)) }
                        .accessibilityIdentifier("template.addField")
                }
                if let error {
                    Section {
                        Text(error).font(.footnote).foregroundStyle(.red)
                            .accessibilityIdentifier("template.error")
                    }
                }
            }
            .navigationTitle(existing == nil ? "新建模板" : "编辑模板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .accessibilityIdentifier("template.save")
                }
            }
            .alert("最多创建\(CoreDataCustomTemplateRepository.maxCount)个自定义模板",
                   isPresented: $showLimitAlert) {
                Button("好", role: .cancel) {}
            }
        }
    }

    @ViewBuilder private func fieldEditor(_ field: Binding<CustomTemplate.Field>) -> some View {
        let key = field.wrappedValue.id.uuidString
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            TextField("字段标题", text: field.title)
                .accessibilityIdentifier("template.fieldTitle.\(key)")
            Picker("类型", selection: field.type) {
                ForEach(CustomTemplate.FieldType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .accessibilityIdentifier("template.fieldType.\(key)")
            if field.wrappedValue.type == .single || field.wrappedValue.type == .multi {
                // 选项编辑：逗号分隔输入（低成本可靠方案）
                TextField("选项（逗号分隔）", text: optionsBinding(field))
                    .accessibilityIdentifier("template.fieldOptions.\(key)")
            }
            Toggle("必填", isOn: field.isRequired)
                .accessibilityIdentifier("template.fieldRequired.\(key)")
        }
    }

    private func optionsBinding(_ field: Binding<CustomTemplate.Field>) -> Binding<String> {
        Binding(
            get: { field.wrappedValue.options.joined(separator: ",") },
            set: {
                field.wrappedValue.options = $0
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            })
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { error = "模板名不能为空"; return }
        guard !fields.isEmpty else { error = "至少需要一个字段"; return }
        guard fields.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespaces).isEmpty })
        else { error = "字段标题不能为空"; return }
        var template = CustomTemplate(name: trimmed, fields: fields)
        if let existing { template.id = existing.id; template.createdAt = existing.createdAt }
        do {
            try repo.save(template)
            onSave()
            dismiss()
        } catch CustomTemplateError.limitExceeded {
            showLimitAlert = true
        } catch {
            self.error = "保存失败，请重试"
        }
    }
}

// MARK: - 按模板动态渲染的记录表单
// 字段类型映射：text→TextField、multiline→TextEditor、number→decimalPad、
// single→Picker、multi→多个 Toggle（存逗号串）、toggle→Toggle(存 "true"/"false")、date→DatePicker(存 yyyy-MM-dd)
struct CustomRecordFormView: View {
    let template: CustomTemplate
    let petID: UUID
    @State private var answers: [String: String] = [:]
    @State private var toggles: [String: Bool] = [:]
    @State private var multiSelections: [String: Set<String>] = [:]
    @State private var dates: [String: Date] = [:]
    @State private var note = ""
    @State private var mood = ""
    @State private var errors: [String] = []
    private let repo = CoreDataRecordRepository()
    @Environment(\.dismiss) private var dismiss

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        NavigationStack {
            Form {
                ForEach(template.fields) { field in
                    Section(field.title) {
                        fieldView(field)
                    }
                }
                Section("备注与心情") {
                    TextField("备注（≤200字）", text: $note)
                        .accessibilityIdentifier("custom.note")
                    Picker("心情", selection: $mood) {
                        ForEach(["😀", "😐", "😢"], id: \.self) { Text($0).tag($0) }
                    }
                    .accessibilityIdentifier("custom.mood")
                }
                if !errors.isEmpty {
                    Section {
                        ForEach(errors, id: \.self) {
                            Text($0).font(.footnote).foregroundStyle(.red)
                        }
                    }
                    .accessibilityIdentifier("custom.errors")
                }
            }
            .navigationTitle(template.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .accessibilityIdentifier("custom.save")
                }
            }
        }
    }

    @ViewBuilder private func fieldView(_ field: CustomTemplate.Field) -> some View {
        let key = field.id.uuidString
        switch field.type {
        case .text:
            TextField(field.title, text: textBinding(key))
                .accessibilityIdentifier("custom.field.\(key)")
        case .multiline:
            TextEditor(text: textBinding(key))
                .frame(minHeight: 80)
                .accessibilityIdentifier("custom.field.\(key)")
        case .number:
            TextField("数字", text: textBinding(key))
                .keyboardType(.decimalPad)
                .accessibilityIdentifier("custom.field.\(key)")
        case .single:
            Picker(field.title, selection: textBinding(key)) {
                Text("未选择").tag("")
                ForEach(field.options, id: \.self) { Text($0).tag($0) }
            }
            .accessibilityIdentifier("custom.field.\(key)")
        case .multi:
            // 多选：多个 Toggle，选择结果存逗号分隔串（展示/校验与空值判断一致）
            let selected = multiSelections[key] ?? []
            ForEach(field.options, id: \.self) { option in
                Toggle(option, isOn: multiToggleBinding(key, option: option, selected: selected))
                    .accessibilityIdentifier("custom.field.\(key).\(option)")
            }
        case .toggle:
            Toggle(field.title, isOn: toggleBinding(key))
                .accessibilityIdentifier("custom.field.\(key)")
        case .date:
            DatePicker(field.title, selection: dateBinding(key), displayedComponents: .date)
                .accessibilityIdentifier("custom.field.\(key)")
        }
    }

    private func textBinding(_ key: String) -> Binding<String> {
        Binding(get: { answers[key] ?? "" }, set: { answers[key] = $0 })
    }

    private func toggleBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { toggles[key] ?? false }, set: { toggles[key] = $0 })
    }

    private func dateBinding(_ key: String) -> Binding<Date> {
        Binding(get: { dates[key] ?? Date() }, set: { dates[key] = $0 })
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

    private func save() {
        var record = Record(petID: petID, kind: .custom, note: note, mood: mood)
        record.templateName = template.name
        var result: [String: String] = [:]
        for field in template.fields {
            let key = field.id.uuidString
            switch field.type {
            case .toggle:
                result[key] = toggles[key] == true ? "true" : "false"
            case .multi:
                result[key] = (multiSelections[key] ?? []).sorted().joined(separator: ",")
            case .date:
                result[key] = Self.dayFormatter.string(from: dates[key] ?? Date())
            default:
                result[key] = answers[key] ?? ""
            }
        }
        record.answers = result
        // 自定义模板记录的校验：传入模板字段（key 与 answers 一致）
        errors = RecordValidator.errors(for: record, fields: template.templateFields)
        guard errors.isEmpty else { return }
        do {
            try repo.create(record)
            dismiss()
        } catch {
            errors = ["保存失败，请重试"]
        }
    }
}
