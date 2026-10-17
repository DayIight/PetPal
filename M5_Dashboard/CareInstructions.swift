import Foundation
import UIKit

struct CareInstructions: Codable, Identifiable, Equatable {
    var id = UUID()
    var petID: UUID
    var diet = ""
    var dailyCare = ""
    var notes = ""
    var emergencyContacts = ""
    var validationError: String? {
        [diet, dailyCare, notes, emergencyContacts].contains(where: { $0.count > 20_000 }) ? "每项照护说明最多20,000字，请精简后保存。" : nil
    }
}

final class CareInstructionsRepository {
    private let store: CareItemStore
    init(store: CareItemStore = CareItemStore()) { self.store = store }
    func load(petID: UUID) throws -> CareInstructions? {
        let values = try store.items(CareInstructions.self, category: .careInstructions, petID: petID)
        guard values.count <= 1 else { throw CareItemError.invalidPayload }
        if let error = values.first?.validationError { throw MedicalDocumentError.invalid(error) }
        return values.first
    }
    func save(_ value: CareInstructions) throws {
        if let error = value.validationError { throw MedicalDocumentError.invalid(error) }
        if let existing = try load(petID: value.petID), existing.id != value.id { throw CareItemError.invalidPayload }
        try store.upsert(value, id: value.id, petID: value.petID, category: .careInstructions)
    }
}

struct CareCardOptions {
    var includeAllergies = false
    var includeMedication = false
    var includeVet = false
}

struct CareCardSnapshot {
    let pet: Pet
    let sections: [(title: String, text: String)]
    let generatedAt: Date
    init(pet: Pet, instructions: CareInstructions, options: CareCardOptions, medicationSchedules: [String], generatedAt: Date = Date()) throws {
        guard pet.id == instructions.petID else { throw CareItemError.wrongOwner }
        if let error = instructions.validationError { throw MedicalDocumentError.invalid(error) }
        self.pet = pet; self.generatedAt = generatedAt
        var contents = [(title: "饮食安排", text: instructions.diet), (title: "日常照护", text: instructions.dailyCare), (title: "注意事项", text: instructions.notes), (title: "紧急联系人", text: instructions.emergencyContacts)]
        if options.includeAllergies { contents.append(("过敏信息（主人记录）", pet.allergens.isEmpty ? "未记录（不代表无过敏）" : pet.allergens.joined(separator: "、"))) }
        if options.includeMedication { contents.append(("用药安排（主人记录）", medicationSchedules.isEmpty ? "当前没有进行中的用药疗程。" : medicationSchedules.joined(separator: "\n\n"))) }
        if options.includeVet {
            contents.append(("兽医联系方式", [pet.vetName, pet.vetPhone].compactMap { $0 }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n")))
        }
        sections = contents.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !sections.isEmpty else { throw MedicalDocumentError.invalid("请先填写至少一项照护说明，或选择要分享的资料。") }
    }
}

enum CareCardPDFBuilder {
    @MainActor static func makeDocument(snapshot: CareCardSnapshot) throws -> URL {
        guard DashboardPDFBuilder.hasEnoughSpace() else { throw MedicalDocumentError.invalid("可用存储空间不足，请清理后重试。") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PetPalCareCard-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("PetPal-照护交接卡.pdf")
        do {
            let format = UIGraphicsPDFRendererFormat()
            format.documentInfo = [kCGPDFContextTitle as String: "PetPal 照护交接卡", kCGPDFContextCreator as String: "PetPal"]
            let data = UIGraphicsPDFRenderer(bounds: DashboardPDFBuilder.pageSize, format: format).pdfData { context in
                let page = ReportPage(context: context, petName: snapshot.pet.nickname, reportTitle: "照护交接卡")
                page.newPage()
                page.heading("照护交接卡", size: 26)
                page.text("宠物：\(snapshot.pet.nickname)\n物种：\(snapshot.pet.species.rawValue)    品种：\(snapshot.pet.breed)")
                page.text("导出时间：" + RecordAnswerDate.display.string(from: snapshot.generatedAt), secondary: true)
                page.text("以下内容由主人填写。用药安排请按已确认的兽医指示核对，不作为诊断或处方建议；情况变化时请联系主人或兽医。", secondary: true)
                for section in snapshot.sections { page.heading(section.title); page.text(section.text) }
            }
            guard !data.isEmpty else { throw MedicalDocumentError.invalid("交接卡生成失败，请重试。") }
            try data.write(to: url, options: .atomic)
            return url
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
}
