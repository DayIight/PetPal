import CoreData
import Foundation

enum CareItemCategory: String, Codable, CaseIterable {
    case quickAction, medicalDocument, medicationCourse, careInstructions
}

extension Notification.Name {
    static let careItemsDidChange = Notification.Name("PetPal.careItemsDidChange")
}

enum CareItemError: LocalizedError {
    case invalidPayload, missingPet, wrongOwner
    var errorDescription: String? {
        switch self {
        case .invalidPayload: return "照护资料损坏或格式不正确，请重试。"
        case .missingPet: return "这只宠物的档案已不存在。"
        case .wrongOwner: return "这份资料不属于当前宠物。"
        }
    }
}

/// 与档案和提醒共用上下文；commit=false 的变更由调用方统一提交或回滚。
final class CareItemStore {
    let stack: CoreDataStack
    private var context: NSManagedObjectContext { stack.container.viewContext }
    init(stack: CoreDataStack = .shared) { self.stack = stack }

    func items<T: Decodable>(_ type: T.Type, category: CareItemCategory, petID: UUID) throws -> [T] {
        let request = CDCareItem.fetchRequest()
        request.predicate = NSPredicate(format: "category == %@ AND petID == %@", category.rawValue, petID as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        return try context.fetch(request).map { row in
            guard let raw = row.payload, let id = row.id else { throw CareItemError.invalidPayload }
            let data = Data(raw.utf8)
            try Self.validateIdentity(data, id: id, petID: petID)
            return try JSONDecoder().decode(type, from: data)
        }
    }

    func upsert<T: Encodable>(_ value: T, id: UUID, petID: UUID, category: CareItemCategory, commit: Bool = true) throws {
        let data = try JSONEncoder().encode(value)
        try Self.validateIdentity(data, id: id, petID: petID)
        let pet = CDPet.fetchRequest(); pet.predicate = NSPredicate(format: "id == %@", petID as CVarArg)
        guard try context.count(for: pet) == 1 else { throw CareItemError.missingPet }
        let request = CDCareItem.fetchRequest(); request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        let existing = try context.fetch(request).first
        if let existing, existing.petID != petID || existing.category != category.rawValue { throw CareItemError.wrongOwner }
        let row = existing ?? stack.insert(CDCareItem.self)
        row.id = id; row.petID = petID; row.category = category.rawValue
        row.payload = String(decoding: data, as: UTF8.self)
        if row.createdAt == nil { row.createdAt = Date() }
        if commit { try stack.save(); Self.notify() }
    }

    func delete(id: UUID, commit: Bool = true) throws {
        let request = CDCareItem.fetchRequest(); request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        for row in try context.fetch(request) { context.delete(row) }
        if commit { try stack.save(); Self.notify() }
    }

    static func notify() { NotificationCenter.default.post(name: .careItemsDidChange, object: nil) }

    static func validateIdentity(_ data: Data, id: UUID, petID: UUID) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawID = object["id"] as? String, UUID(uuidString: rawID) == id,
              let rawPet = object["petID"] as? String, UUID(uuidString: rawPet) == petID else { throw CareItemError.invalidPayload }
    }

    static func rows(in context: NSManagedObjectContext, petID: UUID? = nil) throws -> [CDCareItem] {
        guard context.persistentStoreCoordinator?.managedObjectModel.entitiesByName["CDCareItem"] != nil else { return [] }
        let request = CDCareItem.fetchRequest()
        if let petID { request.predicate = NSPredicate(format: "petID == %@", petID as CVarArg) }
        return try context.fetch(request)
    }

    static func mediaFileNames(in rows: [CDCareItem]) throws -> [String] {
        try rows.filter { $0.category == CareItemCategory.medicalDocument.rawValue }.map { row in
            guard let raw = row.payload,
                  let object = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                  let fileName = object["fileName"] as? String,
                  PortableBackup.safeName(fileName) else { throw CareItemError.invalidPayload }
            return fileName
        }
    }
}
