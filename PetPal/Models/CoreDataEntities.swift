import CoreData
import Foundation

@objc(CDPet)
public class CDPet: NSManagedObject {
    @NSManaged public var id: UUID?
    @NSManaged public var nickname: String?
    @NSManaged public var breed: String?
    @NSManaged public var birthday: Date?
    @NSManaged public var adoptionDate: Date?
    @NSManaged public var weightKg: Double
    @NSManaged public var neuterStatus: String?
    @NSManaged public var chipNumber: String?
    @NSManaged public var allergens: [String]?
    @NSManaged public var species: String?
    @NSManaged public var vetName: String?
    @NSManaged public var vetPhone: String?
    @NSManaged public var avatarFileName: String?
    @NSManaged public var createdAt: Date?
}

extension CDPet {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDPet> {
        NSFetchRequest<CDPet>(entityName: "CDPet")
    }
}

@objc(CDRecord)
public class CDRecord: NSManagedObject {
    @NSManaged public var id: UUID?
    @NSManaged public var petID: UUID?
    @NSManaged public var kind: String?
    @NSManaged public var answers: [String: String]?
    @NSManaged public var note: String?
    @NSManaged public var mood: String?
    @NSManaged public var photoFileNames: [String]?
    @NSManaged public var createdAt: Date?
    @NSManaged public var templateName: String?
    @NSManaged public var templateSnapshot: String?
}

extension CDRecord {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDRecord> {
        NSFetchRequest<CDRecord>(entityName: "CDRecord")
    }
}

@objc(CDCustomTemplate)
public class CDCustomTemplate: NSManagedObject {
    @NSManaged public var id: UUID?
    @NSManaged public var name: String?
    @NSManaged public var payload: String?
    @NSManaged public var createdAt: Date?
}

extension CDCustomTemplate {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDCustomTemplate> {
        NSFetchRequest<CDCustomTemplate>(entityName: "CDCustomTemplate")
    }
}

@objc(CDReminder)
public class CDReminder: NSManagedObject {
    @NSManaged public var id: UUID?
    @NSManaged public var petID: UUID?
    @NSManaged public var type: String?
    @NSManaged public var hour: Int16
    @NSManaged public var minute: Int16
    @NSManaged public var petName: String?
    @NSManaged public var repeatRule: String?
    @NSManaged public var advance: String?
    @NSManaged public var isEnabled: Bool
}

extension CDReminder {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDReminder> {
        NSFetchRequest<CDReminder>(entityName: "CDReminder")
    }
}

@objc(CDWeightSample)
public class CDWeightSample: NSManagedObject {
    @NSManaged public var id: UUID?
    @NSManaged public var petID: UUID?
    @NSManaged public var kg: Double
    @NSManaged public var date: Date?
}

extension CDWeightSample {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDWeightSample> {
        NSFetchRequest<CDWeightSample>(entityName: "CDWeightSample")
    }
}
