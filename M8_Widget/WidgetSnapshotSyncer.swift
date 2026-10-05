import Foundation
import Combine
import WidgetKit
import os

// MARK: - Widget 快照同步（L-01；仅 App target）
// 触发点：①宠物列表/当前宠物变更（订阅 CurrentPetStore）②提醒增删/重排（ReminderService.onDidChange）
// ③回前台（RootTabView scenePhase .active）。写完快照后通知 WidgetCenter 刷新时间线。
@MainActor final class WidgetSnapshotSyncer {
    private let reminderRepo: ReminderRepository
    private let currentPet: CurrentPetStore
    private let directory: () -> URL?
    private var bag = Set<AnyCancellable>()
    /// 测试可替换；生产为 WidgetCenter 全量刷新
    var reloadTimelines: () -> Void = { WidgetCenter.shared.reloadAllTimelines() }

    init(reminderRepo: ReminderRepository, currentPet: CurrentPetStore,
         directory: @escaping () -> URL? = { WidgetSnapshotStore.sharedDirectory }) {
        self.reminderRepo = reminderRepo
        self.currentPet = currentPet
        self.directory = directory
        currentPet.$pets
            .combineLatest(currentPet.$current)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &bag)
    }

    func sync() {
        let now = Date()
        do {
            guard let directory = directory() else { throw WidgetSnapshotStoreError.sharedContainerUnavailable }
            let all = try reminderRepo.allReminders()
            let snapshot = WidgetSnapshot(
                generatedAt: now,
                currentPetID: currentPet.current?.id,
                pets: currentPet.pets.map {
                    .init(id: $0.id, nickname: $0.nickname, species: $0.species.rawValue,
                          avatarFileName: $0.avatarFileName)
                },
                reminders: all
                    .filter(\.isEnabled)
                    .map { .init(id: $0.id, petID: $0.petID, petName: $0.petName,
                                 type: $0.type.rawValue, hour: $0.hour, minute: $0.minute,
                                 repeatRule: $0.repeatRule) })
            try WidgetSnapshotStore.write(snapshot, to: directory)
            if let avatar = currentPet.current?.avatarFileName {
                let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                WidgetSnapshotStore.copyAvatar(fileName: avatar, from: documents, to: directory)
            }
            reloadTimelines()
        } catch {
            Logger(subsystem: "com.petpal.prototype", category: "Widget")
                .error("快照更新失败，保留旧快照：\(error.localizedDescription, privacy: .private)")
        }
    }

    /// 与 Widget 查询共用重复规则，避免两端对日期的判断漂移。
    nonisolated static func fires(rule: RepeatRule, on date: Date, calendar: Calendar = .current) -> Bool {
        rule.fires(on: date, calendar: calendar)
    }
}
