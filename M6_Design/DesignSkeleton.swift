import SwiftUI

// MARK: - 设计 Token（全 App 只允许引用，禁止散落字面量）
enum DS {
    enum Spacing {
        static let xs: CGFloat = 4, sm: CGFloat = 8, md: CGFloat = 16
        static let lg: CGFloat = 24, xl: CGFloat = 32
    }
    enum Radius {
        static let control: CGFloat = 8, card: CGFloat = 12, sheet: CGFloat = 16
    }
    enum Shadow {   // 统一卡片阴影参数
        static let cardColor = Color.black.opacity(0.08)
        static let cardRadius: CGFloat = 8
        static let cardY: CGFloat = 2
    }
}

// MARK: - 语义化颜色封装（深色模式自动适配，禁止硬编码色值）
extension Color {
    static let pageBackground = Color(.systemBackground)
    static let cardBackground = Color(.secondarySystemBackground)
    static let groupedBackground = Color(.systemGroupedBackground)
}

// MARK: - 无障碍约定（M-05：label 必填、hint 按需——Apple 指南要求 hint 仅在 label 无法说清结果时提供）
extension View {
    @ViewBuilder
    func a11y(_ label: String, hint: String? = nil,
              traits: AccessibilityTraits = .isButton) -> some View {
        if let hint {
            accessibilityLabel(label).accessibilityHint(hint).accessibilityAddTraits(traits)
        } else {
            accessibilityLabel(label).accessibilityAddTraits(traits)
        }
    }
}

// MARK: - 卡片容器（圆角12 + 统一阴影 + 语义化底色）
struct CardContainer<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(DS.Spacing.md)
            .background(Color.cardBackground,
                        in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .shadow(color: DS.Shadow.cardColor, radius: DS.Shadow.cardRadius, y: DS.Shadow.cardY)
    }
}

// MARK: - 本地首版：今日 / 记录 / 成长 / 我的
struct RootTabView: View {
    @StateObject private var router = DeepLinkRouter.shared
    @StateObject private var petListVM = PetListViewModel(repo: CoreDataPetRepository())
    @StateObject private var currentPet: CurrentPetStore
    @StateObject private var reminderService = ReminderService.shared
    @State private var selection: Tab = .today
    @State private var recordsPickerRequested = false
    @State private var storeError: Error?
    @State private var snapshotSyncer: WidgetSnapshotSyncer
    @State private var showRecovery = false
    @State private var dataRevision = UUID()
    @State private var recordsNavigationRevision = UUID()
    @State private var missingRecordsPet = false
    @Environment(\.scenePhase) private var scenePhase
    enum Tab { case today, records, growth, profile }

    init() {
        let current = CurrentPetStore(repo: CoreDataPetRepository())
        _currentPet = StateObject(wrappedValue: current)
        _snapshotSyncer = State(wrappedValue: WidgetSnapshotSyncer(
            reminderRepo: CoreDataReminderRepository(), currentPet: current))
    }

    var body: some View {
        Group {
            if let error = storeError {
                NavigationStack {
                VStack(spacing: DS.Spacing.md) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                    Text("数据加载失败").font(.headline)
                    Text("本地数据暂时无法打开：\(error.localizedDescription)")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("从备份恢复") { showRecovery = true }
                    Text("恢复前会校验备份，并保留原数据库副本。")
                        .font(.footnote).foregroundStyle(.secondary)
                    NavigationLink("隐私与支持") { PrivacySupportView() }
                }
                .padding(DS.Spacing.lg)
                .accessibilityIdentifier("app.storeError")
                }
            } else {
                TabView(selection: $selection) {
                    TodayHomeView(currentPet: currentPet, reminderService: reminderService,
                                  onCreatePet: { selection = .profile })
                        .tabItem { Label("今日", systemImage: "house") }.tag(Tab.today)
                    RecordsHomeView(currentPet: currentPet, reminderService: reminderService,
                                    pickerRequested: $recordsPickerRequested)
                        .id(recordsNavigationRevision)
                        .tabItem { Label("记录", systemImage: "calendar") }.tag(Tab.records)
                    Group {
                        if let pet = currentPet.current {
                            DashboardView(pet: pet, pets: currentPet.pets).id(pet.id)
                        } else {
                            Text("创建宠物档案后查看成长趋势")
                        }
                    }
                    .tabItem { Label("成长", systemImage: "chart.xyaxis.line") }.tag(Tab.growth)
                    PetManagementView(petListVM: petListVM, currentPet: currentPet,
                                      onShowBackup: { showRecovery = true })
                        .tabItem { Label("我的", systemImage: "person") }.tag(Tab.profile)
                }
                .id(dataRevision)
            }
        }
        .onAppear {
            storeError = CoreDataStack.shared.loadError
            petListVM.reminderCleanup = { [reminderService] _ in Task { await reminderService.rescheduleAll() } }
            reminderService.onDidChange = { [snapshotSyncer] in snapshotSyncer.sync() }
            refreshLocalData()
        }
        .onChange(of: scenePhase) { if $0 == .active { refreshLocalData() } }
        .onOpenURL { router.handle(url: $0) }
        .onReceive(router.$path) { if !$0.isEmpty { selection = .profile } }
        .onReceive(router.$recordsPetID.combineLatest(currentPet.$pets, currentPet.$hasLoadedPets)
            .receive(on: DispatchQueue.main)) { id, pets, loaded in
            // 冷启动时先保留请求，等档案加载完成再选宠物；不存在的 ID 不落到另一只宠物。
            guard let id, loaded, router.recordsPetID == id, storeError == nil else { return }
            router.recordsPetID = nil
            guard let pet = pets.first(where: { $0.id == id }) else {
                missingRecordsPet = true
                return
            }
            currentPet.select(pet)
            recordsPickerRequested = false
            recordsNavigationRevision = UUID()
            selection = .records
        }
        .onReceive(NotificationCenter.default.publisher(for: .backupDidRestore)) { _ in
            storeError = CoreDataStack.shared.loadError
            router.path = NavigationPath()
            router.recordsPetID = nil
            dataRevision = UUID()
            // 宠物 publisher 刷新后由 syncer 自动生成快照；通知在恢复流程内重建。
        }
        .sheet(isPresented: $showRecovery) { NavigationStack { BackupManagementView() } }
        .alert("无法打开记录", isPresented: $missingRecordsPet) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("这只宠物的档案已不存在。请在 App 中查看或创建宠物档案。")
        }
    }

    private func refreshLocalData() {
        guard storeError == nil else { return }
        snapshotSyncer.sync()
        Task { await reminderService.rescheduleAll() }
        // 和用户保存操作在主线程串行，数据库与媒体取得一致的副本。
        DatabaseBackupManager.backupIfDue()
    }
}

struct TodayHomeView: View {
    @ObservedObject var currentPet: CurrentPetStore
    @ObservedObject var reminderService: ReminderService
    var onCreatePet: () -> Void
    @State private var showRecord = false
    @State private var showReminder = false
    @State private var showWeight = false
    var body: some View {
        NavigationStack {
            List {
                if let pet = currentPet.current {
                    Section("当前宠物") {
                        HStack {
                            PetAvatarThumb(pet: pet)
                            Text(pet.nickname).font(.headline)
                            Spacer()
                            if currentPet.pets.count > 1 {
                                Menu("切换") {
                                    ForEach(currentPet.pets) { p in
                                        Button(p.nickname) { currentPet.select(p) }
                                    }
                                }
                            }
                        }
                    }
                    Section("今日待提醒") {
                        TimelineView(.periodic(from: Date(), by: 60)) { context in
                            let events = todayReminders(pet: pet, now: context.date)
                            if events.isEmpty { Text("今日暂无待提醒").foregroundStyle(.secondary) }
                            else {
                                ForEach(events, id: \.occurrenceKey) { event in
                                    HStack { Text(String(format: "%02d:%02d", event.hour, event.minute)).monospacedDigit(); Text(event.type) }
                                }
                            }
                        }
                        if reminderService.permission != .granted {
                            Text("通知权限未开启，可在「管理提醒」中开启通知。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Section("快速记录") {
                        Button { showRecord = true } label: { Label("记一条日常", systemImage: "plus.circle") }
                            .accessibilityIdentifier("today.addRecord")
                        Button { showWeight = true } label: { Label("记体重", systemImage: "scalemass") }
                        Button { showReminder = true } label: { Label("管理提醒", systemImage: "bell") }
                    }
                    Section {
                        Text("记录与照片保存在本机。定期在「我的 → 数据备份」导出完整备份，方便换机或恢复。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        Text("为宠物建档，开始记录日常与健康变化")
                        Button("创建宠物档案", action: onCreatePet)
                            .accessibilityIdentifier("today.createPet")
                    }
                }
            }
            .navigationTitle("今日")
            .sheet(isPresented: $showRecord) { RecordTemplatePickerView(pet: currentPet.current) }
            .sheet(isPresented: $showWeight) {
                if let pet = currentPet.current { WeightFormView(petID: pet.id) }
            }
            .sheet(isPresented: $showReminder) {
                if let pet = currentPet.current { ReminderListView(pet: pet, service: reminderService) }
            }
        }
    }
    private func todayReminders(pet: Pet, now: Date) -> [WidgetSnapshot.ReminderEntry] {
        let snapshot = WidgetSnapshot(generatedAt: now, currentPetID: pet.id,
            pets: [.init(id: pet.id, nickname: pet.nickname, species: pet.species.rawValue)],
            reminders: reminderService.configurations.map {
                .init(id: $0.id, petID: $0.petID, petName: $0.petName, type: $0.type.rawValue, hour: $0.hour, minute: $0.minute,
                      repeatRule: $0.repeatRule, advance: $0.advance, isEnabled: $0.isEnabled)
            })
        return WidgetSnapshotQueries.remainingReminders(in: snapshot, now: now)
    }

}
