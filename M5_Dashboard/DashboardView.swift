import SwiftUI
import UIKit

// MARK: - 主视图：体重曲线 + 打卡热力图 + 健康时间线 + PDF 导出
struct DashboardView: View {
    let pet: Pet
    let pets: [Pet]
    @StateObject private var vm: DashboardViewModel
    @StateObject private var heatmap: CheckinHeatmapModel
    @StateObject private var timeline: HealthTimelineModel
    private let weightRepo: WeightRepository
    @State private var showWeights = false
    @State private var showReportOptions = false

    init(pet: Pet, pets: [Pet]) {
        self.pet = pet
        self.pets = pets
        let all = pets.isEmpty ? [pet] : pets
        let names = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.nickname) })
        let weightRepo = CoreDataWeightRepository()
        self.weightRepo = weightRepo
        _vm = StateObject(wrappedValue: DashboardViewModel(repo: weightRepo, names: names))
        let recordRepo = CoreDataRecordRepository()
        _heatmap = StateObject(wrappedValue: CheckinHeatmapModel(repo: recordRepo, petID: pet.id))
        _timeline = StateObject(wrappedValue: HealthTimelineModel(repo: recordRepo, petID: pet.id))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Spacing.lg) {
                    chartSection
                    heatmapSection
                    timelineSection
                }
                .padding(DS.Spacing.md)
            }
            .background(Color.pageBackground)
            .navigationTitle("成长看板")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("导出PDF") { showReportOptions = true }
                        .a11y("导出PDF", hint: "生成\(pet.nickname)的就医报告，可选择日期范围")
                        .accessibilityIdentifier("dashboard.exportPDF")
                }
            }
            .sheet(isPresented: $showWeights) { WeightHistoryView(pet: pet, pets: pets) }
            .sheet(isPresented: $showReportOptions) {
                MedicalReportOptionsView(pet: pet, export: exportPDF)
            }
        }
    }

    // MARK: ① 体重折线图
    private var chartSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                HStack {
                    Text("体重变化").font(.headline)
                    Spacer()
                    Picker("统计粒度", selection: $vm.granularity) {
                        ForEach(Granularity.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                    .a11y("统计粒度", hint: "按月或按年聚合体重数据")
                    .accessibilityIdentifier("dashboard.granularity")
                }
                Button("管理体重记录") { showWeights = true }
                    .accessibilityIdentifier("dashboard.manageWeights")
                if pets.count > 1 { petChips }
                if vm.series.contains(where: { !$0.points.isEmpty }) {
                    WeightLineChart(vm: vm)
                        .frame(height: 220)
                        .accessibilityIdentifier("dashboard.chart")
                    legend
                } else {
                    Text("还没有体重数据，记录后将在这里展示变化曲线")
                        .font(.body).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .accessibilityIdentifier("dashboard.chartEmpty")
                }
            }
        }
    }

    /// 多宠物叠加选择 chips
    private var petChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.sm) {
                ForEach(pets) { p in
                    let selected = vm.selectedPetIDs.contains(p.id)
                    Button {
                        vm.togglePet(p.id)
                    } label: {
                        Text(p.nickname)
                            .font(.body)
                            .padding(.horizontal, DS.Spacing.md)
                            .padding(.vertical, DS.Spacing.xs)
                            .background(
                                Capsule().fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary.opacity(0.15)))
                            )
                            .foregroundStyle(selected ? Color.white : Color.primary)
                    }
                    .a11y("叠加\(p.nickname)的体重曲线",
                          hint: selected ? "当前已叠加，再次点击取消" : "当前未叠加，点击加入曲线")
                    .accessibilityIdentifier("dashboard.petChip.\(p.nickname)")
                }
            }
        }
    }

    /// 图例：颜色点 + 昵称
    private var legend: some View {
        HStack(spacing: DS.Spacing.md) {
            ForEach(vm.series) { s in
                HStack(spacing: DS.Spacing.xs) {
                    Circle().fill(ChartPalette.color(s.colorIndex)).frame(width: 10, height: 10)
                    Text(s.petName).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(s.petName)：\(ChartPalette.color(s.colorIndex) == .accentColor ? "主题色" : "彩色")曲线")
            }
            Spacer()
        }
        .accessibilityHidden(vm.series.count <= 1)   // 单宠时图例对 VoiceOver 是噪音
    }

    // MARK: ② 月度打卡热力图
    private var heatmapSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                Text("月度打卡").font(.headline)
                    .accessibilityIdentifier("dashboard.heatmap")
                Text("左右滑动查看历史月份").font(.caption).foregroundStyle(.secondary)
                TabView(selection: $heatmap.selectedMonth) {
                    ForEach(heatmap.months, id: \.self) { month in
                        MonthGrid(month: month, counts: heatmap.counts)
                            .tag(month)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 320)
            }
        }
    }

    // MARK: ③ 疫苗/体检时间线
    private var timelineSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                Text("疫苗、驱虫与体检").font(.headline)
                    .accessibilityIdentifier("dashboard.timeline")
                if timeline.events.isEmpty {
                    Text("暂无疫苗、驱虫或体检记录")
                        .font(.body).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .accessibilityIdentifier("dashboard.timelineEmpty")
                } else {
                    VStack(spacing: DS.Spacing.sm) {
                        ForEach(timeline.events) { event in
                            timelineRow(event)
                        }
                    }
                }
            }
        }
    }

    private func timelineRow(_ event: HealthEvent) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(event.title).font(.body)
                if !event.detail.isEmpty {
                    Text(event.detail).font(.caption).foregroundStyle(.secondary)
                }
                Text(event.date, formatter: RecordAnswerDate.display)
                    .font(.caption).foregroundStyle(.secondary)
                if let due = event.nextDue {
                    TimelineView(.periodic(from: Date(), by: 60)) { context in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("下次：" + due.formatted(date: .abbreviated, time: event.hasNotification ? .shortened : .omitted))
                            if let status = event.nextStatus(now: context.date) {
                                Text("下次计划：" + status.rawValue + (event.nextPaused ? " · 通知已暂停" : (event.hasNotification ? "" : " · 未设置通知")))
                                    .foregroundStyle(statusColor(status))
                            }
                        }.font(.caption)
                    }
                }
            }
            Spacer(minLength: DS.Spacing.sm)
            Text(event.status.rawValue)
                .font(.caption)
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, DS.Spacing.xs)
                .background(Capsule().fill(statusColor(event.status).opacity(0.15)))
                .foregroundStyle(statusColor(event.status))
                .accessibilityLabel("状态：\(event.status.rawValue)")
        }
        .padding(DS.Spacing.sm)
        .background(Color.groupedBackground,
                    in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
    }

    private func statusColor(_ status: HealthEvent.Status) -> Color {
        switch status {
        case .overdue: return .red
        case .pending: return .orange
        case .done: return .green
        }
    }

    // MARK: ④ 同一宠物、同一日期范围的完整报告
    private func exportPDF(range: ReportDateRange?) throws -> URL {
        guard DashboardPDFBuilder.hasEnoughSpace() else {
            throw NSError(domain: "PetPal.Report", code: 2, userInfo: [NSLocalizedDescriptionKey: "可用存储空间不足，请清理后重试。"])
        }
        let samples = try weightRepo.samples(petID: pet.id)
        let records = try CoreDataRecordRepository().records(petID: pet.id)
        return try DashboardPDFBuilder.makeDocument(report: MedicalReport(pet: pet, range: range, weights: samples, records: records))
    }
}
