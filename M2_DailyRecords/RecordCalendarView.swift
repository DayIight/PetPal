import SwiftUI
import Combine

// MARK: - 记录日历（M2 CalendarGridBuilder 的 UI 落点）
// 月视图网格 + 左右翻历史月份 + 当日记录列表 + 记录详情（只读）

@MainActor final class RecordCalendarViewModel: ObservableObject {
    @Published private(set) var counts: [Date: Int] = [:]   // startOfDay → 当日记录数
    @Published private(set) var records: [Record] = []
    @Published private(set) var months: [Date] = []         // 每月 1 日，升序（可滑动范围）
    @Published var selectedMonth: Date = Date()
    private var bag = Set<AnyCancellable>()
    // 必须持有 repo：repo deinit 会移除 recordsDidChange 观察者，广播链路随之断开
    private let repo: RecordRepository

    init(repo: RecordRepository, petID: UUID) {
        self.repo = repo
        repo.recordsPublisher(petID: petID).receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.apply($0) }
            .store(in: &bag)
    }

    /// 月份覆盖区间与看板热力图一致：最早记录所在月 → 本月（无记录时仅本月）
    private func apply(_ records: [Record]) {
        self.records = records
        let cal = Calendar.current
        counts = CalendarGridBuilder.countsByDay(records)
        let thisMonth = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        guard let earliest = records.map(\.createdAt).min() else {
            months = [thisMonth]; selectedMonth = thisMonth; return
        }
        var first = cal.date(from: cal.dateComponents([.year, .month], from: earliest))!
        if let limit = cal.date(byAdding: .month, value: -23, to: thisMonth), first < limit {
            first = limit   // 历史月份上限 24 个，超出截断
        }
        var result: [Date] = []
        var cursor = first
        while cursor <= thisMonth {
            result.append(cursor)
            cursor = cal.date(byAdding: .month, value: 1, to: cursor)!
        }
        months = result
        if !months.contains(where: { cal.isDate($0, equalTo: selectedMonth, toGranularity: .month) }) {
            selectedMonth = months.last ?? thisMonth
        }
    }

    /// 翻月（按钮方案；PRD 允许 TabView 翻页或按钮翻月二选一。
    /// 不用 paged TabView：iOS 16 上 page 样式 + Date 选择标签在本工程 sheet 场景下会卡死主线程，按钮方案稳定且可测）
    func shiftMonth(_ delta: Int) {
        let cal = Calendar.current
        guard let index = months.firstIndex(where: {
            cal.isDate($0, equalTo: selectedMonth, toGranularity: .month)
        }) else { return }
        let target = index + delta
        guard months.indices.contains(target) else { return }   // 已到最早/最新月份
        selectedMonth = months[target]
    }

    /// 当前是否位于可翻区间边界（按钮置灰用）
    func canShift(_ delta: Int) -> Bool {
        let cal = Calendar.current
        guard let index = months.firstIndex(where: {
            cal.isDate($0, equalTo: selectedMonth, toGranularity: .month)
        }) else { return false }
        return months.indices.contains(index + delta)
    }
}

struct RecordCalendarView: View {
    let pet: Pet
    @StateObject private var vm: RecordCalendarViewModel
    @State private var selectedDate = Date()
    @State private var detailRecord: Record?
    private let cal = Calendar.current

    init(pet: Pet) {
        self.pet = pet
        _vm = StateObject(wrappedValue: RecordCalendarViewModel(
            repo: CoreDataRecordRepository(), petID: pet.id))
    }

    /// 独立使用（sheet 场景）自带 NavigationStack；嵌入记录主页时用下方 RecordCalendarContentView
    var body: some View {
        NavigationStack {
            RecordCalendarContentView(pet: pet, vm: vm,
                                      selectedDate: $selectedDate, detailRecord: $detailRecord)
                .background(Color.pageBackground)
                .navigationTitle("记录日历")
        }
        .sheet(item: $detailRecord) { RecordDetailView(record: $0) }
    }
}

/// 日历内容（月网格 + 当日列表），与导航壳解耦，供记录主页「日历」分段直接嵌入
struct RecordCalendarContentView: View {
    let pet: Pet
    @ObservedObject var vm: RecordCalendarViewModel
    @Binding var selectedDate: Date
    @Binding var detailRecord: Record?
    private let cal = Calendar.current

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.md) {
                monthPager
                dayList
            }
            .padding(DS.Spacing.md)
        }
    }

    // MARK: 月视图网格（上一月/下一月按钮翻阅历史月份）
    private var monthPager: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                HStack {
                    Button {
                        vm.shiftMonth(-1)
                        snapSelectionToMonth()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .a11y("上个月", hint: "查看更早月份")
                    .accessibilityIdentifier("calendar.prevMonth")
                    .disabled(!vm.canShift(-1))
                    Spacer()
                    Text(monthTitle(for: vm.selectedMonth)).font(.headline)
                    Spacer()
                    Button {
                        vm.shiftMonth(1)
                        snapSelectionToMonth()
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .a11y("下个月", hint: "查看更新月份")
                    .accessibilityIdentifier("calendar.nextMonth")
                    .disabled(!vm.canShift(1))
                }
                MonthCalendarGrid(month: vm.selectedMonth, counts: vm.counts,
                                  selectedDate: selectedDate) { date in
                    selectedDate = date
                }
            }
        }
    }

    private func monthTitle(for month: Date) -> String {
        let comps = cal.dateComponents([.year, .month], from: month)
        return "\(comps.year ?? 0)年\(comps.month ?? 0)月"
    }

    /// 翻月后，若所选日期不在该月，回退到该月 1 号（当日列表与网格保持一致）
    private func snapSelectionToMonth() {
        if !cal.isDate(selectedDate, equalTo: vm.selectedMonth, toGranularity: .month) {
            selectedDate = vm.selectedMonth
        }
    }

    // MARK: 当日记录列表（点击格子更新）
    private var dayList: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                Text(dayTitle).font(.headline)
                    .accessibilityIdentifier("calendar.dayListTitle")
                let items = dayRecords
                if items.isEmpty {
                    Text("当日暂无记录")
                        .font(.body).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .accessibilityIdentifier("calendar.dayListEmpty")
                } else {
                    VStack(spacing: DS.Spacing.sm) {
                        ForEach(items) { record in
                            recordRow(record)
                        }
                    }
                }
            }
        }
    }

    private var dayTitle: String {
        let m = cal.component(.month, from: selectedDate)
        let d = cal.component(.day, from: selectedDate)
        return "\(m)月\(d)日 记录"
    }

    private var dayRecords: [Record] {
        vm.records.filter { cal.isDate($0.createdAt, inSameDayAs: selectedDate) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func recordRow(_ record: Record) -> some View {
        Button { detailRecord = record } label: {
            HStack(spacing: DS.Spacing.sm) {
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Text(record.displayKind).font(.body)
                    if !record.summary.isEmpty {
                        Text(record.summary).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: DS.Spacing.sm)
                if !record.mood.isEmpty {
                    Text(record.mood).font(.body)
                }
            }
            .padding(DS.Spacing.sm)
            .background(Color.groupedBackground,
                        in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        }
        .a11y(record.displayKind, hint: "查看记录详情")
        .accessibilityIdentifier("calendar.recordRow")
    }
}

// MARK: - 单月网格（周标题尊重 firstWeekday；圆点=有记录，描边=今天）
struct MonthCalendarGrid: View {
    let month: Date
    let counts: [Date: Int]
    let selectedDate: Date
    let onSelect: (Date) -> Void
    private let cal = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: DS.Spacing.xs), count: 7)

    var body: some View {
        let days = CalendarGridBuilder.month(containing: month, counts: counts)
        VStack(spacing: DS.Spacing.sm) {
            HStack {
                Text(monthTitle).font(.headline)
                Spacer()
            }
            LazyVGrid(columns: columns, spacing: DS.Spacing.xs) {
                ForEach(0..<7, id: \.self) { index in
                    Text(weekdaySymbol(index)).font(.caption).foregroundStyle(.secondary)
                }
                // 占位格（date=nil）的 CalendarDay.id 是随机 UUID，每次渲染都变，
                // 直接用 ForEach(days) 会让 SwiftUI 身份失效引发渲染死循环；
                // 改用下标做稳定 identity（骨架 CalendarGridBuilder 不动）
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    dayCell(day)
                }
            }
        }
    }

    private var monthTitle: String {
        let comps = cal.dateComponents([.year, .month], from: month)
        return "\(comps.year ?? 0)年\(comps.month ?? 0)月"
    }

    /// veryShortWeekdaySymbols 固定以周日开头，按 firstWeekday 旋转
    private func weekdaySymbol(_ index: Int) -> String {
        let symbols = cal.veryShortWeekdaySymbols
        return symbols[(cal.firstWeekday - 1 + index) % 7]
    }

    private func dayCell(_ day: CalendarDay) -> some View {
        Group {
            if let date = day.date {
                realCell(date, count: day.count)
            } else {
                Color.clear.frame(minHeight: 40)   // 月外占位格
            }
        }
    }

    private func realCell(_ date: Date, count: Int) -> some View {
        let d = cal.component(.day, from: date)
        let m = cal.component(.month, from: date)
        let isToday = cal.isDateInToday(date)
        let isSelected = cal.isDate(date, inSameDayAs: selectedDate)
        return Button { onSelect(date) } label: {
            VStack(spacing: 2) {
                Text("\(d)").font(.body)
                Circle()
                    .fill(count > 0 ? Color.accentColor : Color.clear)
                    .frame(width: 6, height: 6)
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .strokeBorder(isToday ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
        .a11y("\(m)月\(d)日", hint: count > 0 ? "有\(count)条记录" : "无记录")
        .accessibilityIdentifier("calendar.day.\(m)月\(d)日")
    }
}

// MARK: - 记录详情（只读展示 + 「编辑」入口复用表单）
// 编辑走 RecordRepository.update（保留原 createdAt）；编辑保存后订阅广播刷新本页快照。
// 自定义记录的编辑需按 templateName 反解模板；模板已删除时降级为只读并提示。
struct RecordDetailView: View {
    @State private var record: Record
    @State private var showEdit = false
    @State private var editTemplate: CustomTemplate?
    @State private var showTemplateMissing = false
    @State private var showDelete = false
    @State private var deleteError: String?
    @Environment(\.dismiss) private var dismiss
    @State private var reloadCancellable: AnyCancellable?
    private let repo = CoreDataRecordRepository()
    private let templateRepo = CoreDataCustomTemplateRepository()
    private let cal = Calendar.current

    init(record: Record) {
        _record = State(initialValue: record)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("记录") {
                    LabeledContent("类型", value: record.displayKind)
                    LabeledContent("时间", value: timeText)
                }
                // 预设模板：按 kind.fields 的标题展示；自定义模板：标题仅存于模板内，
                // 记录里只有字段 UUID key，无法反解，直接列出原始键值
                if record.kind != .custom {
                    Section("内容") {
                        ForEach(record.kind.fields, id: \.key) { field in
                            LabeledContent(field.title, value: record.answers[field.key].flatMap { $0.isEmpty ? nil : $0 } ?? "—")
                        }
                    }
                } else if let snapshot = record.templateSnapshot {
                    Section("内容") {
                        ForEach(snapshot.fields) { field in
                            LabeledContent(field.title, value: record.answers[field.id.uuidString].flatMap { $0.isEmpty ? nil : $0 } ?? "—")
                        }
                    }
                } else if !record.answers.isEmpty {
                    Section("内容") {
                        ForEach(record.answers.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                            LabeledContent("旧字段（\(key.prefix(8))）", value: value.isEmpty ? "—" : value)
                        }
                    }
                }
                Section("备注与心情") {
                    LabeledContent("备注", value: record.note.isEmpty ? "—" : record.note)
                    LabeledContent("心情", value: record.mood.isEmpty ? "—" : record.mood)
                }
                if !record.photoFileNames.isEmpty {
                    Section("照片") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: DS.Spacing.sm) {
                                ForEach(record.photoFileNames, id: \.self) { name in
                                    if let image = AvatarStore.load(fileName: name) {
                                        Image(uiImage: image)
                                            .resizable().scaledToFill()
                                            .frame(width: 96, height: 96)
                                            .clipped()
                                            .cornerRadius(DS.Radius.control)
                                    }
                                }
                            }
                            .padding(.vertical, DS.Spacing.xs)
                        }
                        .accessibilityIdentifier("detail.photos")
                    }
                }
            }
            .accessibilityIdentifier("calendar.recordDetail")
            .confirmationDialog("删除这条记录？关联照片、体检体重和下次提醒也会删除。", isPresented: $showDelete, titleVisibility: .visible) {
                Button("确认删除记录", role: .destructive) {
                    do { try repo.delete(id: record.id); dismiss() }
                    catch { deleteError = "删除失败：" + error.localizedDescription }
                }
            }
            .alert("删除失败", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(deleteError ?? "") }
            .navigationTitle("记录详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .bottomBar) { Button("删除记录", role: .destructive) { showDelete = true }.accessibilityIdentifier("detail.delete") }
                ToolbarItem(placement: .confirmationAction) {
                    Button("编辑", action: beginEdit)
                        .a11y("编辑记录", hint: "修改本条记录的内容")
                        .accessibilityIdentifier("detail.edit")
                }
            }
            .sheet(isPresented: $showEdit, onDismiss: reload) {
                if record.kind == .custom, let template = editTemplate {
                    CustomRecordFormView(template: template, editing: record)
                } else {
                    NavigationStack { PresetRecordFormView(editing: record) }
                }
            }
            .alert("无法编辑", isPresented: $showTemplateMissing) {
                Button("好", role: .cancel) {}
            } message: {
                Text("这是一条旧版记录，未保存完整字段定义。为保留原始答案，暂时只能查看或删除。")
            }
        }
    }

    private func beginEdit() {
        if record.kind == .custom {
            guard let template = record.templateSnapshot else {
                showTemplateMissing = true
                return
            }
            editTemplate = template
        }
        showEdit = true
    }

    /// 编辑保存后 repo 已广播重载，订阅一次取回本条最新快照（被删除则保持旧值展示）
    private func reload() {
        reloadCancellable = repo.recordsPublisher(petID: record.petID).first()
            .sink { records in
                if let fresh = records.first(where: { $0.id == record.id }) { record = fresh }
            }
    }

    private var timeText: String {
        let m = cal.component(.month, from: record.createdAt)
        let d = cal.component(.day, from: record.createdAt)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return "\(m)月\(d)日 \(f.string(from: record.createdAt))"
    }
}
