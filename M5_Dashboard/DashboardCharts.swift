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
