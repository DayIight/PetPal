import XCTest
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
