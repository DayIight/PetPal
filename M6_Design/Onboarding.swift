import SwiftUI

/// 首次打开只展示页内引导。进度来自已保存的数据，取消或保存失败不会推进。
@MainActor final class OnboardingStore: ObservableObject {
    enum Step: Int { case pet, record, reminder, finished }
    @Published private(set) var step: Step = .pet
    @Published private(set) var isVisible = false
    @Published private(set) var error: String?
    private let defaults: UserDefaults
    private let stack: CoreDataStack
    private let key = "petpal.onboarding.v1"
    private var reviewing = false
    init(defaults: UserDefaults = PreviewFixtures.defaults, stack: CoreDataStack = .shared) {
        self.defaults = defaults; self.stack = stack
    }
    func refresh(pets: [Pet]) {
        if defaults.string(forKey: key) == nil {
            // 升级前已有档案的用户无需重新接受首次引导。
            defaults.set(pets.isEmpty ? "active" : "existing", forKey: key)
        }
        guard defaults.string(forKey: key) == "active" || reviewing else { isVisible = false; return }
        isVisible = true
        let savedID = defaults.string(forKey: key + ".petID").flatMap(UUID.init)
        guard let pet = pets.first(where: { $0.id == savedID }) ?? pets.first else {
            defaults.removeObject(forKey: key + ".petID"); step = .pet; error = nil; return
        }
        defaults.set(pet.id.uuidString, forKey: key + ".petID")
        do {
            let records = try CoreDataRecordRepository(stack: stack).records(petID: pet.id)
            let reminders = try CoreDataReminderRepository(stack: stack).reminders(petID: pet.id)
            error = nil
            step = records.isEmpty ? .record : reminders.isEmpty ? .reminder : .finished
            if step == .finished && !reviewing { finish() }
        } catch { self.error = "引导进度读取失败，请稍后重试。" }
    }
    var petID: UUID? { defaults.string(forKey: key + ".petID").flatMap(UUID.init) }
    func skip() { reviewing = false; defaults.set("skipped", forKey: key); isVisible = false }
    func finish() { reviewing = false; defaults.set("completed", forKey: key); isVisible = false }
    func reopen(pets: [Pet]) { reviewing = true; refresh(pets: pets) }
}

struct OnboardingSection: View {
    @ObservedObject var store: OnboardingStore
    var onContinue: () -> Void
    var body: some View {
        Section("开始使用 PetPal") {
            Text("给陪伴留一份记录").font(.headline)
            Text("档案、记录与照片保存在本机，不需要注册。请定期到「我的 → 数据备份」导出完整备份；本机自动备份也会随卸载清除。")
                .font(.subheadline).foregroundStyle(.secondary)
            ForEach(0..<3, id: \.self) { index in
                Label(["创建宠物档案", "保存第一条日常记录", "设置第一个提醒"][index],
                      systemImage: index < store.step.rawValue ? "checkmark.circle.fill" : "\(index + 1).circle")
                    .foregroundStyle(index < store.step.rawValue ? Color.accentColor : .primary)
            }
            if let error = store.error { Text(error).foregroundStyle(.red) }
            if store.step == .finished {
                Button("完成引导") { store.finish() }.accessibilityIdentifier("onboarding.finish")
            } else {
                Button(["创建宠物档案", "记第一条日常", "设置第一个提醒"][store.step.rawValue], action: onContinue)
                    .accessibilityIdentifier("onboarding.continue")
            }
            Text("保存提醒时才会询问通知权限；拒绝授权仍可在 App 中查看待办。")
                .font(.footnote).foregroundStyle(.secondary)
            Button("跳过引导") { store.skip() }.accessibilityIdentifier("onboarding.skip")
        }
    }
}
