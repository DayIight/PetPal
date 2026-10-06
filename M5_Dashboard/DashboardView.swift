import SwiftUI
import Charts
import Combine
import UIKit

// MARK: - answers 内嵌日期的容错解析
// 历史数据无统一写入方（M2 记录表单尚未实现 date 字段 UI，answers 中日期尚无落盘代码），
// 无统一存储格式；此处按 ISO8601 → yyyy-MM-dd 顺序容错解析，均失败视为无日期。
enum RecordAnswerDate {
    static func parse(_ raw: String) -> Date? {
        if let d = ISO8601DateFormatter().date(from: raw) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: raw)
    }
    /// 展示用：yyyy年M月d日
    static let display: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy年M月d日"
        return f
    }()
    /// 表格/PDF 用：yyyy-MM-dd
    static let table: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - 月度打卡热力图（按 createdAt 统计每日记录数）
@MainActor final class CheckinHeatmapModel: ObservableObject {
    @Published private(set) var counts: [Date: Int] = [:]   // startOfDay → 当日记录数
    @Published private(set) var months: [Date] = []         // 每月 1 日，升序
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

    private func apply(_ records: [Record]) {
        let cal = Calendar.current
        var counts: [Date: Int] = [:]
        for r in records {
            counts[cal.startOfDay(for: r.createdAt), default: 0] += 1
        }
        self.counts = counts
        let thisMonth = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        if let earliest = records.map(\.createdAt).min() {
            var first = cal.date(from: cal.dateComponents([.year, .month], from: earliest))!
            // 历史月份上限 24 个，超出截断到最近 24 个月
            if let limit = cal.date(byAdding: .month, value: -23, to: thisMonth), first < limit {
                first = limit
            }
            var result: [Date] = []
            var cursor = first
            while cursor <= thisMonth {
                result.append(cursor)
                cursor = cal.date(byAdding: .month, value: 1, to: cursor)!
            }
            months = result
        } else {
            months = [thisMonth]
        }
        if !months.contains(where: { cal.isDate($0, equalTo: selectedMonth, toGranularity: .month) }) {
            selectedMonth = months.last ?? thisMonth
        }
    }
}

// MARK: - 疫苗/体检时间线
struct HealthEvent: Identifiable {
    enum Status: String {
        case done = "已完成", pending = "待进行", overdue = "已过期"
    }
    let id: UUID
    let title: String
    let detail: String
    let date: Date
    let status: Status
}

@MainActor final class HealthTimelineModel: ObservableObject {
    @Published private(set) var events: [HealthEvent] = []
    private var bag = Set<AnyCancellable>()
    // 必须持有 repo：repo deinit 会移除 recordsDidChange 观察者，广播链路随之断开
    private let repo: RecordRepository

    init(repo: RecordRepository, petID: UUID) {
        self.repo = repo
        repo.recordsPublisher(petID: petID).receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.apply($0) }
            .store(in: &bag)
    }

    private func apply(_ records: [Record]) {
        events = records
            .filter { $0.kind == .vaccine || $0.kind == .checkup }
            .sorted { $0.createdAt < $1.createdAt }   // 时间正序
            .map(HealthEvent.init)
    }
}

private extension HealthEvent {
    init(_ r: Record) {
        id = r.id
        let isVaccine = r.kind == .vaccine
        title = isVaccine ? (r.answers["vaccineName"] ?? "疫苗接种") : "体检"
        var parts: [String] = []
        if let hospital = r.answers["hospital"], !hospital.isEmpty { parts.append(hospital) }
        if !isVaccine, let conclusion = r.answers["conclusion"], !conclusion.isEmpty {
            parts.append(conclusion)
        }
        detail = parts.joined(separator: " · ")
        date = r.createdAt
        // 状态判定：有 nextDue 且早于今天 → 已过期；nextDue 在未来 → 待进行；无 nextDue → 已完成
        if let nextDue = r.answers["nextDue"].flatMap(RecordAnswerDate.parse) {
            status = nextDue < Calendar.current.startOfDay(for: Date()) ? .overdue : .pending
        } else {
            status = .done
        }
    }
}

// MARK: - 主视图：体重曲线 + 打卡热力图 + 健康时间线 + PDF 导出
struct DashboardView: View {
    let pet: Pet
    let pets: [Pet]
    @StateObject private var vm: DashboardViewModel
    @StateObject private var heatmap: CheckinHeatmapModel
    @StateObject private var timeline: HealthTimelineModel
    private let weightRepo: WeightRepository
    @State private var shareItem: PDFShareItem?
    @State private var showSpaceAlert = false
    @State private var exportError: String?

    init(pet: Pet, pets: [Pet]) {
        self.pet = pet
        self.pets = pets
        let all = pets.isEmpty ? [pet] : pets
        let names = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.nickname) })
        let weightRepo = CoreDataWeightRepository()
        self.weightRepo = weightRepo
        _vm = StateObject(wrappedValue: DashboardViewModel(repo: weightRepo, names: names))
        let recordRepo = CoreDataRecordRepository()
        _heatmap = StateObject(wrappedValue: CheckinHeatmapModel(repo: recordRepo, petID: pet.id))
        _timeline = StateObject(wrappedValue: HealthTimelineModel(repo: recordRepo, petID: pet.id))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Spacing.lg) {
                    chartSection
                    heatmapSection
                    timelineSection
                }
                .padding(DS.Spacing.md)
            }
            .background(Color.pageBackground)
            .navigationTitle("成长看板")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("导出PDF", action: exportPDF)
                        .a11y("导出PDF", hint: "生成\(pet.nickname)的成长报告并打开分享面板")
                        .accessibilityIdentifier("dashboard.exportPDF")
                }
            }
            .sheet(item: $shareItem) { item in
                DashboardPDFPreview(url: item.url)
            }
            .alert("存储空间不足", isPresented: $showSpaceAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text("可用存储空间不足，无法生成PDF。请先清理空间后重试。")
            }
            .alert("导出失败", isPresented: .init(get: { exportError != nil },
                                                  set: { if !$0 { exportError = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(exportError ?? "请重试")
            }
        }
    }

    // MARK: ① 体重折线图
    private var chartSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                HStack {
                    Text("体重变化").font(.headline)
                    Spacer()
                    Picker("统计粒度", selection: $vm.granularity) {
                        ForEach(Granularity.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                    .a11y("统计粒度", hint: "按月或按年聚合体重数据")
                    .accessibilityIdentifier("dashboard.granularity")
                }
                if pets.count > 1 { petChips }
                if vm.series.contains(where: { !$0.points.isEmpty }) {
                    WeightLineChart(vm: vm)
                        .frame(height: 220)
                        .accessibilityIdentifier("dashboard.chart")
                    legend
                } else {
                    Text("还没有体重数据，记录后将在这里展示变化曲线")
                        .font(.body).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .accessibilityIdentifier("dashboard.chartEmpty")
                }
            }
        }
    }

    /// 多宠物叠加选择 chips
    private var petChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.sm) {
                ForEach(pets) { p in
                    let selected = vm.selectedPetIDs.contains(p.id)
                    Button {
                        vm.togglePet(p.id)
                    } label: {
                        Text(p.nickname)
                            .font(.body)
                            .padding(.horizontal, DS.Spacing.md)
                            .padding(.vertical, DS.Spacing.xs)
                            .background(
                                Capsule().fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary.opacity(0.15)))
                            )
                            .foregroundStyle(selected ? Color.white : Color.primary)
                    }
                    .a11y("叠加\(p.nickname)的体重曲线",
                          hint: selected ? "当前已叠加，再次点击取消" : "当前未叠加，点击加入曲线")
                    .accessibilityIdentifier("dashboard.petChip.\(p.nickname)")
                }
            }
        }
    }

    /// 图例：颜色点 + 昵称
    private var legend: some View {
        HStack(spacing: DS.Spacing.md) {
            ForEach(vm.series) { s in
                HStack(spacing: DS.Spacing.xs) {
                    Circle().fill(ChartPalette.color(s.colorIndex)).frame(width: 10, height: 10)
                    Text(s.petName).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(s.petName)：\(ChartPalette.color(s.colorIndex) == .accentColor ? "主题色" : "彩色")曲线")
            }
            Spacer()
        }
        .accessibilityHidden(vm.series.count <= 1)   // 单宠时图例对 VoiceOver 是噪音
    }

    // MARK: ② 月度打卡热力图
    private var heatmapSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                Text("月度打卡").font(.headline)
                    .accessibilityIdentifier("dashboard.heatmap")
                Text("左右滑动查看历史月份").font(.caption).foregroundStyle(.secondary)
                TabView(selection: $heatmap.selectedMonth) {
                    ForEach(heatmap.months, id: \.self) { month in
                        MonthGrid(month: month, counts: heatmap.counts)
                            .tag(month)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 320)
            }
        }
    }

    // MARK: ③ 疫苗/体检时间线
    private var timelineSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                Text("疫苗与体检").font(.headline)
                    .accessibilityIdentifier("dashboard.timeline")
                if timeline.events.isEmpty {
                    Text("暂无疫苗或体检记录")
                        .font(.body).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .accessibilityIdentifier("dashboard.timelineEmpty")
                } else {
                    VStack(spacing: DS.Spacing.sm) {
                        ForEach(timeline.events) { event in
                            timelineRow(event)
                        }
                    }
                }
            }
        }
    }

    private func timelineRow(_ event: HealthEvent) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(event.title).font(.body)
                if !event.detail.isEmpty {
                    Text(event.detail).font(.caption).foregroundStyle(.secondary)
                }
                Text(event.date, formatter: RecordAnswerDate.display)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: DS.Spacing.sm)
            Text(event.status.rawValue)
                .font(.caption)
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, DS.Spacing.xs)
                .background(Capsule().fill(statusColor(event.status).opacity(0.15)))
                .foregroundStyle(statusColor(event.status))
                .accessibilityLabel("状态：\(event.status.rawValue)")
        }
        .padding(DS.Spacing.sm)
        .background(Color.groupedBackground,
                    in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
    }

    private func statusColor(_ status: HealthEvent.Status) -> Color {
        switch status {
        case .overdue: return .red
        case .pending: return .orange
        case .done: return .green
        }
    }

    // MARK: ④ PDF 导出
    private func exportPDF() {
        guard DashboardPDFBuilder.hasEnoughSpace() else {
            showSpaceAlert = true
            return
        }
        let names = Dictionary(uniqueKeysWithValues: (pets.isEmpty ? [pet] : pets).map { ($0.id, $0.nickname) })
        let samples = vm.selectedPetIDs
            .flatMap { (try? weightRepo.samples(petID: $0)) ?? [] }
            .sorted { $0.date > $1.date }
        let image = chartSnapshot()
        do {
            let url = try DashboardPDFBuilder.makeDocument(
                pet: pet, names: names, samples: samples, chartImage: image)
            shareItem = PDFShareItem(url: url)
        } catch {
            exportError = error.localizedDescription
        }
    }

    /// 用 ImageRenderer 将折线图渲染为位图嵌入 PDF 第二页
    @MainActor private func chartSnapshot() -> UIImage {
        let content = WeightLineChart(vm: vm)
            .frame(width: 540, height: 260)
            .padding(DS.Spacing.md)
            .background(Color.white)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        return renderer.uiImage ?? UIImage()
    }
}

// MARK: - 折线图（Swift Charts）
struct WeightLineChart: View {
    @ObservedObject var vm: DashboardViewModel
    var body: some View {
        Chart {
            ForEach(vm.series) { s in
                let color = ChartPalette.color(s.colorIndex)
                ForEach(s.points, id: \.date) { p in
                    LineMark(x: .value("时间", p.date), y: .value("体重", p.kg))
                        .foregroundStyle(color)
                        .interpolationMethod(.catmullRom)
                    PointMark(x: .value("时间", p.date), y: .value("体重", p.kg))
                        .foregroundStyle(color)
                        .symbolSize(24)
                }
            }
        }
        .chartYScale(domain: vm.yDomain)
        // 整图描述（AXChartDescriptor），避免逐点朗读打断 VoiceOver 流程
        .accessibilityChartDescriptor(
            WeightChartDescriptor(series: vm.series, granularity: vm.granularity))
    }
}

/// 整图无障碍描述载体（iOS 16 SDK 仅提供 representable 重载）
struct WeightChartDescriptor: AXChartDescriptorRepresentable {
    let series: [ChartSeries]
    let granularity: Granularity

    func makeChartDescriptor() -> AXChartDescriptor {
        let labels = series.flatMap(\.points).map(\.label)
            .reduce(into: [String]()) { $0.contains($1) ? () : $0.append($1) }
            .sorted()
        return AXChartDescriptor(
            title: "体重变化图",
            summary: "所选宠物按\(granularity == .month ? "月" : "年")聚合的平均体重曲线",
            xAxis: AXCategoricalDataAxisDescriptor(title: "时间", categoryOrder: labels),
            yAxis: AXNumericDataAxisDescriptor(
                title: "体重",
                range: 0...max(1, series.flatMap(\.points).map(\.kg).max() ?? 1),
                gridlinePositions: []) { value in "\(Int(value))公斤" },
            additionalAxes: [],
            series: series.map { s in
                AXDataSeriesDescriptor(
                    name: s.petName,
                    isContinuous: false,
                    dataPoints: s.points.map { AXDataPoint(x: $0.label, y: $0.kg) })
            })
    }
}

// MARK: - 月历网格
struct MonthGrid: View {
    let month: Date          // 该月 1 日
    let counts: [Date: Int]  // startOfDay → 当日记录数
    private let weekdays = ["一", "二", "三", "四", "五", "六", "日"]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: DS.Spacing.xs), count: 7)

    var body: some View {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: month)
        let daysInMonth = cal.range(of: .day, in: .month, for: month)!.count
        // 周一为一周起点：offset = (首个日期的 weekday + 5) % 7（Sunday=1 ... Saturday=7）
        let firstWeekday = cal.dateComponents([.weekday], from: month).weekday ?? 2
        let leading = (firstWeekday + 5) % 7

        return VStack(spacing: DS.Spacing.sm) {
            Text("\(comps.year ?? 0)年\(comps.month ?? 0)月")
                .font(.headline)
            LazyVGrid(columns: columns, spacing: DS.Spacing.xs) {
                ForEach(weekdays, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                ForEach(0..<leading, id: \.self) { _ in Color.clear }
                ForEach(1...daysInMonth, id: \.self) { day in
                    let date = cal.date(from: DateComponents(year: comps.year, month: comps.month, day: day))!
                    let count = counts[cal.startOfDay(for: date)] ?? 0
                    Text(count > 0 ? "\(count)" : "")
                        .font(.caption2)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                                .fill(cellColor(count))
                        )
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(comps.month ?? 0)月\(day)日，\(count)次打卡")
                }
            }
        }
    }

    /// 5 档颜色：0 次=透明灰底；1/2/3/4+ 递增主题色透明度
    private func cellColor(_ count: Int) -> Color {
        switch min(count, 4) {
        case 0: return Color.secondary.opacity(0.08)
        case 1: return Color.accentColor.opacity(0.25)
        case 2: return Color.accentColor.opacity(0.45)
        case 3: return Color.accentColor.opacity(0.7)
        default: return Color.accentColor.opacity(0.95)
        }
    }
}

// MARK: - PDF 分享载体
struct PDFShareItem: Identifiable {
    let id = UUID()
    let url: URL
}
