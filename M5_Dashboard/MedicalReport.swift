import SwiftUI

struct ReportDateRange: Equatable {
    let start: Date
    let end: Date
    let calendar: Calendar
    init(start: Date, end: Date, calendar: Calendar = .current) throws {
        guard start.timeIntervalSinceReferenceDate.isFinite,
              end.timeIntervalSinceReferenceDate.isFinite,
              calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) != nil else {
            throw NSError(domain: "PetPal.Report", code: 1, userInfo: [NSLocalizedDescriptionKey: "开始日期不能晚于结束日期。"])
        }
        let firstDay = calendar.startOfDay(for: start), lastDay = calendar.startOfDay(for: end)
        guard firstDay <= lastDay else {
            throw NSError(domain: "PetPal.Report", code: 1, userInfo: [NSLocalizedDescriptionKey: "开始日期不能晚于结束日期。"])
        }
        self.start = firstDay; self.end = lastDay; self.calendar = calendar
    }
    func contains(_ date: Date) -> Bool {
        guard let exclusiveEnd = calendar.date(byAdding: .day, value: 1, to: end) else { return false }
        return date >= start && date < exclusiveEnd
    }
    var label: String { "\(RecordAnswerDate.table.string(from: start)) 至 \(RecordAnswerDate.table.string(from: end))（含首尾日期）" }
}

/// 图表和明细共享同一只宠物、同一时间范围的快照。
struct MedicalReport {
    let pet: Pet
    let range: ReportDateRange?
    let weights: [WeightSample]
    let records: [Record]
    let generatedAt: Date
    static let healthKinds: [RecordKind] = [.vaccine, .deworming, .checkup, .medication]
    init(pet: Pet, range: ReportDateRange? = nil, weights: [WeightSample], records: [Record], generatedAt: Date = Date()) {
        self.pet = pet; self.range = range; self.generatedAt = generatedAt
        self.weights = weights.filter { $0.petID == pet.id && (range?.contains($0.date) ?? true) }.sorted { $0.date < $1.date }
        self.records = records.filter { $0.petID == pet.id && Self.healthKinds.contains($0.kind) && (range?.contains($0.eventDate) ?? true) }.sorted { $0.eventDate > $1.eventDate }
    }
    var rangeLabel: String { range?.label ?? "全部日期" }
}

struct MedicalReportOptionsView: View {
    let pet: Pet
    let export: (ReportDateRange?) throws -> URL
    @Environment(\.dismiss) private var dismiss
    @State private var allDates = true
    @State private var start = Calendar.current.date(byAdding: .month, value: -3, to: Date()) ?? Date()
    @State private var end = Date()
    @State private var error: String?
    @State private var generating = false
    @State private var shareItem: PDFShareItem?
    private var invalidRange: Bool { Calendar.current.startOfDay(for: start) > Calendar.current.startOfDay(for: end) }
    var body: some View {
        NavigationStack {
            Form {
                Section("就医报告 · \(pet.nickname)") {
                    Text("仅包含这只宠物的资料，不受看板多宠物对比选择影响。")
                    Toggle("全部日期", isOn: $allDates).accessibilityIdentifier("report.allDates")
                    if !allDates {
                        DatePicker("开始日期", selection: $start, in: ...Date(), displayedComponents: .date).accessibilityIdentifier("report.start")
                        DatePicker("结束日期", selection: $end, in: ...Date(), displayedComponents: .date).accessibilityIdentifier("report.end")
                        if invalidRange { Text("开始日期不能晚于结束日期。").foregroundStyle(.red) }
                    }
                }
                Section("包含内容") {
                    Text("当前档案与过敏源、体重曲线与明细、疫苗、驱虫、体检及用药记录。健康记录按发生日期筛选。")
                    Text("档案信息为导出时的当前值；下次计划不代表已经完成。未记录的项目会明确标注。")
                }
                Section {
                    Text("报告含宠物健康资料及你填写的芯片号、兽医联系方式。生成后请确认分享对象。PDF 用于整理已有记录，不提供诊断或治疗建议。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button(generating ? "正在生成…" : "生成并分享 PDF") {
                        generating = true
                        Task { @MainActor in
                            await Task.yield()
                            do { shareItem = PDFShareItem(url: try export(allDates ? nil : ReportDateRange(start: start, end: end))) }
                            catch { self.error = error.localizedDescription }
                            generating = false
                        }
                    }
                    .disabled(generating || (!allDates && invalidRange)).accessibilityIdentifier("report.generate")
                }
            }
            .navigationTitle("导出就医报告")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(generating) } }
            .interactiveDismissDisabled(generating)
            .sheet(item: $shareItem) { ActivityView(activityItems: [$0.url]).ignoresSafeArea() }
            .alert("导出失败", isPresented: .init(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(error ?? "请重试") }
        }
    }
}
