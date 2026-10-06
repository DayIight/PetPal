import AppIntents

@available(iOS 17.0, *)
struct SelectWidgetPetIntent: AppIntent {
    static var title: LocalizedStringResource = "切换小组件宠物"
    static var isDiscoverable: Bool = false

    @Parameter(title: "宠物 ID")
    var petID: String

    // 两只宠物时，左右按钮的目标 ID 相同；方向仍须区分两项交互的身份。
    @Parameter(title: "上一页")
    var isPrevious: Bool

    init() {}
    init(petID: UUID, isPrevious: Bool) {
        self.petID = petID.uuidString
        self.isPrevious = isPrevious
    }

    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: petID) {
            do {
                try WidgetPetPageStore.select(petID: id, in: WidgetSnapshotStore.sharedDirectory)
            } catch {
                // 保存失败保留原页面，随后重新读取；不更改 App 的当前宠物。
                NSLog("小组件翻页保存失败：%@", error.localizedDescription)
            }
        }
        // 系统在 intent 完成后保证刷新当前小组件；避免额外重排与交互刷新争抢时间线。
        return .result()
    }
}
