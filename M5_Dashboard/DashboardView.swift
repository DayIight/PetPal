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
    @State private var shareItem: PDFShareItem?
    @State private var showSpaceAlert = false
    @State private var exportError: String?

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
                    Button("导出PDF", action: exportPDF)
                        .a11y("导出PDF", hint: "生成\(pet.nickname)的成长报告并打开分享面板")
                        .accessibilityIdentifier("dashboard.exportPDF")
                }
            }
            .sheet(isPresented: $showWeights) { WeightHistoryView(pet: pet, pets: pets) }
            .sheet(item: $shareItem) { item in
                ActivityView(activityItems: [item.url])
                    .ignoresSafeArea()
                    .a11y("分享成长报告", hint: "通过系统分享面板发送PDF")
            }
            .alert("存储空间不足", isPresented: $showSpaceAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text("可用存储空间不足，无法生成PDF。请先清理空间后重试。")
            }
            .alert("导出失败", isPresented: .init(get: { exportError != nil },
                                                  set: { if !$0 { exportError = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(exportError ?? "请重试")
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
                Text("疫苗与体检").font(.headline)
                    .accessibilityIdentifier("dashboard.timeline")
                if timeline.events.isEmpty {
                    Text("暂无疫苗或体检记录")
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

    // MARK: ④ PDF 导出
    private func exportPDF() {
        guard DashboardPDFBuilder.hasEnoughSpace() else {
            showSpaceAlert = true
            return
        }
        let names = Dictionary(uniqueKeysWithValues: (pets.isEmpty ? [pet] : pets).map { ($0.id, $0.nickname) })
        let samples = vm.selectedPetIDs
            .flatMap { (try? weightRepo.samples(petID: $0)) ?? [] }
            .sorted { $0.date > $1.date }
        let image = chartSnapshot()
        do {
            let url = try DashboardPDFBuilder.makeDocument(
                pet: pet, names: names, samples: samples, chartImage: image)
            shareItem = PDFShareItem(url: url)
        } catch {
            exportError = error.localizedDescription
        }
    }

    /// 用 ImageRenderer 将折线图渲染为位图嵌入 PDF 第二页
    @MainActor private func chartSnapshot() -> UIImage {
        let content = WeightLineChart(vm: vm)
            .frame(width: 540, height: 260)
            .padding(DS.Spacing.md)
            .background(Color.white)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        return renderer.uiImage ?? UIImage()
    }
}
