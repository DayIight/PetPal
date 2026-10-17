import SwiftUI
import UIKit
import CoreText

struct PDFShareItem: Identifiable { let id = UUID(); let url: URL }
struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

enum DashboardPDFBuilder {
    static let pageSize = CGRect(x: 0, y: 0, width: 595, height: 842)
    static let minimumFreeBytes = 1_000_000
    static func hasEnoughSpace() -> Bool {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let capacity = try? docs.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        else { return true }
        return capacity >= minimumFreeBytes
    }
    static func makeDocument(report: MedicalReport) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PetPalReport-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 独立文件夹避免再次导出覆盖正在分享的文件；宠物昵称不作为路径。
        let url = directory.appendingPathComponent("PetPal-就医报告.pdf")
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: "PetPal 就医报告", kCGPDFContextCreator as String: "PetPal"]
        let data = UIGraphicsPDFRenderer(bounds: pageSize, format: format).pdfData { context in
            let page = ReportPage(context: context, petName: report.pet.nickname)
            page.newPage()
            page.heading("就医报告", size: 26)
            page.text("记录范围：" + report.rangeLabel)
            page.text("导出时间：" + RecordAnswerDate.display.string(from: report.generatedAt))
            page.text("本报告整理主人保存的资料，供就诊沟通参考，不提供诊断或治疗建议。未记录不等于没有发生。", secondary: true)
            page.heading("宠物档案（当前信息）")
            let pet = report.pet
            page.text("昵称：\(pet.nickname)\n物种：\(pet.species.rawValue)    品种：\(pet.breed)\n生日：\(RecordAnswerDate.table.string(from: pet.birthday))\n绝育状态：\(pet.neuterStatus.rawValue)")
            if let adoption = pet.adoptionDate { page.text("到家日期：" + RecordAnswerDate.table.string(from: adoption)) }
            page.text(String(format: "档案当前体重：%.1f kg（不受报告日期范围筛选）", pet.weightKg))
            page.text("芯片号：" + nonempty(pet.chipNumber))
            page.text("过敏源：" + (pet.allergens.isEmpty ? "未记录（不代表无过敏）" : pet.allergens.joined(separator: "、")))
            page.text("兽医：" + nonempty(pet.vetName) + "\n兽医电话：" + nonempty(pet.vetPhone))
            page.heading("所选范围概览")
            page.text("体重记录：\(report.weights.count) 条\n" + MedicalReport.healthKinds.map { kind in
                "\(kind.rawValue)：\(report.records.filter { $0.kind == kind }.count) 条"
            }.joined(separator: "    "))
            page.newPage()
            page.heading("体重变化与明细")
            if report.weights.isEmpty { page.text("所选日期范围内暂无体重记录。") }
            else {
                page.chart(report.weights)
                page.text("曲线按实际测量日期绘制，同日多次测量均保留。单位：kg。", secondary: true)
                page.heading("体重明细")
                for sample in report.weights.reversed() {
                    page.text("\(RecordAnswerDate.display.string(from: sample.date))    \(String(format: "%.1f", sample.kg)) kg")
                }
            }
            page.newPage()
            page.heading("健康记录明细")
            for kind in MedicalReport.healthKinds {
                let records = report.records.filter { $0.kind == kind }
                page.reserve(records.isEmpty ? 90 : 180)
                page.heading(kind.rawValue + "记录")
                if records.isEmpty { page.text("所选日期范围内暂无\(kind.rawValue)记录。") }
                for (index, record) in records.enumerated() {
                    page.heading("\(index + 1). \(RecordAnswerDate.display.string(from: record.eventDate))", size: 14)
                    for field in kind.fields {
                        if let value = record.answers[field.key], !value.isEmpty {
                            let title = field.key == "nextDue" ? "下次计划（未确认完成）" : field.title
                            let display = field.key == "nextDue" ? RecordAnswerDate.parse(value).map { RecordAnswerDate.table.string(from: $0) } ?? value : value
                            page.text(title + "：" + display)
                        }
                    }
                    if !record.note.isEmpty { page.text("备注：" + record.note) }
                    if !record.photoFileNames.isEmpty { page.text("附有 \(record.photoFileNames.count) 张照片，请在 App 中查看原图。", secondary: true) }
                    page.gap(12)
                }
            }
        }
        do { try data.write(to: url, options: .atomic) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
        return url
    }
    private static func nonempty(_ value: String?) -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "未记录" }
        return value
    }
}

/// CoreText 按可见字符分页，任意长度的字段也不会在页面底部截断。
final class ReportPage {
    let context: UIGraphicsPDFRendererContext
    let petName: String
    let reportTitle: String
    var y: CGFloat = 64
    var pageNumber = 0
    var section = ""
    let width: CGFloat = 499
    let bottom: CGFloat = 770
    init(context: UIGraphicsPDFRendererContext, petName: String, reportTitle: String = "就医报告") { self.context = context; self.petName = petName; self.reportTitle = reportTitle }
    func newPage(continuation: Bool = false) {
        context.beginPage(); pageNumber += 1; y = 64
        UIColor.white.setFill(); context.cgContext.fill(DashboardPDFBuilder.pageSize)
        let header = "PetPal · " + reportTitle + " · " + String(petName.prefix(20))
        (header as NSString).draw(in: CGRect(x: 48, y: 28, width: width, height: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: UIColor.darkGray])
        ("第 \(pageNumber) 页 · 资料由主人记录" as NSString).draw(at: CGPoint(x: 48, y: 801), withAttributes: [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: UIColor.darkGray])
        if continuation && !section.isEmpty { text(section + "（续）", bold: true) }
    }
    func heading(_ title: String, size: CGFloat = 18) {
        if y + 90 > bottom { newPage() }
        section = title; gap(8); text(title, size: size, bold: true); gap(6)
    }
    func reserve(_ height: CGFloat) { if y + height > bottom { newPage() } }
    func gap(_ value: CGFloat) { y += value }
    func text(_ value: String, size: CGFloat = 12, bold: Bool = false, secondary: Bool = false) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
        let string = NSAttributedString(string: value, attributes: [.font: UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular), .foregroundColor: secondary ? UIColor.darkGray : UIColor.black, .paragraphStyle: paragraph])
        let setter = CTFramesetterCreateWithAttributedString(string)
        var location = 0
        while location < string.length {
            if bottom - y < size + 12 { newPage(continuation: true) }
            let available = bottom - y
            let suggested = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: location, length: string.length - location), nil, CGSize(width: width, height: available), nil)
            let height = min(available, max(size + 8, ceil(suggested.height) + 2))
            let path = CGPath(rect: CGRect(x: 48, y: 842 - y - height, width: width, height: height), transform: nil)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: location, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { newPage(continuation: true); continue }
            let cg = context.cgContext; cg.saveGState(); cg.textMatrix = .identity
            cg.translateBy(x: 0, y: 842); cg.scaleBy(x: 1, y: -1); CTFrameDraw(frame, cg); cg.restoreGState()
            location += visible.length; y += height + 6
            if location < string.length { newPage(continuation: true) }
        }
    }
    func chart(_ samples: [WeightSample]) {
        if y + 240 > bottom { newPage(continuation: true) }
        let rect = CGRect(x: 80, y: y + 20, width: 440, height: 170)
        let cg = context.cgContext; cg.saveGState()
        let low = (samples.map(\.kg).min() ?? 0) - 0.2, high = (samples.map(\.kg).max() ?? 1) + 0.2
        let first = samples.first!.date.timeIntervalSince1970, last = samples.last!.date.timeIntervalSince1970
        cg.setStrokeColor(UIColor.lightGray.cgColor); cg.setLineWidth(0.5); cg.stroke(rect)
        for (kg, lineY) in [(low, rect.maxY), (high, rect.minY)] {
            (String(format: "%.1f", kg) as NSString).draw(at: CGPoint(x: 48, y: lineY - 5), withAttributes: [.font: UIFont.systemFont(ofSize: 9), .foregroundColor: UIColor.darkGray])
        }
        let points = samples.map { sample in CGPoint(x: rect.minX + (last == first ? 0.5 : (sample.date.timeIntervalSince1970 - first) / (last - first)) * rect.width, y: rect.maxY - (sample.kg - low) / (high - low) * rect.height) }
        cg.setStrokeColor(UIColor(red: 0.12, green: 0.45, blue: 0.4, alpha: 1).cgColor); cg.setLineWidth(1.8)
        cg.addLines(between: points); cg.strokePath()
        cg.setFillColor(UIColor(red: 0.12, green: 0.45, blue: 0.4, alpha: 1).cgColor)
        for point in points { cg.fillEllipse(in: CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)) }
        for (date, x) in [(samples.first!.date, rect.minX), (samples.last!.date, rect.maxX - 60)] {
            (RecordAnswerDate.table.string(from: date) as NSString).draw(at: CGPoint(x: x, y: rect.maxY + 8), withAttributes: [.font: UIFont.systemFont(ofSize: 9), .foregroundColor: UIColor.darkGray])
        }
        cg.restoreGState(); y += 230
    }
}
