import SwiftUI
import Combine

// MARK: - 记录日历（M2 CalendarGridBuilder 的 UI 落点）
// 月视图网格 + 左右翻历史月份 + 当日记录列表 + 记录详情与管理

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
