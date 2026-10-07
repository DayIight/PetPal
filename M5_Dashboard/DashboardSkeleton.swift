import Foundation
import Combine
import CoreData
import SwiftUI

// MARK: - 模型
struct WeightSample: Identifiable, Equatable {
    var id = UUID()
    var petID: UUID
    var kg: Double                      // 0.1...100.0
    var date: Date
    var sourceRecordID: UUID?
}

/// 体重合法范围（Stepper 由 in: 钳制；TextField 直接输入的越界值由保存侧用本校验拦截）
enum WeightValidator {
    static let kgRange: ClosedRange<Double> = 0.1...100.0
    static func isValid(_ kg: Double) -> Bool { kgRange.contains(kg) }
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
    func update(_ sample: WeightSample) throws
    func delete(id: UUID) throws
}
extension WeightRepository {
    func update(_ sample: WeightSample) throws { throw DataStoreError.missingItem }
    func delete(id: UUID) throws { throw DataStoreError.missingItem }
}

extension Notification.Name { static let weightsDidChange = Notification.Name("PetPal.weightsDidChange") }

/// GAP-07：体检记录 → 体重样本的纯函数抽取（key 与 RecordKind.checkup 模板字段一致）
enum WeightExtraction {
    static let checkupWeightKey = "weightKg"
    static func sample(from record: Record) -> WeightSample? {
        guard record.kind == .checkup,
              let raw = record.answers[checkupWeightKey],
              let kg = Double(raw), WeightValidator.isValid(kg) else { return nil }
        return WeightSample(petID: record.petID, kg: kg, date: record.createdAt, sourceRecordID: record.id)
    }
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
            WeightSample(id: $0.id ?? UUID(), petID: $0.petID ?? UUID(), kg: $0.kg, date: $0.date ?? Date(), sourceRecordID: $0.sourceRecordID)
        }
    }
    private func validate(_ sample: WeightSample) throws {
        guard WeightValidator.isValid(sample.kg), sample.date <= Date() else {
            throw NSError(domain: "PetPal.Weight", code: 1, userInfo: [NSLocalizedDescriptionKey: "体重需在0.1–100kg之间，日期不能晚于今天"])
        }
        guard sample.sourceRecordID == nil else { throw linkedError }
    }
    private var linkedError: NSError { NSError(domain: "PetPal.Weight", code: 2, userInfo: [NSLocalizedDescriptionKey: "体检体重请在来源记录中修改或删除"])}
    private func find(_ id: UUID) throws -> CDWeightSample? {
        let request = CDWeightSample.fetchRequest(); request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return try ctx.fetch(request).first
    }
    private func changed() {
        NotificationCenter.default.post(name: .weightsDidChange, object: nil)
        NotificationCenter.default.post(name: .petsDidChange, object: nil)
    }
    func add(_ s: WeightSample) throws {
        try validate(s)
        let e = stack.insert(CDWeightSample.self)
        e.id = s.id; e.petID = s.petID; e.kg = s.kg; e.date = s.date
        try stack.save(); changed()
    }
    func update(_ s: WeightSample) throws {
        try validate(s)
        guard let e = try find(s.id), e.petID == s.petID else { throw DataStoreError.missingItem }
        guard e.sourceRecordID == nil else { throw linkedError }
        e.kg = s.kg; e.date = s.date
        try stack.save(); changed()
    }
    func delete(id: UUID) throws {
        guard let e = try find(id) else { throw DataStoreError.missingItem }
        guard e.sourceRecordID == nil else { throw linkedError }
        ctx.delete(e); try stack.save(); changed()
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
    private var bag = Set<AnyCancellable>()
    init(repo: WeightRepository, names: [UUID: String]) {
        self.repo = repo; self.names = names
        selectedPetIDs = Set(names.keys)
        rebuild()
        // 体检抽取/记体重等写入后广播，看板原地重建（与 pets/records 广播模式一致）
        NotificationCenter.default.publisher(for: .weightsDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &bag)
    }
    func togglePet(_ id: UUID) {
        selectedPetIDs.formSymmetricDifference([id])
    }
    private func rebuild() {
        let samples = selectedPetIDs.flatMap { (try? repo.samples(petID: $0)) ?? [] }
        series = ChartSeriesBuilder.series(samples: samples, names: names, granularity: granularity)
    }
}

/// 旧版抽取保留了记录的准确时间；只有唯一匹配时才补来源，避免占用手录数据。
enum HealthDataMigration {
    private struct Key: Hashable { let petID: UUID; let date: Date; let kg: Double }
    static func linkLegacyWeights(in context: NSManagedObjectContext) throws {
        let records = try context.fetch(CDRecord.fetchRequest()).filter { $0.kind == RecordKind.checkup.rawValue }
        let samples = try context.fetch(CDWeightSample.fetchRequest())
        func key(_ record: CDRecord) -> Key? {
            guard let petID = record.petID, let date = record.createdAt,
                  let raw = record.answers?[WeightExtraction.checkupWeightKey], let kg = Double(raw), WeightValidator.isValid(kg) else { return nil }
            return Key(petID: petID, date: date, kg: kg)
        }
        let eligible = records.compactMap { r in key(r).map { ($0, r) } }
        let grouped = Dictionary(grouping: eligible, by: { $0.0 })
        var linkedRecordIDs = Set(samples.compactMap(\.sourceRecordID))
        var candidatesByKey: [Key: [CDWeightSample]] = [:]
        for sample in samples where sample.sourceRecordID == nil {
            guard let petID = sample.petID, let date = sample.date, WeightValidator.isValid(sample.kg) else { continue }
            candidatesByKey[Key(petID: petID, date: date, kg: sample.kg), default: []].append(sample)
        }
        for (key, matches) in grouped where matches.count == 1 {
            let record = matches[0].1
            guard let id = record.id, !linkedRecordIDs.contains(id),
                  let candidates = candidatesByKey[key], candidates.count == 1 else { continue }
            candidates[0].sourceRecordID = id
            linkedRecordIDs.insert(id)
        }
    }
}
