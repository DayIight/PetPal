import Foundation
import Combine
import WidgetKit

// MARK: - Widget 快照同步（L-01；仅 App target）
// 触发点：①宠物列表/当前宠物变更（订阅 CurrentPetStore）②提醒增删/重排（ReminderService.onDidChange）
// ③回前台（RootTabView scenePhase .active）。写完快照后通知 WidgetCenter 刷新时间线。
@MainActor final class WidgetSnapshotSyncer {
    private let reminderRepo: ReminderRepository
    private let currentPet: CurrentPetStore
    private var bag = Set<AnyCancellable>()
    /// 测试可替换；生产为 WidgetCenter 全量刷新
    var reloadTimelines: () -> Void = { WidgetCenter.shared.reloadAllTimelines() }

    init(reminderRepo: ReminderRepository, currentPet: CurrentPetStore) {
        self.reminderRepo = reminderRepo
        self.currentPet = currentPet
        currentPet.$pets
            .combineLatest(currentPet.$current)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &bag)
    }

    func sync() {
        let now = Date()
        let all = (try? reminderRepo.allReminders()) ?? []
        let snapshot = WidgetSnapshot(
            generatedAt: now,
            currentPetID: currentPet.current?.id,
            pets: currentPet.pets.map {
                .init(id: $0.id, nickname: $0.nickname, species: $0.species.rawValue,
                      avatarFileName: $0.avatarFileName)
            },
            reminders: all
                .map { .init(id: $0.id, petID: $0.petID, petName: $0.petName,
                             type: $0.type.rawValue, hour: $0.hour, minute: $0.minute, repeatRule: $0.repeatRule, advance: $0.advance, isEnabled: $0.isEnabled) })
        let directory = WidgetSnapshotStore.sharedDirectory
        do {
            try WidgetSnapshotStore.write(snapshot, to: directory)
            let names = Set(currentPet.pets.compactMap(\.avatarFileName))
            for name in names { WidgetSnapshotStore.copyAvatar(fileName: name, from: AvatarStore.directory, to: directory) }
            try WidgetSnapshotStore.pruneAvatars(keeping: names, in: directory)
        } catch {
            NSLog("widget 快照写入失败：%@", error.localizedDescription)   // 不阻塞主流程，widget 保持旧快照/空态
        }
        reloadTimelines()
    }

    /// 提醒是否在指定日触发；与 Widget 使用相同的重复规则。
    nonisolated static func fires(rule: RepeatRule, on date: Date, calendar: Calendar = .current) -> Bool {
        ReminderRecurrence.occurs(rule: rule, on: date, calendar: calendar)
    }
}
