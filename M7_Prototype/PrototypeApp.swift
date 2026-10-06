import SwiftUI
import Combine
import UserNotifications

@main
struct PetPalPrototypeApp: App {
    // H-06：接入 AppDelegate，挂 UNUserNotificationCenterDelegate 实现通知点击路由
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene { WindowGroup { RootTabView() } }
}

// MARK: - DeepLink 路由（H-06）
@MainActor final class DeepLinkRouter: ObservableObject {
    static let shared = DeepLinkRouter()
    @Published var path = NavigationPath()
    init() {}
    /// 点击通知 → 路由至对应宠物详情页（落点在「我的」tab 的 NavigationStack）
    func openPet(id: UUID) { path.append(id) }
    /// L-01：widget 点击深链 petpal://pet/<uuid>
    func handle(url: URL) {
        guard url.scheme == "petpal", url.host == "pet",
              let raw = url.pathComponents.last,
              let id = UUID(uuidString: raw) else { return }
        openPet(id: id)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    /// 通知点击（前台/后台/杀进程态均经此回调）；userInfo 契约见 M4 ReminderContentBuilder
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard info["route"] as? String == "reminder",
              let raw = info["petID"] as? String,
              let petID = UUID(uuidString: raw) else { return }
        DeepLinkRouter.shared.openPet(id: petID)
    }
    /// 前台收到通知时仍展示横幅（提醒类 App 的合理默认）
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

// MARK: - UNUserNotificationCenter 的真实适配（生产用；测试用 Mock）
final class UNNotificationScheduler: NotificationScheduling {
    private let center = UNUserNotificationCenter.current()
    func requestAuthorization() async throws -> Bool {
        // L-03：不再申请从未使用的 badge 权限
        try await center.requestAuthorization(options: [.alert, .sound])
    }
    func add(_ request: UNNotificationRequest) async throws {
        try await center.add(request)
    }
    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }
    func removePending(matchingPrefix prefix: String) async {
        let requests = await center.pendingNotificationRequests()
        let ids = requests.filter {
            $0.content.userInfo["route"] as? String == "reminder" && $0.identifier.hasPrefix(prefix)
        }.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}

// MARK: - 当前宠物选择（H-07：多宠物家庭可切换，选择持久化；全 App 共享一份，跨 tab 一致）
@MainActor final class CurrentPetStore: ObservableObject {
    @Published private(set) var current: Pet?
    @Published private(set) var pets: [Pet] = []
    private static let defaultsKey = "petpal.currentPetID"
    private var bag = Set<AnyCancellable>()
    // 必须持有 repo：CoreDataPetRepository deinit 会移除变更观察者，跨实例广播随之断开
    private let repo: PetRepository
    init(repo: PetRepository) {
        self.repo = repo
        repo.petsPublisher.receive(on: DispatchQueue.main)
            .sink { [weak self] pets in
                guard let self else { return }
                self.pets = pets
                let storedID = UserDefaults.standard.string(forKey: Self.defaultsKey).flatMap(UUID.init)
                // 已删宠物自动回退到列表第一只
                self.current = pets.first { $0.id == storedID } ?? pets.first
            }
            .store(in: &bag)
    }
    func select(_ pet: Pet) {
        current = pet
        UserDefaults.standard.set(pet.id.uuidString, forKey: Self.defaultsKey)
    }
}
