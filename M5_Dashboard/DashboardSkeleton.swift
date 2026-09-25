import Foundation
import CoreData
import SwiftUI

// MARK: - 模型
struct WeightSample: Identifiable, Equatable {
    var id = UUID()
    var petID: UUID
    var kg: Double                      // 0.1...100.0
    var date: Date
}

enum Granularity: String, CaseIterable, Identifiable {
    case month = "按月", year = "按年"
    var id: String { rawValue }
}

struct ChartPoint: Equatable {
    var label: String                   // "2026-03" 或 "2026"
    var kg: Double
    var date: Date                      // 桶起始日，X 轴定位与排序依据
}

struct ChartSeries: Identifiable, Equatable {
    var id: UUID                        // petID
    var petName: String
    var colorIndex: Int                 // 经 ChartPalette 取模，保证同屏不同色
    var points: [ChartPoint]
}

// MARK: - 聚合（纯函数：分桶均值 + 自适应 Y 域）
enum ChartSeriesBuilder {
    private struct BucketKey: Hashable {
        let label: String
        let start: Date
    }

    static func series(samples: [WeightSample], names: [UUID: String],
                       granularity: Granularity) -> [ChartSeries] {
        let grouped = Dictionary(grouping: samples, by: \.petID)
        let sortedGroups = grouped.sorted {
            (names[$0.key] ?? "") < (names[$1.key] ?? "")
        }
        var result: [ChartSeries] = []
        for (index, entry) in sortedGroups.enumerated() {
            let buckets = Dictionary(grouping: entry.value) { sample in
                bucketKey(sample.date, granularity)
            }
            var points: [ChartPoint] = []
            for (key, values) in buckets {
                let total = values.reduce(0.0) { $0 + $1.kg }
                points.append(ChartPoint(label: key.label, kg: total / Double(values.count),
                                         date: key.start))
            }
            points.sort { $0.date < $1.date }
            result.append(ChartSeries(id: entry.key, petName: names[entry.key] ?? "未知",
                                      colorIndex: index, points: points))
        }
        return result
    }
    static func yDomain(series: [ChartSeries]) -> ClosedRange<Double> {
        let all = series.flatMap(\.points).map(\.kg)
        guard let lo = all.min(), let hi = all.max() else { return 0...1 }
        let pad = max((hi - lo) * 0.1, 0.5)
        return max(0, lo - pad)...(hi + pad)
    }
    private static func bucketKey(_ date: Date, _ g: Granularity) -> BucketKey {
        let cal = Calendar.current
        let comps = cal.dateComponents(g == .month ? [.year, .month] : [.year], from: date)
        let label = g == .month
            ? String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
            : String(comps.year ?? 0)
        return BucketKey(label: label, start: cal.date(from: comps) ?? date)
    }
}

// MARK: - 配色（仅用于曲线区分；文本仍用语义化颜色）
enum ChartPalette {
    static let colors: [Color] = [.accentColor, .orange, .green, .purple, .pink, .teal]
    static func color(_ index: Int) -> Color { colors[index % colors.count] }
}

// MARK: - 存储边界（CDWeightSample：id/petID UUID、kg Double、date Date）
protocol WeightRepository: AnyObject {
    func samples(petID: UUID) throws -> [WeightSample]
    func add(_ sample: WeightSample) throws
}

final class CoreDataWeightRepository: WeightRepository {
    private let stack: CoreDataStack
    init(stack: CoreDataStack = .shared) { self.stack = stack }
    private var ctx: NSManagedObjectContext { stack.container.viewContext }
    func samples(petID: UUID) throws -> [WeightSample] {
        let r = CDWeightSample.fetchRequest()
        r.predicate = NSPredicate(format: "petID == %@", petID as CVarArg)
        r.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
        return try ctx.fetch(r).map {
            WeightSample(id: $0.id ?? UUID(), petID: $0.petID ?? UUID(), kg: $0.kg, date: $0.date ?? Date())
        }
    }
    func add(_ s: WeightSample) throws {
        let e = stack.insert(CDWeightSample.self)
        e.id = s.id; e.petID = s.petID; e.kg = s.kg; e.date = s.date
        try ctx.save()
    }
}

// MARK: - ViewModel（粒度/宠物选择变更 → 同步重建序列）
@MainActor final class DashboardViewModel: ObservableObject {
    @Published var granularity: Granularity = .month { didSet { rebuild() } }
    @Published var selectedPetIDs: Set<UUID> = [] { didSet { rebuild() } }
    @Published private(set) var series: [ChartSeries] = []
    var yDomain: ClosedRange<Double> { ChartSeriesBuilder.yDomain(series: series) }
    private let repo: WeightRepository
    private let names: [UUID: String]
    init(repo: WeightRepository, names: [UUID: String]) {
        self.repo = repo; self.names = names
        selectedPetIDs = Set(names.keys)
        rebuild()
    }
    func togglePet(_ id: UUID) {
        selectedPetIDs.formSymmetricDifference([id])
    }
    private func rebuild() {
        let samples = selectedPetIDs.flatMap { (try? repo.samples(petID: $0)) ?? [] }
        series = ChartSeriesBuilder.series(samples: samples, names: names, granularity: granularity)
    }
}
