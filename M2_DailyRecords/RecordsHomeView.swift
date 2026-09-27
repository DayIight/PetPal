import SwiftUI

// MARK: - 记录主页（「记录」tab：顶部当前宠物切换 + 时间轴/日历分段 + 记一条/提醒入口）
struct RecordsHomeView: View {
    @ObservedObject var currentPet: CurrentPetStore
    @ObservedObject var reminderService: ReminderService
    @Binding var pickerRequested: Bool   // 发布 sheet「记一条日常」跨 tab 触发模板选择
    @State private var segment: Segment = .timeline
    @State private var showTemplatePicker = false
    @State private var showReminder = false

    private enum Segment: String, CaseIterable, Identifiable {
        case timeline = "时间轴", calendar = "日历"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                petHeader
                Picker("视图切换", selection: $segment) {
                    ForEach(Segment.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.sm)
                .accessibilityIdentifier("records.segment")
                content
            }
            .background(Color.pageBackground)
            .navigationTitle("记录")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showReminder = true } label: {
                        Image(systemName: "bell.badge")
                    }
                    .a11y("设一个提醒", hint: "为当前宠物创建重复提醒")
                    .accessibilityIdentifier("records.reminder")
                    .disabled(currentPet.current == nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { showTemplatePicker = true } label: {
                        Image(systemName: "plus")
                    }
                    .a11y("记一条", hint: "选择模板，为当前宠物创建一条记录")
                    .accessibilityIdentifier("records.add")
                    .disabled(currentPet.current == nil)
                }
            }
        }
        .sheet(isPresented: $showTemplatePicker) {
            RecordTemplatePickerView(pet: currentPet.current)
        }
        .sheet(isPresented: $showReminder) {
            if let pet = currentPet.current {
                ReminderFormView(pet: pet, service: reminderService)
            }
        }
        // 发布 sheet 跳来：切到记录 tab 后自动弹模板选择
        .onChange(of: pickerRequested) { requested in
            if requested { showTemplatePicker = true; pickerRequested = false }
        }
    }

    // MARK: 顶部当前宠物切换（H-07：多宠物家庭可切换；单宠时静态展示）
    private var petHeader: some View {
        CardContainer {
            HStack(spacing: DS.Spacing.sm) {
                if let pet = currentPet.current {
                    PetAvatarThumb(pet: pet, diameter: 36)
                    if currentPet.pets.count > 1 {
                        Menu {
                            ForEach(currentPet.pets) { p in
                                Button {
                                    currentPet.select(p)
                                } label: {
                                    Label("\(p.nickname)（\(p.species.rawValue)）",
                                          systemImage: p.id == pet.id ? "checkmark.circle.fill" : "circle")
                                }
                            }
                        } label: {
                            Label("当前宠物：\(pet.nickname)", systemImage: "arrow.triangle.2.circlepath")
                                .font(.body)
                        }
                        .a11y("切换宠物", hint: "当前为\(pet.nickname)，共\(currentPet.pets.count)只")
                        .accessibilityIdentifier("records.petSwitcher")
                    } else {
                        Text("当前宠物：\(pet.nickname)").font(.body)
                            .accessibilityIdentifier("records.currentPet")
                    }
                } else {
                    Text("还没有宠物档案").font(.body).foregroundStyle(.secondary)
                        .accessibilityIdentifier("records.noPetHeader")
                }
                Spacer(minLength: DS.Spacing.sm)
            }
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.top, DS.Spacing.sm)
    }

    @ViewBuilder private var content: some View {
        switch segment {
        case .timeline:
            if let pet = currentPet.current {
                TimelineRecordsView(pet: pet).id(pet.id)
            } else {
                noPetPlaceholder
            }
        case .calendar:
            if let pet = currentPet.current {
                EmbeddedCalendarView(pet: pet).id(pet.id)
            } else {
                noPetPlaceholder
            }
        }
    }

    /// 无档案引导（建档在「我的」tab 完成）
    private var noPetPlaceholder: some View {
        VStack(spacing: DS.Spacing.md) {
            Image(systemName: "tray")
                .font(.system(size: 40)).foregroundStyle(.secondary)
            Text("创建宠物档案后，这里会展示它的日常记录")
                .font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("records.noPet")
        }
        .frame(maxWidth: .infinity)
        .padding(DS.Spacing.xl)
    }
}

// MARK: - 时间轴（TimelineViewModel.sections 的 UI 落点：按日分组卡片列表）
private struct TimelineRecordsView: View {
    let pet: Pet
    @StateObject private var vm: TimelineViewModel
    private let cal = Calendar.current

    init(pet: Pet) {
        self.pet = pet
        _vm = StateObject(wrappedValue: TimelineViewModel(
            repo: CoreDataRecordRepository(), petID: pet.id))
    }

    var body: some View {
        ScrollView {
            if vm.sections.isEmpty {
                VStack(spacing: DS.Spacing.md) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("还没有记录").font(.headline)
                    Text("点右上角「+」选择模板，记第一条日常")
                        .font(.body).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(DS.Spacing.xl)
                .accessibilityIdentifier("records.timelineEmpty")
            } else {
                VStack(spacing: DS.Spacing.md) {
                    ForEach(vm.sections, id: \.day) { section in
                        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                            Text(dayTitle(section.day)).font(.headline)
                                .padding(.horizontal, DS.Spacing.md)
                            VStack(spacing: DS.Spacing.sm) {
                                ForEach(section.items) { record in
                                    recordRow(record)
                                }
                            }
                            .padding(.horizontal, DS.Spacing.md)
                        }
                    }
                }
                .padding(.vertical, DS.Spacing.sm)
            }
        }
    }

    private func dayTitle(_ day: Date) -> String {
        let m = cal.component(.month, from: day)
        let d = cal.component(.day, from: day)
        return cal.isDateInToday(day) ? "今天（\(m)月\(d)日）" : "\(m)月\(d)日"
    }

    /// 行：类型圆标 + displayKind + summary + 心情 + 时间（卡片样式）
    private func recordRow(_ record: Record) -> some View {
        CardContainer {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: record.kind == .custom ? "note.text" : record.kind.symbolName)
                    .font(.body)
                    .frame(width: 36, height: 36)
                    .background(Color.groupedBackground,
                                in: Circle())
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Text(record.displayKind).font(.headline)
                    if !record.summary.isEmpty {
                        Text(record.summary).font(.body).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: DS.Spacing.sm)
                VStack(alignment: .trailing, spacing: DS.Spacing.xs) {
                    Text(timeText(record.createdAt)).font(.caption)
                        .foregroundStyle(.secondary)
                    if !record.mood.isEmpty {
                        Text(record.mood).font(.body)
                            .accessibilityLabel("心情\(record.mood)")
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("records.row.\(record.id.uuidString)")
    }

    private func timeText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

// MARK: - 记录类型 → SF Symbol 圆标
extension RecordKind {
    var symbolName: String {
        switch self {
        case .feeding: return "fork.knife"
        case .walking: return "figure.walk"
        case .training: return "target"
        case .deworming: return "pill.fill"
        case .vaccine: return "syringe.fill"
        case .checkup: return "stethoscope"
        case .grooming: return "scissors"
        case .custom: return "note.text"
        }
    }
}

// MARK: - 日历嵌入壳（复用 RecordCalendarContentView，不带独立导航栈；换宠时 .id 重建 VM）
private struct EmbeddedCalendarView: View {
    let pet: Pet
    @StateObject private var vm: RecordCalendarViewModel
    @State private var selectedDate = Date()
    @State private var detailRecord: Record?

    init(pet: Pet) {
        self.pet = pet
        _vm = StateObject(wrappedValue: RecordCalendarViewModel(
            repo: CoreDataRecordRepository(), petID: pet.id))
    }

    var body: some View {
        RecordCalendarContentView(pet: pet, vm: vm,
                                  selectedDate: $selectedDate, detailRecord: $detailRecord)
            .sheet(item: $detailRecord) { RecordDetailView(record: $0) }
    }
}

// MARK: - 记录模板选择（预设 7 类图标网格 + 已有自定义模板 + 模板管理入口）
struct RecordTemplatePickerView: View {
    let pet: Pet?
    @State private var templates: [CustomTemplate] = []
    @State private var showTemplates = false
    @State private var dismissAll = false
    private let templateRepo = CoreDataCustomTemplateRepository()
    @Environment(\.dismiss) private var dismiss

    /// sheet 内导航目标（RecordKind 与 CustomTemplate 均不适合直接做 path 元素）
    private enum Destination: Hashable {
        case preset(RecordKind)
        case custom(UUID)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    if pet == nil {
                        Text("请先创建宠物档案（「我的」tab），再记日常")
                            .font(.body).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("record.noPet")
                    }
                    Text("预设记录").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: DS.Spacing.sm)],
                              spacing: DS.Spacing.sm) {
                        ForEach(RecordKind.presetCases) { kind in
                            NavigationLink(value: Destination.preset(kind)) {
                                VStack(spacing: DS.Spacing.sm) {
                                    Image(systemName: kind.symbolName)
                                        .font(.title3)
                                        .frame(width: 48, height: 48)
                                        .background(Color.groupedBackground,
                                                    in: RoundedRectangle(cornerRadius: DS.Radius.control,
                                                                         style: .continuous))
                                        .foregroundStyle(Color.accentColor)
                                    Text(kind.rawValue).font(.caption)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, DS.Spacing.sm)
                            }
                            .a11y(kind.rawValue, hint: "为\(pet?.nickname ?? "当前宠物")记一条\(kind.rawValue)")
                            .accessibilityIdentifier("record.template.\(kind.rawValue)")
                            .disabled(pet == nil)
                            .opacity(pet == nil ? 0.5 : 1)
                        }
                    }
                    if !templates.isEmpty {
                        Text("自定义模板").font(.headline)
                        VStack(spacing: DS.Spacing.sm) {
                            ForEach(templates) { template in
                                NavigationLink(value: Destination.custom(template.id)) {
                                    HStack(spacing: DS.Spacing.sm) {
                                        Image(systemName: "rectangle.stack")
                                            .foregroundStyle(Color.accentColor)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(template.name).font(.body)
                                            Text("\(template.fields.count) 个字段")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    .padding(DS.Spacing.sm)
                                    .background(Color.groupedBackground,
                                                in: RoundedRectangle(cornerRadius: DS.Radius.control,
                                                                     style: .continuous))
                                }
                                .a11y("记\(template.name)", hint: "按模板为\(pet?.nickname ?? "当前宠物")创建记录")
                                .accessibilityIdentifier("record.template.custom.\(template.name)")
                                .disabled(pet == nil)
                                .opacity(pet == nil ? 0.5 : 1)
                            }
                        }
                    }
                    Button("管理自定义模板") { showTemplates = true }
                        .font(.callout)
                        .a11y("管理自定义模板", hint: "新建或编辑自定义记录模板")
                        .accessibilityIdentifier("record.template.manage")
                        .padding(.top, DS.Spacing.xs)
                }
                .padding(DS.Spacing.md)
            }
            .background(Color.pageBackground)
            .navigationTitle("记一条日常")
            .navigationBarTitleDisplayMode(.inline)
            .presentationDetents([.medium, .large])
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .preset(let kind):
                    if let pet {
                        PresetRecordFormView(petID: pet.id, kind: kind) { dismiss() }
                    }
                case .custom(let templateID):
                    if let pet, let template = templates.first(where: { $0.id == templateID }) {
                        CustomRecordFormView(template: template, petID: pet.id)
                    }
                }
            }
            .sheet(isPresented: $showTemplates) { TemplateListView() }
            .onAppear { templates = (try? templateRepo.all()) ?? [] }
        }
    }
}

// MARK: - 预设模板通用动态记录表单（按 kind.fields 渲染全部 7 类预设模板；
// 原写死的 FeedingFormView 由本视图取代，字段 key/校验与 RecordFormViewModel 完全一致）
struct PresetRecordFormView: View {
    @StateObject var vm: RecordFormViewModel
    private let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    /// date/multi/toggle 字段的本地编辑态，保存时统一序列化进 answers
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
            repo: CoreDataRecordRepository(), petID: petID, kind: kind))
        self.onSaved = onSaved
    }

    var body: some View {
        Form {
            ForEach(vm.draft.kind.fields, id: \.key) { field in
                Section(field.title) {
                    fieldView(field)
                }
            }
            Section("备注与心情") {
                TextField("备注（≤200字）", text: $vm.draft.note)
                    .accessibilityIdentifier("record.note")
                Picker("心情", selection: $vm.draft.mood) {
                    ForEach(["😀", "😐", "😢"], id: \.self) { Text($0).tag($0) }
                }
                .accessibilityIdentifier("record.mood")
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
        .navigationTitle("\(vm.draft.kind.rawValue)记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
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
            DatePicker(field.title, selection: dateBinding(field.key), displayedComponents: .date)
                .accessibilityIdentifier("record.field.\(field.key)")
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

    private func save() {
        var answers = vm.draft.answers
        for field in vm.draft.kind.fields {
            switch field.kind {
            case .date:
                answers[field.key] = Self.dayFormatter.string(from: dates[field.key] ?? Date())
            case .toggle:
                answers[field.key] = toggles[field.key] == true ? "true" : "false"
            case .multi:
                answers[field.key] = (multiSelections[field.key] ?? []).sorted().joined(separator: ",")
            default:
                break   // text/number/single 已直接写入 draft.answers
            }
        }
        vm.draft.answers = answers
        if vm.save() {
            dismiss()        // pop 回模板选择
            onSaved()        // 关闭模板选择 sheet
        }
    }
}
