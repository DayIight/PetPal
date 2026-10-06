import XCTest
import Combine
@testable import PetPal

final class ChartSeriesBuilderTests: XCTestCase {
    private let cal = Calendar.current
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    func test_sameMonthSamples_areAveraged() {
        let pet = UUID()
        let samples = [
            WeightSample(petID: pet, kg: 8.0, date: date(2026, 3, 2)),
            WeightSample(petID: pet, kg: 9.0, date: date(2026, 3, 20)),
            WeightSample(petID: pet, kg: 8.4, date: date(2026, 4, 1)),
        ]
        let series = ChartSeriesBuilder.series(samples: samples, names: [pet: "小白"], granularity: .month)
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series[0].points.count, 2)
        XCTAssertEqual(series[0].points[0].label, "2026-03")
        XCTAssertEqual(series[0].points[0].kg, 8.5, accuracy: 0.001)
        XCTAssertEqual(series[0].points[1].label, "2026-04")
    }
    func test_yearGranularity_mergesMonths() {
        let pet = UUID()
        let samples = [
            WeightSample(petID: pet, kg: 8.0, date: date(2025, 6, 1)),
            WeightSample(petID: pet, kg: 10.0, date: date(2025, 12, 1)),
            WeightSample(petID: pet, kg: 9.0, date: date(2026, 1, 1)),
        ]
        let points = ChartSeriesBuilder.series(samples: samples, names: [pet: "小白"],
                                               granularity: .year)[0].points
        XCTAssertEqual(points.map(\.label), ["2025", "2026"])
        XCTAssertEqual(points[0].kg, 9.0, accuracy: 0.001)
    }
    func test_multiPet_seriesGetDistinctColors() {
        let a = UUID(), b = UUID()
        let samples = [WeightSample(petID: a, kg: 8, date: date(2026, 3, 1)),
                       WeightSample(petID: b, kg: 5, date: date(2026, 3, 1))]
        let series = ChartSeriesBuilder.series(samples: samples,
                                               names: [a: "小白", b: "豆豆"], granularity: .month)
        XCTAssertEqual(series.count, 2)
        XCTAssertNotEqual(series[0].colorIndex, series[1].colorIndex)
    }
    func test_yDomain_padsAndHandlesEmpty() {
        let pet = UUID()
        let single = ChartSeriesBuilder.series(
            samples: [WeightSample(petID: pet, kg: 8.5, date: date(2026, 3, 1))],
            names: [pet: "小白"], granularity: .month)
        XCTAssertEqual(ChartSeriesBuilder.yDomain(series: single), 8.0...9.0)
        XCTAssertEqual(ChartSeriesBuilder.yDomain(series: []), 0...1)
    }
}

// MARK: - DashboardViewModel（选择集/粒度变更 → 序列重建）
final class DashboardViewModelTests: XCTestCase {
    @MainActor private func makeVM() throws -> (DashboardViewModel, UUID, UUID) {
        let repo = CoreDataWeightRepository(stack: CoreDataStack(inMemory: true))
        let a = UUID(), b = UUID()
        try repo.add(WeightSample(petID: a, kg: 8.5, date: Date()))
        try repo.add(WeightSample(petID: b, kg: 4.2, date: Date()))
        return (DashboardViewModel(repo: repo, names: [a: "小白", b: "豆豆"]), a, b)
    }
    @MainActor func test_togglePet_excludesItsSeries() throws {
        let (vm, a, _) = try makeVM()
        XCTAssertEqual(vm.series.count, 2)          // 默认全选
        vm.togglePet(a)
        XCTAssertEqual(vm.series.count, 1)
        XCTAssertNotEqual(vm.series.first?.id, a)
    }
    @MainActor func test_switchGranularity_rebuildsBuckets() throws {
        let repo = CoreDataWeightRepository(stack: CoreDataStack(inMemory: true))
        let a = UUID()
        let cal = Calendar.current
        try repo.add(WeightSample(petID: a, kg: 8.0,
                                  date: cal.date(from: DateComponents(year: 2026, month: 3, day: 1))!))
        try repo.add(WeightSample(petID: a, kg: 9.0,
                                  date: cal.date(from: DateComponents(year: 2026, month: 4, day: 1))!))
        let vm = DashboardViewModel(repo: repo, names: [a: "小白"])
        XCTAssertEqual(vm.series.first?.points.count, 2)   // 按月：两桶
        vm.granularity = .year
        XCTAssertEqual(vm.series.first?.points.count, 1)   // 按年：合并
        XCTAssertEqual(vm.series.first?.points.first?.kg ?? 0, 8.5, accuracy: 0.001)
    }
}

final class CoreDataWeightRepositoryTests: XCTestCase {
    func test_addAndQueryPerPet() throws {
        let repo = CoreDataWeightRepository(stack: CoreDataStack(inMemory: true))
        let a = UUID(), b = UUID()
        try repo.add(WeightSample(petID: a, kg: 8.5, date: Date()))
        try repo.add(WeightSample(petID: b, kg: 4.2, date: Date()))
        XCTAssertEqual(try repo.samples(petID: a).count, 1)
        XCTAssertEqual(try repo.samples(petID: a).first?.kg, 8.5)
    }
}

final class WeightValidatorTests: XCTestCase {
    func test_kgRange_boundaries() {
        XCTAssertTrue(WeightValidator.isValid(0.1))
        XCTAssertTrue(WeightValidator.isValid(100.0))
        XCTAssertTrue(WeightValidator.isValid(12.5))
        XCTAssertFalse(WeightValidator.isValid(0.09))
        XCTAssertFalse(WeightValidator.isValid(100.1))
        XCTAssertFalse(WeightValidator.isValid(0))
        XCTAssertFalse(WeightValidator.isValid(-5))
    }
}

// MARK: - GAP-07：体检记录 → 体重样本抽取
final class WeightExtractionTests: XCTestCase {
    func test_checkupWithWeight_extractsSample() {
        let pet = UUID()
        let r = PetPal.Record(petID: pet, kind: .checkup, answers: ["weightKg": "8.5"])
        let sample = WeightExtraction.sample(from: r)
        XCTAssertEqual(sample?.petID, pet)
        XCTAssertEqual(sample?.kg ?? 0, 8.5, accuracy: 0.001)
        XCTAssertEqual(sample?.date, r.createdAt)
    }
    func test_nonCheckupKind_returnsNil() {
        let r = PetPal.Record(petID: UUID(), kind: .feeding, answers: ["weightKg": "8.5"])
        XCTAssertNil(WeightExtraction.sample(from: r))
    }
    func test_invalidOrOutOfRangeWeight_returnsNil() {
        let pet = UUID()
        for raw in ["", "abc", "0", "100.1"] {
            let r = PetPal.Record(petID: pet, kind: .checkup, answers: ["weightKg": raw])
            XCTAssertNil(WeightExtraction.sample(from: r), "「\(raw)」不应被抽取")
        }
    }
    // 体检模板必须携带 weightKg 字段（抽取 key 与模板字段一致，防漂移）
    func test_checkupTemplate_hasWeightField() {
        XCTAssertTrue(RecordKind.checkup.fields.contains {
            $0.key == WeightExtraction.checkupWeightKey && !$0.isRequired
        })
    }
}

// MARK: - GAP-07 集成：表单保存体检记录 → WeightRepository 写入；编辑重存去重
final class CheckupWeightIntegrationTests: XCTestCase {
    @MainActor func test_checkupSave_writesWeightSample_oncePerSameValue() throws {
        let stack = CoreDataStack(inMemory: true)
        let recordRepo = CoreDataRecordRepository(stack: stack)
        let weightRepo = CoreDataWeightRepository(stack: stack)
        let pet = UUID()
        let vm = RecordFormViewModel(repo: recordRepo, petID: pet, kind: .checkup,
                                     weightRepo: weightRepo)
        vm.draft.answers = ["hospital": "安心宠物医院", "weightKg": "8.5"]
        XCTAssertTrue(vm.save())
        XCTAssertEqual(try weightRepo.samples(petID: pet).count, 1)
        XCTAssertEqual(try weightRepo.samples(petID: pet).first?.kg ?? 0, 8.5, accuracy: 0.001)

        // 编辑该记录重存：同日同值不重复抽取
        var records: [PetPal.Record] = []
        var bag = Set<AnyCancellable>()
        recordRepo.recordsPublisher(petID: pet).sink { records = $0 }.store(in: &bag)
        let editVM = RecordFormViewModel(repo: recordRepo, editing: records.first!, weightRepo: weightRepo)
        XCTAssertTrue(editVM.save())
        XCTAssertEqual(try weightRepo.samples(petID: pet).count, 1, "编辑重存不应产生重复体重点")
        _ = bag
    }

    // 非体检记录即使带 weightKg 也不抽取（走 save 全链路）
    @MainActor func test_feedingSave_doesNotExtractWeight() throws {
        let stack = CoreDataStack(inMemory: true)
        let weightRepo = CoreDataWeightRepository(stack: stack)
        let pet = UUID()
        let vm = RecordFormViewModel(repo: CoreDataRecordRepository(stack: stack),
                                     petID: pet, kind: .feeding, weightRepo: weightRepo)
        vm.draft.answers = ["food": "处方粮", "grams": "80", "mealTime": "早"]
        XCTAssertTrue(vm.save())
        XCTAssertTrue(try weightRepo.samples(petID: pet).isEmpty)
    }
}

// MARK: - weightsDidChange 广播 → 看板 VM 原地重建（体检抽取后看板无需重进）
final class DashboardWeightsDidChangeTests: XCTestCase {
    @MainActor func test_addSample_broadcastsAndRebuilds() throws {
        let repo = CoreDataWeightRepository(stack: CoreDataStack(inMemory: true))
        let pet = UUID()
        let vm = DashboardViewModel(repo: repo, names: [pet: "小白"])
        XCTAssertTrue(vm.series.flatMap(\.points).isEmpty)
        try repo.add(WeightSample(petID: pet, kg: 8, date: Date()))
        let drained = expectation(description: "main 队列投递完成")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertEqual(vm.series.flatMap(\.points).count, 1)
    }
}
