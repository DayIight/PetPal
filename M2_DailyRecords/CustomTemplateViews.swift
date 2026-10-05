import SwiftUI

// MARK: - 自定义模板：管理列表 + 新建/编辑表单（M2 CoreDataCustomTemplateRepository 的 UI 落点）
// 记录入口在记录主页「+」模板选择：自定义模板 → CustomRecordFormView

struct TemplateListView: View {
    @State private var templates: [CustomTemplate] = []
    @State private var editing: CustomTemplate?
    @State private var showForm = false
    @State private var loadError = false
    @State private var operationError: String?
    @Environment(\.dismiss) private var dismiss
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("template.done")
                }
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
            .alert("操作失败", isPresented: Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(operationError ?? "请重试") }
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
        do { for index in offsets { try repo.delete(id: templates[index].id) } }
        catch { operationError = "删除失败，原模板已保留，请重试。" }
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

// MARK: - 自定义模板表单入口
struct CustomRecordFormView: View {
    let template: CustomTemplate
    let petID: UUID
    var onSaved: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        RecordEditorView(vm: RecordFormViewModel(repo: CoreDataRecordRepository(), petID: petID,
                                               kind: .custom, template: template)) {
            dismiss(); onSaved()
        }
    }
}
