import Foundation
import UserNotifications

/// 只在 Debug 中通过明确启动参数启用，使用内存数据库和独立偏好域。
/// 商店截图与 UI 测试不读取、修改真实宠物数据库，也不发送通知或写小组件快照。
enum PreviewFixtures {
    static var scenario: String? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--petpal-preview"), args.indices.contains(i + 1), ["empty", "demo"].contains(args[i + 1]) { return args[i + 1] }
        #endif
        return nil
    }
    static var enabled: Bool { scenario != nil }
    static var defaults: UserDefaults { enabled ? UserDefaults(suiteName: "PetPal.Preview")! : .standard }
    static func scheduler() -> NotificationScheduling {
        #if DEBUG
        if enabled { return PreviewNotificationScheduler() }
        #endif
        return UNNotificationScheduler()
    }
    static func prepare() {
        #if DEBUG
        guard let scenario else { return }
        if ProcessInfo.processInfo.arguments.contains("--reset-onboarding") {
            defaults.removePersistentDomain(forName: "PetPal.Preview")
        }
        guard scenario == "demo" else { return }
        let stack = CoreDataStack.shared
        let now = Date()
        func days(_ count: Int) -> Date { Calendar.current.date(byAdding: .day, value: count, to: now)! }
        var pet = Pet(id: UUID(uuidString: "76EEAA26-B67B-4A59-9D14-463658115711")!, species: .dog, nickname: "奶糖", breed: "柯基", birthday: days(-820), weightKg: 10.2)
        pet.allergens = ["鸡肉", "花粉"]; pet.neuterStatus = .neutered
        do {
            try CoreDataPetRepository(stack: stack).create(pet)
            let weights = CoreDataWeightRepository(stack: stack)
            for i in 0..<8 { try weights.add(WeightSample(petID: pet.id, kg: 9.5 + Double(i) * 0.1, date: days(-105 + i * 15))) }
            let records = CoreDataRecordRepository(stack: stack)
            for offset in [-8, -5, -3, -1, 0] {
                try records.create(Record(petID: pet.id, kind: .walking, answers: ["minutes": "30", "place": "小区公园"], note: "精神很好，今天也认真探索了新路线。", occurredAt: days(offset)))
            }
            try records.create(Record(petID: pet.id, kind: .vaccine, answers: ["vaccineName": "年度疫苗", "hospital": "社区动物医院", "nextDue": RecordAnswerDate.table.string(from: days(340))], occurredAt: days(-25)))
            try records.create(Record(petID: pet.id, kind: .deworming, answers: ["drug": "常规驱虫", "nextDue": RecordAnswerDate.table.string(from: days(20))], occurredAt: days(-10)))
            try records.create(Record(petID: pet.id, kind: .checkup, answers: ["hospital": "社区动物医院", "conclusion": "已记录本次检查结果，继续观察日常状态。", "weightKg": "10.2"], occurredAt: days(-2)))
            try CoreDataReminderRepository(stack: stack).save(Reminder(petID: pet.id, petName: pet.nickname, type: .feeding, hour: 18, minute: 30, trackingSince: Calendar.current.startOfDay(for: now)))
            defaults.set("completed", forKey: "petpal.onboarding.v1")
        } catch { preconditionFailure("截图演示数据准备失败：\(error)") }
        #endif
    }
}
#if DEBUG
private final class PreviewNotificationScheduler: NotificationScheduling {
    func requestAuthorization() async throws -> Bool { false }
    func authorizationStatus() async -> UNAuthorizationStatus { .denied }
    func add(_ request: UNNotificationRequest) async throws {}
    func removePending(matchingPrefix prefix: String) async {}
}
#endif
