import XCTest
import PDFKit
@testable import PetPal

final class MedicalReportTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Los_Angeles")!; return c }
    private func date(_ day: Int, hour: Int = 12) -> Date { calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour))! }
    func test_rangeIncludesWholeLastDayAcrossDSTAndFiltersPetAndOccurrenceDate() throws {
        let pet = Pet(nickname: "目标", breed: "柯基")
        let range = try ReportDateRange(start: date(7), end: date(8), calendar: calendar)
        XCTAssertTrue(range.contains(date(8, hour: 23))); XCTAssertFalse(range.contains(date(9, hour: 0)))
        XCTAssertFalse(range.contains(date(6, hour: 23)))
        var backfill = Record(petID: pet.id, kind: .vaccine, createdAt: date(10))
        backfill.occurredAt = date(8)
        let report = MedicalReport(pet: pet, range: range,
            weights: [WeightSample(petID: pet.id, kg: 4, date: date(8, hour: 23)), WeightSample(petID: UUID(), kg: 5, date: date(8)), WeightSample(petID: pet.id, kg: 6, date: date(9))],
            records: [backfill, Record(petID: UUID(), kind: .vaccine, occurredAt: date(8)), Record(petID: pet.id, kind: .walking, occurredAt: date(8))])
        XCTAssertEqual(report.records.map(\.id), [backfill.id]); XCTAssertEqual(report.weights.map(\.kg), [4])
        XCTAssertThrowsError(try ReportDateRange(start: date(9), end: date(8)))
        XCTAssertNoThrow(try ReportDateRange(start: date(8, hour: 23), end: date(8, hour: 0), calendar: calendar))
    }
    @MainActor func test_standardReportIncludesAllHealthSectionsAndPlansAreLabeled() throws {
        var pet = Pet(nickname: "奶糖", breed: "柯基", birthday: date(1).addingTimeInterval(-730 * 86400), weightKg: 10.2)
        pet.allergens = ["鸡肉", "花粉"]
        let kinds = MedicalReport.healthKinds
        let records = kinds.map { Record(petID: pet.id, kind: $0, answers: ["vaccineName": "年度疫苗", "hospital": "社区动物医院", "nextDue": "2027-03-08", "drug": "常规药品", "dose": "按本次记录", "conclusion": "状态平稳"], note: "就诊时请核对原始记录。", occurredAt: date(8)) }
        let weights = (0..<8).map { WeightSample(petID: pet.id, kg: 9.5 + Double($0) * 0.1, date: date(1 + $0)) }
        let doc = try document(MedicalReport(pet: pet, weights: weights, records: records, generatedAt: date(10)), name: "report-standard")
        let text = doc.string ?? ""
        for expected in ["奶糖", "鸡肉", "花粉", "疫苗记录", "驱虫记录", "体检记录", "服药记录", "下次计划（未确认完成）", "状态平稳", "10.2 kg"] { XCTAssertTrue(text.contains(expected), expected) }
        XCTAssertLessThanOrEqual(doc.pageCount, 4)
    }
    @MainActor func test_longUnicodeFieldsAndManyWeightsRemainCompleteAcrossPages() throws {
        var pet = Pet(nickname: "长文本/档案", breed: "柯基")
        pet.allergens = [String(repeating: "花粉与尘螨，需要就诊时逐项确认。", count: 120) + "过敏源结束标记"]
        let conclusion = String(repeating: "复查记录：饮食、活动和精神状态已由主人观察并记录。\n", count: 180) + "结论结束标记"
        let record = Record(petID: pet.id, kind: .checkup, answers: ["conclusion": conclusion], occurredAt: date(8))
        let weights = (0..<100).map { WeightSample(petID: pet.id, kg: 10 + Double($0 % 10) / 10, date: date(1).addingTimeInterval(Double($0) * 3600)) }
        let doc = try document(MedicalReport(pet: pet, weights: weights, records: [record]), name: "report-long")
        XCTAssertGreaterThan(doc.pageCount, 10)
        let text = doc.string ?? ""
        XCTAssertTrue(text.contains("过敏源结束标记")); XCTAssertTrue(text.contains("结论结束标记"))
        XCTAssertEqual(text.components(separatedBy: "复查记录：").count - 1, 180)
        for index in 0..<doc.pageCount {
            let page = try XCTUnwrap(doc.page(at: index))
            XCTAssertEqual(page.bounds(for: .mediaBox).size, CGSize(width: 595, height: 842))
            XCTAssertTrue((page.string ?? "").contains("第 \(index + 1) 页"))
        }
    }
    @MainActor func test_emptyAndSingleWeightReportsAreValidAndExportsNeverOverwrite() throws {
        let pet = Pet(nickname: "空数据", breed: "柯基")
        let report = MedicalReport(pet: pet, weights: [], records: [])
        let doc = try document(report, name: "report-empty")
        XCTAssertTrue((doc.string ?? "").contains("未记录（不代表无过敏）"))
        XCTAssertTrue((doc.string ?? "").contains("暂无体重记录"))
        let one = try DashboardPDFBuilder.makeDocument(report: MedicalReport(pet: pet, weights: [WeightSample(petID: pet.id, kg: 5, date: date(8))], records: []))
        let two = try DashboardPDFBuilder.makeDocument(report: report)
        XCTAssertNotEqual(one, two); XCTAssertNotNil(PDFDocument(url: one))
        try FileManager.default.removeItem(at: one.deletingLastPathComponent()); try FileManager.default.removeItem(at: two.deletingLastPathComponent())
    }
    @MainActor private func document(_ report: MedicalReport, name: String) throws -> PDFDocument {
        let url = try DashboardPDFBuilder.makeDocument(report: report)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let attachment = XCTAttachment(data: try Data(contentsOf: url), uniformTypeIdentifier: "com.adobe.pdf")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        return try XCTUnwrap(PDFDocument(url: url))
    }
}
