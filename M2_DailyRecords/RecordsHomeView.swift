import SwiftUI

// MARK: - 记录主页（「记录」tab：顶部当前宠物切换 + 时间轴/日历分段 + 记一条/提醒入口）
struct RecordsHomeView: View {
    @ObservedObject var currentPet: CurrentPetStore
    @ObservedObject var reminderService: ReminderService
    @Binding var pickerRequested: Bool   // 发布 sheet「记一条日常」跨 tab 触发模板选择
    @State private var segment: Segment = .timeline
    @State private var showTemplatePicker = false
    @State private var showReminder = false

    private enum Segment: String, CaseIterable, Identifiable {
        case timeline = "时间轴", calendar = "日历"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                petHeader
                Picker("视图切换", selection: $segment) {
                    ForEach(Segment.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.sm)
                .accessibilityIdentifier("records.segment")
                content
            }
            .background(Color.pageBackground)
            .navigationTitle("记录")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showReminder = true } label: {
                        Image(systemName: "bell.badge")
                    }
                    .a11y("提醒", hint: "查看并管理当前宠物的提醒")
                    .accessibilityIdentifier("records.reminder")
                    .disabled(currentPet.current == nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { showTemplatePicker = true } label: {
                        Image(systemName: "plus")
                    }
                    .a11y("记一条", hint: "选择模板，为当前宠物创建一条记录")
                    .accessibilityIdentifier("records.add")
                    .disabled(currentPet.current == nil)
                }
            }
        }
        .sheet(isPresented: $showTemplatePicker) {
            RecordTemplatePickerView(pet: currentPet.current)
        }
        .sheet(isPresented: $showReminder) {
            if let pet = currentPet.current {
                ReminderListView(pet: pet, service: reminderService)
            }
        }
        // 发布 sheet 跳来：切到记录 tab 后自动弹模板选择
        .onChange(of: pickerRequested) { requested in
            if requested { showTemplatePicker = true; pickerRequested = false }
        }
    }

    // MARK: 顶部当前宠物切换（H-07：多宠物家庭可切换；单宠时静态展示）
    private var petHeader: some View {
        CardContainer {
            HStack(spacing: DS.Spacing.sm) {
                if let pet = currentPet.current {
                    PetAvatarThumb(pet: pet, diameter: 36)
                    if currentPet.pets.count > 1 {
                        Menu {
                            ForEach(currentPet.pets) { p in
                                Button {
                                    currentPet.select(p)
                                } label: {
                                    Label("\(p.nickname)（\(p.species.rawValue)）",
                                          systemImage: p.id == pet.id ? "checkmark.circle.fill" : "circle")
                                }
                            }
                        } label: {
                            Label("当前宠物：\(pet.nickname)", systemImage: "arrow.triangle.2.circlepath")
                                .font(.body)
                        }
                        .a11y("切换宠物", hint: "当前为\(pet.nickname)，共\(currentPet.pets.count)只")
                        .accessibilityIdentifier("records.petSwitcher")
                    } else {
                        Text("当前宠物：\(pet.nickname)").font(.body)
                            .accessibilityIdentifier("records.currentPet")
                    }
                } else {
                    Text("还没有宠物档案").font(.body).foregroundStyle(.secondary)
                        .accessibilityIdentifier("records.noPetHeader")
                }
                Spacer(minLength: DS.Spacing.sm)
            }
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.top, DS.Spacing.sm)
    }

    @ViewBuilder private var content: some View {
        switch segment {
        case .timeline:
            if let pet = currentPet.current {
                TimelineRecordsView(pet: pet).id(pet.id)
            } else {
                noPetPlaceholder
            }
        case .calendar:
            if let pet = currentPet.current {
                EmbeddedCalendarView(pet: pet).id(pet.id)
            } else {
                noPetPlaceholder
            }
        }
    }

    /// 无档案引导（建档在「我的」tab 完成）
    private var noPetPlaceholder: some View {
        VStack(spacing: DS.Spacing.md) {
            Image(systemName: "tray")
                .font(.system(size: 40)).foregroundStyle(.secondary)
            Text("创建宠物档案后，这里会展示它的日常记录")
                .font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("records.noPet")
        }
        .frame(maxWidth: .infinity)
        .padding(DS.Spacing.xl)
    }
}

// MARK: - 时间轴（TimelineViewModel.sections 的 UI 落点：按日分组卡片列表）
private struct TimelineRecordsView: View {
    @State private var detailRecord: Record?
    let pet: Pet
    @StateObject private var vm: TimelineViewModel
    private let cal = Calendar.current

    init(pet: Pet) {
        self.pet = pet
        _vm = StateObject(wrappedValue: TimelineViewModel(
            repo: CoreDataRecordRepository(), petID: pet.id))
    }

    var body: some View {
        ScrollView {
            if vm.sections.isEmpty {
                VStack(spacing: DS.Spacing.md) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("还没有记录").font(.headline)
                    Text("点右上角「+」选择模板，记第一条日常")
                        .font(.body).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(DS.Spacing.xl)
                .accessibilityIdentifier("records.timelineEmpty")
            } else {
                VStack(spacing: DS.Spacing.md) {
                    ForEach(vm.sections, id: \.day) { section in
                        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                            Text(dayTitle(section.day)).font(.headline)
                                .padding(.horizontal, DS.Spacing.md)
                            VStack(spacing: DS.Spacing.sm) {
                                ForEach(section.items) { record in
                                    Button { detailRecord = record } label: { recordRow(record) }.buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, DS.Spacing.md)
                        }
                    }
                }
                .padding(.vertical, DS.Spacing.sm)
            }
        }
        .sheet(item: $detailRecord) { RecordDetailView(record: $0) }
    }

    private func dayTitle(_ day: Date) -> String {
        let m = cal.component(.month, from: day)
        let d = cal.component(.day, from: day)
        return cal.isDateInToday(day) ? "今天（\(m)月\(d)日）" : "\(m)月\(d)日"
    }

    /// 行：类型圆标 + displayKind + summary + 心情 + 时间（卡片样式）
    private func recordRow(_ record: Record) -> some View {
        CardContainer {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: record.kind == .custom ? "note.text" : record.kind.symbolName)
                    .font(.body)
                    .frame(width: 36, height: 36)
                    .background(Color.groupedBackground,
                                in: Circle())
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Text(record.displayKind).font(.headline)
                    if !record.summary.isEmpty {
                        Text(record.summary).font(.body).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: DS.Spacing.sm)
                VStack(alignment: .trailing, spacing: DS.Spacing.xs) {
                    Text(timeText(record.createdAt)).font(.caption)
                        .foregroundStyle(.secondary)
                    if !record.mood.isEmpty {
                        Text(record.mood).font(.body)
                            .accessibilityLabel("心情\(record.mood)")
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("records.row.\(record.id.uuidString)")
    }

    private func timeText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

// MARK: - 记录类型 → SF Symbol 圆标
extension RecordKind {
    var symbolName: String {
        switch self {
        case .feeding: return "fork.knife"
        case .walking: return "figure.walk"
        case .training: return "target"
        case .deworming: return "pill.fill"
        case .vaccine: return "syringe.fill"
        case .checkup: return "stethoscope"
        case .grooming: return "scissors"
        case .custom: return "note.text"
        }
    }
}

// MARK: - 日历嵌入壳（复用 RecordCalendarContentView，不带独立导航栈；换宠时 .id 重建 VM）
private struct EmbeddedCalendarView: View {
    let pet: Pet
    @StateObject private var vm: RecordCalendarViewModel
    @State private var selectedDate = Date()
    @State private var detailRecord: Record?

    init(pet: Pet) {
        self.pet = pet
        _vm = StateObject(wrappedValue: RecordCalendarViewModel(
            repo: CoreDataRecordRepository(), petID: pet.id))
    }

    var body: some View {
        RecordCalendarContentView(pet: pet, vm: vm,
                                  selectedDate: $selectedDate, detailRecord: $detailRecord)
            .sheet(item: $detailRecord) { RecordDetailView(record: $0) }
    }
}
