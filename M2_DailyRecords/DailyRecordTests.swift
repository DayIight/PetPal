import XCTest
import Combine
@testable import PetPal

final class RecordValidatorTests: XCTestCase {
    private func feeding() -> PetPal.Record {
        PetPal.Record(petID: UUID(), kind: .feeding,
                      answers: ["food": "处方粮", "grams": "80", "mealTime": "早"])
    }
    func test_missingRequiredField_rejected() {
        var r = feeding(); r.answers["grams"] = ""
        XCTAssertTrue(RecordValidator.errors(for: r).contains { $0.contains("克数") })
    }
    func test_noteOver200_rejected() {
        var r = feeding(); r.note = String(repeating: "字", count: 201)
        XCTAssertFalse(RecordValidator.errors(for: r).isEmpty)
    }
    func test_tenPhotos_rejected() {
        var r = feeding(); r.photoFileNames = (1...10).map { "\($0).jpg" }
        XCTAssertFalse(RecordValidator.errors(for: r).isEmpty)
    }
    func test_validFeeding_passes() {
        XCTAssertTrue(RecordValidator.errors(for: feeding()).isEmpty)
    }
    // M-02：number 字段类型与范围校验
    func test_nonNumericNumberField_rejected() {
        var r = feeding(); r.answers["grams"] = "abc"
        XCTAssertTrue(RecordValidator.errors(for: r).contains { $0.contains("克数") && $0.contains("数字") })
    }
    func test_outOfRangeNumberField_rejected() {
        var r = feeding(); r.answers["grams"] = "999999"
        XCTAssertFalse(RecordValidator.errors(for: r).isEmpty)
        r.answers["grams"] = "0"
        XCTAssertFalse(RecordValidator.errors(for: r).isEmpty)
    }
    func test_optionalNumberFieldEmpty_passes() {
        // 遛弯时长为选填：留空不报错，填非法值才报错
        var r = PetPal.Record(petID: UUID(), kind: .walking, answers: ["minutes": "", "place": ""])
        XCTAssertTrue(RecordValidator.errors(for: r).isEmpty)
        r.answers["minutes"] = "一小时"
        XCTAssertFalse(RecordValidator.errors(for: r).isEmpty)
    }
}

final class TimelineGrouperTests: XCTestCase {
    func test_groupedByDayDesc_thenCreatedAtDesc() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        let a = PetPal.Record(petID: UUID(), createdAt: yesterday.addingTimeInterval(3600))
        let b = PetPal.Record(petID: UUID(), createdAt: today.addingTimeInterval(60))
        let c = PetPal.Record(petID: UUID(), createdAt: today.addingTimeInterval(7200))
        let sections = TimelineGrouper.group([a, b, c])
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].day, today)
        XCTAssertEqual(sections[0].items.map(\.id), [c.id, b.id])
    }
}

// MARK: - 日历月视图（波3新增）
final class CalendarGridBuilderTests: XCTestCase {
    private let cal = Calendar.current
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }
    func test_countsByDay_groupsByCalendarDay() {
        let pet = UUID()
        let records = [
            PetPal.Record(petID: pet, createdAt: date(2026, 3, 5, 8)),
            PetPal.Record(petID: pet, createdAt: date(2026, 3, 5, 20)),
            PetPal.Record(petID: pet, createdAt: date(2026, 3, 7)),
        ]
        let counts = CalendarGridBuilder.countsByDay(records)
        XCTAssertEqual(counts[cal.startOfDay(for: date(2026, 3, 5))], 2)
        XCTAssertEqual(counts[cal.startOfDay(for: date(2026, 3, 7))], 1)
    }
    func test_monthGrid_hasAllDaysAndCarriesCounts() {
        let counts = [cal.startOfDay(for: date(2026, 3, 5)): 2]
        let grid = CalendarGridBuilder.month(containing: date(2026, 3, 15), counts: counts)
        let realDays = grid.filter { $0.date != nil }
        XCTAssertEqual(realDays.count, 31)                       // 3 月 31 天
        XCTAssertEqual(grid.count - realDays.count, grid.prefix { $0.date == nil }.count,
                       "占位格必须全部位于网格开头")
        let day5 = realDays.first { cal.component(.day, from: $0.date!) == 5 }
        XCTAssertEqual(day5?.count, 2)
        let day6 = realDays.first { cal.component(.day, from: $0.date!) == 6 }
        XCTAssertEqual(day6?.count, 0)
    }
    func test_monthOffset_navigation() {
        let prev = CalendarGridBuilder.month(offset: -1, from: date(2026, 3, 15))
        XCTAssertEqual(cal.component(.month, from: prev), 2)
        XCTAssertEqual(cal.component(.year, from: prev), 2026)
    }
}

// MARK: - 自定义模板（波3新增）
final class CustomTemplateRepositoryTests: XCTestCase {
    private var repo: CoreDataCustomTemplateRepository!
    override func setUp() { repo = CoreDataCustomTemplateRepository(stack: CoreDataStack(inMemory: true)) }

    private func template(_ name: String) -> CustomTemplate {
        CustomTemplate(name: name, fields: [
            .init(title: "分量", type: .number, isRequired: true),
            .init(title: "状态", type: .single, options: ["好", "一般", "差"]),
        ])
    }
    func test_saveFetchDelete_roundTrip() throws {
        let t = template("喂药")
        try repo.save(t)
        let all = try repo.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.name, "喂药")
        XCTAssertEqual(all.first?.fields.count, 2)
        try repo.delete(id: t.id)
        XCTAssertTrue(try repo.all().isEmpty)
    }
    func test_limit20_exceededThrows() throws {
        for i in 1...20 { try repo.save(template("模板\(i)")) }
        XCTAssertThrowsError(try repo.save(template("第21个"))) { error in
            XCTAssertEqual(error as? CustomTemplateError, .limitExceeded)
        }
        // 更新已存在的模板不受上限影响
        var existing = try repo.all().first!
        existing.name = "改名"
        XCTAssertNoThrow(try repo.save(existing))
        XCTAssertEqual(try repo.all().first?.name, "改名")
    }
    func test_customRecord_roundTripsWithTemplateName() throws {
        let stack = CoreDataStack(inMemory: true)
        let recordRepo = CoreDataRecordRepository(stack: stack)
        let pet = UUID()
        var r = PetPal.Record(petID: pet, kind: .custom, answers: ["k1": "v1"])
        r.templateName = "喂药"
        try recordRepo.create(r)
        var records: [PetPal.Record] = []
        var bag = Set<AnyCancellable>()
        recordRepo.recordsPublisher(petID: pet).sink { records = $0 }.store(in: &bag)
        XCTAssertEqual(records.first?.kind, .custom)
        XCTAssertEqual(records.first?.templateName, "喂药")
        XCTAssertEqual(records.first?.displayKind, "喂药")
        _ = bag
    }
    func test_validator_withCustomTemplateFields() {
        let t = template("喂药")
        var r = PetPal.Record(petID: UUID(), kind: .custom, answers: [:])
        r.templateName = "喂药"
        let errors = RecordValidator.errors(for: r, fields: t.templateFields)
        XCTAssertTrue(errors.contains { $0.contains("分量") })       // 必填缺失
        r.answers[t.fields[0].id.uuidString] = "-5"
        XCTAssertFalse(RecordValidator.errors(for: r, fields: t.templateFields).isEmpty)  // 越界
        r.answers[t.fields[0].id.uuidString] = "2"
        XCTAssertTrue(RecordValidator.errors(for: r, fields: t.templateFields).isEmpty)
    }
}

final class CoreDataRecordRepositoryTests: XCTestCase {
    private var repo: CoreDataRecordRepository!
    private var bag = Set<AnyCancellable>()
    override func setUp() { repo = CoreDataRecordRepository(stack: CoreDataStack(inMemory: true)) }

    func test_recordsAreIsolatedPerPet() throws {
        let petA = UUID(), petB = UUID()
        try repo.create(PetPal.Record(petID: petA, kind: .feeding))
        try repo.create(PetPal.Record(petID: petB, kind: .walking))
        var aRecords: [PetPal.Record] = []
        repo.recordsPublisher(petID: petA).sink { aRecords = $0 }.store(in: &bag)
        XCTAssertEqual(aRecords.count, 1)
        XCTAssertEqual(aRecords.first?.kind, .feeding)
    }
    func test_delete_emitsUpdate() throws {
        let pet = UUID(); let r = PetPal.Record(petID: pet, kind: .checkup)
        try repo.create(r)
        var records: [PetPal.Record] = []
        repo.recordsPublisher(petID: pet).sink { records = $0 }.store(in: &bag)
        try repo.delete(id: r.id)
        XCTAssertTrue(records.isEmpty)
    }
    // M-01：编辑更新保留原 createdAt 与原位刷新
    func test_update_preservesCreatedAtAndEmits() throws {
        let pet = UUID()
        var r = PetPal.Record(petID: pet, kind: .feeding,
                              answers: ["food": "处方粮", "grams": "80", "mealTime": "早"])
        let originalDate = r.createdAt
        try repo.create(r)
        var records: [PetPal.Record] = []
        repo.recordsPublisher(petID: pet).sink { records = $0 }.store(in: &bag)
        r.answers["grams"] = "100"
        try repo.update(r)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.answers["grams"], "100")
        XCTAssertEqual(records.first?.createdAt, originalDate)
    }
}
