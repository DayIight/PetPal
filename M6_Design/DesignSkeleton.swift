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

// MARK: - 根导航：五标签栏，「发布」居中突出、点击弹 sheet 而非切页（PRD §6 要求保留五 tab 布局）
// H-04 修复：①记住来源 tab，发布后停留原页不再强制跳回首页；②占位 tab 对 VoiceOver 隐藏
// 重构：各 tab 挂正式页面（首页动态=信息流 / 记录=记录主页 / 消息=互动消息 / 我的=宠物管理）
struct RootTabView: View {
    @StateObject private var router = DeepLinkRouter.shared
    @StateObject private var petListVM = PetListViewModel(repo: CoreDataPetRepository())
    @StateObject private var currentPet: CurrentPetStore
    @StateObject private var reminderService = ReminderService(
        repo: CoreDataReminderRepository(), scheduler: UNNotificationScheduler())
    @State private var selection: Tab = .home
    @State private var lastContentTab: Tab = .home   // 最近一个内容 tab，发布拦截后恢复
    @State private var showPublish = false
    @State private var recordsPickerRequested = false   // 发布 sheet「记一条日常」→ 记录页弹模板选择
    @State private var storeError: Error?
    @State private var snapshotSyncer: WidgetSnapshotSyncer   // L-01：widget 快照同步
    @Environment(\.scenePhase) private var scenePhase
    /// 全 App 共享一份社交数据：信息流/消息页跳转/发布 sheet 都落在同一实例上
    private let socialRepo = MockSocialRepository()

    enum Tab: Int { case home, records, publish, messages, profile }

    init() {
        let current = CurrentPetStore(repo: CoreDataPetRepository())
        _currentPet = StateObject(wrappedValue: current)
        _snapshotSyncer = State(wrappedValue: WidgetSnapshotSyncer(
            reminderRepo: CoreDataReminderRepository(), currentPet: current))
    }

    var body: some View {
        Group {
            if let error = storeError {
                // H-03：持久化加载失败的全屏错误态，而非静默丢数据
                // （iOS 16 无 ContentUnavailableView，用等效自绘布局；升 iOS 17 后可替换）
                VStack(spacing: DS.Spacing.md) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle).foregroundStyle(.orange)
                    Text("数据加载失败").font(.headline)
                    Text("本地数据库无法打开（\(error.localizedDescription)）。请重启 App 重试；若反复出现，请联系支持。")
                        .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(DS.Spacing.lg)
                .accessibilityIdentifier("app.storeError")
            } else {
                tabBar
            }
        }
        .onAppear {
            storeError = CoreDataStack.shared.loadError
            // H-02：删除宠物前先撤销其 pending 通知
            petListVM.reminderCleanup = { [reminderService] id in
                try reminderService.removeAll(petID: id)
            }
            // L-01：提醒增删/重排后重建 widget 快照
            reminderService.onDidChange = { [snapshotSyncer] in snapshotSyncer.sync() }
            snapshotSyncer.sync()
        }
        // L-01：回前台刷新快照（跨日/跨时区后 widget 数据保鲜）
        .onChange(of: scenePhase) { phase in
            if phase == .active { snapshotSyncer.sync() }
        }
        // L-01：widget 点击深链 petpal://pet/<uuid>
        .onOpenURL { router.handle(url: $0) }
        // H-06：通知点击深链落点在「我的」tab 的导航栈，路径入栈时先切到该 tab
        .onReceive(router.$path) { path in
            if !path.isEmpty { selection = .profile }
        }
    }

    private var tabBar: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selection) {
                FeedView(repo: socialRepo)
                    .tabItem { Label("首页动态", systemImage: "house") }.tag(Tab.home)
                RecordsHomeView(currentPet: currentPet, reminderService: reminderService,
                                pickerRequested: $recordsPickerRequested)
                    .tabItem { Label("记录", systemImage: "calendar") }.tag(Tab.records)
                Color.clear
                    .tabItem { Label("发布", systemImage: "plus") }.tag(Tab.publish)
                    .accessibilityHidden(true)   // 占位 tab 不进入读屏焦点，发布由悬浮按钮承担
                MessageListView(repo: socialRepo, messages: socialRepo.interactionMessages())
                    .tabItem { Label("消息", systemImage: "bell.badge") }.tag(Tab.messages)
                PetManagementView(petListVM: petListVM, currentPet: currentPet)
                    .tabItem { Label("我的", systemImage: "person") }.tag(Tab.profile)
            }
            .tint(.accentColor)   // 选中=主题色；未选中自动为 secondaryLabel
            publishButton
        }
        .onChange(of: selection) { tab in   // 拦截中间 tab：只弹发布，并停留在来源页
            if tab == .publish {
                selection = lastContentTab; showPublish = true
            } else {
                lastContentTab = tab
            }
        }
        .sheet(isPresented: $showPublish) { publishSheet }
    }

    /// 发布 sheet：记一条日常（跳记录页并弹模板选择）/ 发一条动态（表单 push）
    private var publishSheet: some View {
        NavigationStack {
            List {
                Button {
                    showPublish = false
                    selection = .records
                    recordsPickerRequested = true
                } label: {
                    Label("记一条日常", systemImage: "pawprint")
                }
                .a11y("记一条日常", hint: "前往记录页选择模板，为当前宠物记一条日常记录")
                .accessibilityIdentifier("publish.logRecord")
                NavigationLink {
                    PublishFormView(vm: FeedViewModel(repo: socialRepo))
                } label: {
                    Label("发一条动态", systemImage: "square.and.pencil")
                }
                .a11y("发一条动态", hint: "撰写并发布一条宠友动态")
                .accessibilityIdentifier("publish.newPost")
            }
            .navigationTitle("发布")
            .presentationDetents([.medium])   // iOS 16+
        }
    }

    private var publishButton: some View {
        Button { showPublish = true } label: {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Color.accentColor))
                .shadow(color: DS.Shadow.cardColor, radius: DS.Shadow.cardRadius, y: DS.Shadow.cardY)
        }
        .a11y("发布", hint: "创建新动态或日常记录")
        .accessibilityIdentifier("tab.publish")
        .padding(.bottom, DS.Spacing.xs)
    }
}
