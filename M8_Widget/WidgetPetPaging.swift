import Foundation

/// 用宠物 ID 记住页面，避免增删、重排档案后页码指向另一只宠物。
struct WidgetPetPage: Equatable {
    let pet: WidgetSnapshot.PetEntry
    let index: Int
    let count: Int
    let previousPetID: UUID?
    let nextPetID: UUID?

    static func resolve(in snapshot: WidgetSnapshot, selectedPetID: UUID?) -> WidgetPetPage? {
        guard !snapshot.pets.isEmpty else { return nil }
        let index = selectedPetID.flatMap { id in snapshot.pets.firstIndex { $0.id == id } }
            ?? snapshot.currentPetID.flatMap { id in snapshot.pets.firstIndex { $0.id == id } }
            ?? 0
        let count = snapshot.pets.count
        return WidgetPetPage(
            pet: snapshot.pets[index], index: index, count: count,
            previousPetID: count > 1 ? snapshot.pets[(index + count - 1) % count].id : nil,
            nextPetID: count > 1 ? snapshot.pets[(index + 1) % count].id : nil)
    }
}

/// 独立于 App 的当前宠物和快照；小、中尺寸共用上次查看的页面。
enum WidgetPetPageStore {
    static let widgetKind = "PetPalReminderWidget"
    static let selectionFileName = "widget-selected-pet.json"

    static func selectedPetID(from directory: URL) -> UUID? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(selectionFileName)) else { return nil }
        return try? JSONDecoder().decode(UUID.self, from: data)
    }

    /// 按钮携带目标 ID；重复执行也停留在同一页，不会因旧时间线多翻一页。
    /// 已删除的目标或不可读快照不会覆盖现有选择。
    @discardableResult
    static func select(petID: UUID, in directory: URL) throws -> Bool {
        guard let snapshot = WidgetSnapshotStore.read(from: directory),
              snapshot.pets.contains(where: { $0.id == petID }) else { return false }
        let data = try JSONEncoder().encode(petID)
        try data.write(to: directory.appendingPathComponent(selectionFileName), options: .atomic)
        return true
    }
}
