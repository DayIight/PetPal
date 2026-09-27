import SwiftUI
import Combine

// MARK: - 宠物档案管理（「我的」tab）
// 核心修复：档案列表常驻展示，导航栏「+」随时新增第二个及更多档案；不再依赖单页堆按钮入口。
struct PetManagementView: View {
    @ObservedObject var petListVM: PetListViewModel
    @ObservedObject var currentPet: CurrentPetStore
    @StateObject private var router = DeepLinkRouter.shared
    @State private var showAddPet = false
    @State private var showDashboard = false
    @State private var showTemplates = false
    @State private var showWeight = false

    var body: some View {
        NavigationStack(path: $router.path) {
            ScrollView {
                VStack(spacing: DS.Spacing.md) {
                    if petListVM.pets.isEmpty {
                        emptyState
                    } else {
                        petList
                    }
                    featureSection
                }
                .padding(DS.Spacing.md)
                .frame(maxWidth: .infinity)
            }
            .background(Color.pageBackground)
            .navigationTitle("我的宠物")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { showAddPet = true } label: {
                        Image(systemName: "plus")
                    }
                    .a11y("新增宠物档案", hint: "随时为家庭新增一只宠物建档")
                    .accessibilityIdentifier("pet.add")
                }
            }
            // H-06：通知点击深链的落点（openPet → 宠物详情）
            .navigationDestination(for: UUID.self) { petID in
                PetDetailView(petID: petID, repo: CoreDataPetRepository(),
                              petListVM: petListVM, currentPet: currentPet)
            }
            .sheet(isPresented: $showAddPet) {
                PetFormView(vm: PetFormViewModel(repo: CoreDataPetRepository()))
            }
            .sheet(isPresented: $showDashboard) {
                if let pet = currentPet.current {
                    DashboardView(pet: pet, pets: currentPet.pets)
                }
            }
            .sheet(isPresented: $showWeight) {
                if let pet = currentPet.current {
                    WeightFormView(petID: pet.id)
                }
            }
            .sheet(isPresented: $showTemplates) { TemplateListView() }
        }
    }

    // MARK: 空态：图标 + 引导文案（iOS 16 无 ContentUnavailableView，自绘等效）
    private var emptyState: some View {
        VStack(spacing: DS.Spacing.md) {
            Image(systemName: "pawprint.circle")
                .font(.system(size: 48)).foregroundStyle(.secondary)
            Text("还没有宠物档案").font(.headline)
            Text("为家里的第一只宠物建档，开始记录它的日常")
                .font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("pet.emptyGuide")
            Button("创建第一个宠物档案") { showAddPet = true }
                .a11y("创建宠物档案", hint: "新建宠物昵称、品种等信息")
                .accessibilityIdentifier("pet.createFirst")
        }
        .frame(maxWidth: .infinity)
        .padding(DS.Spacing.lg)
    }

    // MARK: 宠物卡片列表（头像 / 昵称 / 物种品种 / 年龄；点卡片进详情）
    private var petList: some View {
        VStack(spacing: DS.Spacing.md) {
            ForEach(petListVM.pets) { pet in
                NavigationLink(value: pet.id) {
                    petCard(pet)
                }
                .a11y("宠物\(pet.nickname)", hint: "查看\(pet.nickname)的档案详情")
                .accessibilityIdentifier("pet.row.\(pet.nickname)")
                .buttonStyle(.plain)
            }
        }
    }

    private func petCard(_ pet: Pet) -> some View {
        CardContainer {
            HStack(spacing: DS.Spacing.md) {
                PetAvatarThumb(pet: pet, diameter: 52)
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    HStack(spacing: DS.Spacing.sm) {
                        Text(pet.nickname).font(.headline)
                        if pet.id == currentPet.current?.id {
                            Text("当前")
                                .font(.caption2)
                                .padding(.horizontal, DS.Spacing.sm)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                                .foregroundStyle(Color.accentColor)
                                .accessibilityLabel("当前选中")
                        }
                    }
                    Text("\(pet.species.rawValue) · \(pet.breed)").font(.body)
                        .foregroundStyle(.secondary)
                    Text(PetAge.text(from: pet.birthday)).font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: DS.Spacing.sm)
                Image(systemName: "chevron.right")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 功能入口（看板 / 记体重 / 自定义模板）
    private var featureSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                Text("功能入口").font(.headline)
                featureRow("成长看板", icon: "chart.xyaxis.line",
                           hint: "查看当前宠物的体重曲线、打卡热力图与疫苗体检时间线",
                           disabled: currentPet.current == nil) {
                    showDashboard = true
                }
                .accessibilityIdentifier("profile.dashboard")
                featureRow("记体重", icon: "scalemass",
                           hint: "为当前宠物录入一次体重，在看板展示变化曲线",
                           disabled: currentPet.current == nil) {
                    showWeight = true
                }
                .accessibilityIdentifier("profile.addWeight")
                featureRow("自定义模板", icon: "rectangle.stack.badge.plus",
                           hint: "管理自定义记录模板，最多20个") {
                    showTemplates = true
                }
                .accessibilityIdentifier("profile.templates")
            }
        }
    }

    private func featureRow(_ title: String, icon: String, hint: String,
                            disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: icon)
                    .font(.body)
                    .frame(width: 28, height: 28)
                    .background(Color.groupedBackground,
                                in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                    .foregroundStyle(Color.accentColor)
                Text(title).font(.body)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .a11y(title, hint: hint)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }
}

// MARK: - 宠物头像圆标（AvatarStore 读图；无头像用昵称首字占位）
struct PetAvatarThumb: View {
    let pet: Pet
    var diameter: CGFloat = 44
    var body: some View {
        Group {
            if let file = pet.avatarFileName, let image = AvatarStore.load(fileName: file) {
                Image(uiImage: image)
                    .resizable().scaledToFill()
            } else {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.15))
                    Text(pet.nickname.prefix(1))
                        .font(.headline)
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .accessibilityHidden(true)   // 行级 label 已含昵称，头像不单独进读屏
    }
}

// MARK: - 年龄展示（生日 → N岁 / N个月）
enum PetAge {
    static func text(from birthday: Date) -> String {
        let comps = Calendar.current.dateComponents([.year, .month], from: birthday, to: Date())
        let years = comps.year ?? 0, months = comps.month ?? 0
        if years > 0 { return "\(years)岁\(months > 0 ? "\(months)个月" : "")" }
        let totalMonths = max(1, years * 12 + months)
        return "\(totalMonths)个月"
    }
}

// MARK: - 宠物详情页（H-06 通知路由落点；完整信息 + 编辑 + 删除）
struct PetDetailView: View {
    let petID: UUID
    @State private var pet: Pet?
    @State private var showEdit = false
    @State private var confirmDelete = false
    @State private var avatarError: String?
    @State private var bag = Set<AnyCancellable>()
    @ObservedObject private var petListVM: PetListViewModel
    @ObservedObject private var currentPet: CurrentPetStore
    @StateObject private var router = DeepLinkRouter.shared
    @Environment(\.dismiss) private var dismiss
    private let repo: PetRepository

    init(petID: UUID, repo: PetRepository,
         petListVM: PetListViewModel? = nil, currentPet: CurrentPetStore? = nil) {
        self.petID = petID; self.repo = repo
        // 深链/独立场景下无外部 VM 时自建一份（删除联动 reminderCleanup 由 RootTabView 注入共享实例）
        let vm = petListVM ?? PetListViewModel(repo: repo)
        _petListVM = ObservedObject(wrappedValue: vm)
        _currentPet = ObservedObject(wrappedValue: currentPet ?? CurrentPetStore(repo: repo))
    }

    var body: some View {
        Group {
            if let pet {
                Form {
                    Section {
                        HStack(spacing: DS.Spacing.md) {
                            AvatarPickerView(nickname: pet.nickname,
                                             avatarFileName: pet.avatarFileName,
                                             diameter: 64,
                                             onPick: { changeAvatar(pet, image: $0) },
                                             onRemove: { changeAvatar(pet, image: nil) })
                            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                                Text(pet.nickname).font(.title3)
                                if pet.id == currentPet.current?.id {
                                    Text("当前宠物").font(.caption)
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .padding(.vertical, DS.Spacing.xs)
                        .accessibilityIdentifier("pet.detail.header")
                    }
                    Section("基本信息") {
                        LabeledContent("物种", value: pet.species.rawValue)
                        LabeledContent("品种", value: pet.breed)
                        LabeledContent("生日", value: RecordAnswerDate.display.string(from: pet.birthday))
                        LabeledContent("年龄", value: PetAge.text(from: pet.birthday))
                        LabeledContent("体重", value: String(format: "%.1f kg", pet.weightKg))
                        LabeledContent("绝育状态", value: pet.neuterStatus.rawValue)
                    }
                    Section("其他信息") {
                        LabeledContent("芯片号", value: pet.chipNumber?.isEmpty == false ? pet.chipNumber! : "—")
                        LabeledContent("兽医", value: pet.vetName?.isEmpty == false ? pet.vetName! : "—")
                        LabeledContent("兽医电话", value: pet.vetPhone?.isEmpty == false ? pet.vetPhone! : "—")
                    }
                    Section {
                        Button("删除该宠物档案", role: .destructive) { confirmDelete = true }
                            .a11y("删除宠物档案", hint: "将同时删除其记录、提醒与图片")
                            .accessibilityIdentifier("pet.delete")
                    }
                }
                .accessibilityIdentifier("pet.detail")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("编辑") { showEdit = true }
                            .a11y("编辑宠物档案", hint: "修改\(pet.nickname)的信息")
                            .accessibilityIdentifier("pet.edit")
                    }
                }
                .sheet(isPresented: $showEdit) {
                    PetFormView(vm: PetFormViewModel(repo: repo, editing: pet))
                }
                .confirmationDialog("确认删除该宠物档案？",
                                    isPresented: $confirmDelete,
                                    titleVisibility: .visible) {
                    Button("删除（含全部记录与提醒）", role: .destructive) { delete(pet) }
                    Button("取消", role: .cancel) {}
                }
                .alert("操作失败", isPresented: .init(get: { avatarError != nil },
                                                      set: { if !$0 { avatarError = nil } })) {
                    Button("知道了", role: .cancel) {}
                } message: {
                    Text(avatarError ?? "")
                }
            } else {
                // iOS 16 无 ContentUnavailableView，等效自绘
                VStack(spacing: DS.Spacing.sm) {
                    Image(systemName: "questionmark.circle").font(.largeTitle)
                    Text("宠物不存在或已删除").foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("pet.detail.missing")
            }
        }
        .navigationTitle(pet?.nickname ?? "宠物详情")
        .onAppear {
            repo.petsPublisher.receive(on: DispatchQueue.main)
                .sink { pets in pet = pets.first { $0.id == petID } }
                .store(in: &bag)
        }
    }

    /// 删除走 PetListViewModel.delete（保留 H-02 reminderCleanup 联动），删除后退出详情并出栈深链路径
    private func delete(_ pet: Pet) {
        petListVM.delete(pet)
        if !router.path.isEmpty { router.path.removeLast() }
    }

    /// 详情页点头像即时更换/移除：压缩落盘 → 写库 → 成功后清理旧文件；失败回滚新文件并提示
    private func changeAvatar(_ pet: Pet, image: UIImage?) {
        var updated = pet
        var newFile: String?
        if let image {
            guard let name = AvatarStore.save(image) else {
                avatarError = "头像保存失败，请重试"; return
            }
            newFile = name
            updated.avatarFileName = name
        } else {
            updated.avatarFileName = nil
        }
        do {
            try repo.update(updated)
            if let old = pet.avatarFileName, old != newFile { AvatarStore.delete(fileName: old) }
        } catch {
            if let newFile { AvatarStore.delete(fileName: newFile) }
            avatarError = "头像更新失败，请重试"
        }
    }
}
