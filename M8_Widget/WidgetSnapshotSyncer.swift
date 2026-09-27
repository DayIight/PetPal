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
        let calendar = Calendar.current
        let all = (try? reminderRepo.allReminders()) ?? []
        let snapshot = WidgetSnapshot(
            generatedAt: now,
            currentPetID: currentPet.current?.id,
            pets: currentPet.pets.map {
                .init(id: $0.id, nickname: $0.nickname, species: $0.species.rawValue,
                      avatarFileName: $0.avatarFileName)
            },
            reminders: all
                .filter { Self.fires(rule: $0.repeatRule, on: now, calendar: calendar) }
                .map { .init(id: $0.id, petID: $0.petID, petName: $0.petName,
                             type: $0.type.rawValue, hour: $0.hour, minute: $0.minute) })
        let directory = WidgetSnapshotStore.sharedDirectory
        do {
            try WidgetSnapshotStore.write(snapshot, to: directory)
            if let avatar = currentPet.current?.avatarFileName {
                let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                WidgetSnapshotStore.copyAvatar(fileName: avatar, from: documents, to: directory)
            }
        } catch {
            assertionFailure("widget 快照写入失败：\(error)")   // 不阻塞主流程，widget 保持旧快照/空态
        }
        reloadTimelines()
    }

    /// 提醒是否在今天触发（快照只装当天全集，widget 侧无需理解 RepeatRule）；纯函数，非隔离
    nonisolated static func fires(rule: RepeatRule, on date: Date, calendar: Calendar = .current) -> Bool {
        switch rule {
        case .daily:
            return true
        case .weekly(let days):
            return days.contains(calendar.component(.weekday, from: date))
        case .monthly(let day):
            return calendar.component(.day, from: date) == day
        case .yearly(let month, let day):
            return calendar.component(.month, from: date) == month
                && calendar.component(.day, from: date) == day
        }
    }
}
