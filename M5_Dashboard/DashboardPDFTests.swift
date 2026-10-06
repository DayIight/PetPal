import XCTest
import PDFKit
@testable import PetPal

final class DashboardPDFTests: XCTestCase {
    func test_exportWritesReadableThreePageReportWithPetAndEmptyData() throws {
        let pet = Pet(nickname: "小白", breed: "柯基")
        let url = try DashboardPDFBuilder.makeDocument(pet: pet, names: [pet.id: pet.nickname], samples: [], chartImage: UIImage())
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        XCTAssertTrue(data.starts(with: Data("%PDF-".utf8)))
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(document.pageCount, 3)
        XCTAssertTrue(document.page(at: 0)?.string?.contains("小白") == true)
        XCTAssertTrue(document.page(at: 2)?.string?.contains("暂无体重数据") == true)
    }
    func test_largeDataSetPaginatesAndPreservesLastRow() throws {
        let pet = Pet(nickname: "测试/宠物", breed: "柯基")
        let samples = (1...80).map { WeightSample(petID: pet.id, kg: Double($0), date: Date()) }
        let url = try DashboardPDFBuilder.makeDocument(pet: pet, names: [pet.id: pet.nickname], samples: samples, chartImage: UIImage())
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertGreaterThan(document.pageCount, 3)
        XCTAssertTrue(document.page(at: document.pageCount - 1)?.string?.contains("80.0") == true)
        XCTAssertEqual(document.page(at: 0)?.bounds(for: .mediaBox), DashboardPDFBuilder.pageSize)
    }
    func test_writeFailureIsReported() {
        XCTAssertThrowsError(try DashboardPDFBuilder.makeDocument(pet: Pet(), names: [:], samples: [], chartImage: UIImage(),
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    }
}
