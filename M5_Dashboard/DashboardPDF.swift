import SwiftUI
import UIKit

// MARK: - PDF 分享载体
struct PDFShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// UIActivityViewController 包装：导出后用系统分享面板发送
struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - PDF 生成（A4 595x842pt）
enum DashboardPDFBuilder {
    static let pageSize = CGRect(x: 0, y: 0, width: 595, height: 842)
    /// 导出前最低可用空间（1MB，远超一份报告的体积，给临时写入留余量）
    static let minimumFreeBytes = 1_000_000

    static func hasEnoughSpace() -> Bool {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let capacity = try? docs.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey])
              .volumeAvailableCapacityForImportantUsage
        else { return true }   // 取不到容量信息时不阻断导出
        return capacity >= minimumFreeBytes
    }

    static func makeDocument(pet: Pet, names: [UUID: String],
                             samples: [WeightSample], chartImage: UIImage) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PetPal-\(pet.nickname)-成长报告.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: pageSize)
        let data = renderer.pdfData { ctx in
            ctx.beginPage()
            drawCoverPage(pet: pet)
            ctx.beginPage()
            drawChartPage(chartImage: chartImage)
            ctx.beginPage()
            drawTablePage(samples: samples, names: names, in: ctx)
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    // 第一页：宠物基本信息
    private static func drawCoverPage(pet: Pet) {
        var y: CGFloat = 72
        drawText("PetPal 成长报告", x: 48, y: y, font: .preferredFont(forTextStyle: .title1)); y += 44
        y += 16
        drawText("昵称：\(pet.nickname)", x: 48, y: y, font: .preferredFont(forTextStyle: .headline)); y += 32
        drawText("物种：\(pet.species.rawValue)", x: 48, y: y, font: .preferredFont(forTextStyle: .body)); y += 28
        drawText("品种：\(pet.breed)", x: 48, y: y, font: .preferredFont(forTextStyle: .body)); y += 28
        drawText("生日：\(RecordAnswerDate.display.string(from: pet.birthday))",
                 x: 48, y: y, font: .preferredFont(forTextStyle: .body)); y += 28
        drawText(String(format: "体重：%.1f kg", pet.weightKg),
                 x: 48, y: y, font: .preferredFont(forTextStyle: .body)); y += 28
        drawText("导出于 \(RecordAnswerDate.display.string(from: Date()))",
                 x: 48, y: pageSize.height - 72, font: .preferredFont(forTextStyle: .footnote),
                 color: .secondaryLabel)
    }

    // 第二页：图表快照
    private static func drawChartPage(chartImage: UIImage) {
        var y: CGFloat = 72
        drawText("体重变化曲线", x: 48, y: y, font: .preferredFont(forTextStyle: .title2)); y += 40
        let rect = CGRect(x: 48, y: y, width: pageSize.width - 96, height: 300)
        if chartImage.size.width > 0 {
            chartImage.draw(in: rect)
        } else {
            drawText("（图表渲染失败）", x: 48, y: y, font: .preferredFont(forTextStyle: .body),
                     color: .secondaryLabel)
        }
    }

    // 第三页：体重原始数据表格（超出自动分页）
    private static func drawTablePage(samples: [WeightSample], names: [UUID: String], in ctx: UIGraphicsPDFRendererContext) {
        var y: CGFloat = 72
        drawText("体重原始数据", x: 48, y: y, font: .preferredFont(forTextStyle: .title2)); y += 40
        drawText("日期        宠物        体重(kg)", x: 48, y: y,
                 font: .preferredFont(forTextStyle: .headline), color: .secondaryLabel)
        y += 30
        let body = UIFont.preferredFont(forTextStyle: .body)
        for s in samples {
            if y > pageSize.height - 72 {   // 分页
                ctx.beginPage()
                y = 72
            }
            let line = "\(RecordAnswerDate.table.string(from: s.date))    \(names[s.petID] ?? "未知")    \(String(format: "%.1f", s.kg))"
            drawText(line, x: 48, y: y, font: body)
            y += 26
        }
        if samples.isEmpty {
            drawText("暂无体重数据", x: 48, y: y, font: body, color: .secondaryLabel)
        }
    }

    private static func drawText(_ text: String, x: CGFloat, y: CGFloat,
                                 font: UIFont, color: UIColor = .label) {
        (text as NSString).draw(at: CGPoint(x: x, y: y),
                                withAttributes: [.font: font, .foregroundColor: color])
    }
}
