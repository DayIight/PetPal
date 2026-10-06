import SwiftUI
import Combine

// MARK: - 疫苗/体检时间线
struct HealthEvent: Identifiable {
    enum Status: String {
        case done = "已完成", pending = "待进行", overdue = "已过期"
    }
    let id: UUID
    let title: String
    let detail: String
    let date: Date
    let status: Status
}

@MainActor final class HealthTimelineModel: ObservableObject {
    @Published private(set) var events: [HealthEvent] = []
    private var bag = Set<AnyCancellable>()
    // 必须持有 repo：repo deinit 会移除 recordsDidChange 观察者，广播链路随之断开
    private let repo: RecordRepository

    init(repo: RecordRepository, petID: UUID) {
        self.repo = repo
        repo.recordsPublisher(petID: petID).receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.apply($0) }
            .store(in: &bag)
    }

    private func apply(_ records: [Record]) {
        events = records
            .filter { $0.kind == .vaccine || $0.kind == .checkup }
            .sorted { $0.createdAt < $1.createdAt }   // 时间正序
            .map(HealthEvent.init)
    }
}

private extension HealthEvent {
    init(_ r: Record) {
        id = r.id
        let isVaccine = r.kind == .vaccine
        title = isVaccine ? (r.answers["vaccineName"] ?? "疫苗接种") : "体检"
        var parts: [String] = []
        if let hospital = r.answers["hospital"], !hospital.isEmpty { parts.append(hospital) }
        if !isVaccine, let conclusion = r.answers["conclusion"], !conclusion.isEmpty {
            parts.append(conclusion)
        }
        detail = parts.joined(separator: " · ")
        date = r.createdAt
        // 状态判定：有 nextDue 且早于今天 → 已过期；nextDue 在未来 → 待进行；无 nextDue → 已完成
        if let nextDue = r.answers["nextDue"].flatMap(RecordAnswerDate.parse) {
            status = nextDue < Calendar.current.startOfDay(for: Date()) ? .overdue : .pending
        } else {
            status = .done
        }
    }
}
