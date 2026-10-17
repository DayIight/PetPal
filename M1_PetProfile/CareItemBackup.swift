import CoreData
import Foundation

/// 备份从不信任 JSON 载荷的身份、类型或跨实体引用。
enum CareItemBackup {
    static func validate(in context: NSManagedObjectContext) throws -> Set<String> {
        let rows = try CareItemStore.rows(in: context)
        let records = try context.fetch(CDRecord.fetchRequest())
        let recordsByID = Dictionary(uniqueKeysWithValues: records.compactMap { row in row.id.map { ($0, row) } })
        let reminders = try context.fetch(CDReminder.fetchRequest())
        let remindersByID = Dictionary(uniqueKeysWithValues: reminders.compactMap { row in row.id.map { ($0, row) } })
        var files = Set<String>(), reminderOwners = Set<UUID>()
        var quickCounts: [UUID: Int] = [:], instructionPets = Set<UUID>()
        for row in rows {
            guard let id = row.id, let petID = row.petID, let raw = row.payload,
                  let category = row.category.flatMap(CareItemCategory.init(rawValue:)) else { throw BackupError.damaged }
            let data = Data(raw.utf8)
            do { try CareItemStore.validateIdentity(data, id: id, petID: petID) }
            catch { throw BackupError.damaged }
            switch category {
            case .quickAction:
                guard let value = try? JSONDecoder().decode(QuickAction.self, from: data), value.validationError == nil else { throw BackupError.damaged }
                quickCounts[petID, default: 0] += 1
                guard quickCounts[petID, default: 0] <= QuickActionRepository.maximumCount else { throw BackupError.damaged }
            case .medicalDocument:
                guard let value = try? JSONDecoder().decode(MedicalDocument.self, from: data), value.validationError == nil,
                      files.insert(value.fileName).inserted else { throw BackupError.damaged }
                if let recordID = value.recordID {
                    guard let record = recordsByID[recordID], record.petID == petID,
                          MedicalReport.healthKinds.contains(where: { $0.rawValue == record.kind }) else { throw BackupError.damaged }
                }
            case .careInstructions:
                guard let value = try? JSONDecoder().decode(CareInstructions.self, from: data), value.validationError == nil,
                      instructionPets.insert(petID).inserted else { throw BackupError.damaged }
            case .medicationCourse:
                guard let value = try? JSONDecoder().decode(MedicationCourse.self, from: data), value.validationError == nil else { throw BackupError.damaged }
                for reminderID in value.reminderIDs {
                    guard reminderOwners.insert(reminderID).inserted,
                          let reminder = remindersByID[reminderID], reminder.petID == petID,
                          reminder.type == ReminderType.medication.rawValue, reminder.sourceRecordID == nil else { throw BackupError.damaged }
                }
                for time in value.times {
                    guard let reminder = remindersByID[time.reminderID], reminder.hour == time.hour, reminder.minute == time.minute,
                          reminder.isEnabled == (value.status == .active), let rawRule = reminder.repeatRule,
                          let rule = try? JSONDecoder().decode(RepeatRule.self, from: Data(rawRule.utf8)),
                          rule == .dailyWindow(start: value.startDate, end: value.endDate) else { throw BackupError.damaged }
                }
                guard value.archivedReminderIDs.allSatisfy({ remindersByID[$0]?.isEnabled == false }) else { throw BackupError.damaged }
            }
        }
        return files
    }

    static func renameMedicalFiles(in context: NSManagedObjectContext, using names: [String: String]) throws {
        for row in try CareItemStore.rows(in: context) where row.category == CareItemCategory.medicalDocument.rawValue {
            guard let raw = row.payload, var value = try? JSONDecoder().decode(MedicalDocument.self, from: Data(raw.utf8)),
                  let renamed = names[value.fileName] else { throw BackupError.damaged }
            value.fileName = renamed
            row.payload = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        }
    }

    /// 删除健康记录只解除资料关联，医疗原件仍留在资料夹。
    static func detachRecord(_ recordID: UUID, in context: NSManagedObjectContext) throws {
        for row in try CareItemStore.rows(in: context) where row.category == CareItemCategory.medicalDocument.rawValue {
            guard let raw = row.payload, var value = try? JSONDecoder().decode(MedicalDocument.self, from: Data(raw.utf8)) else { throw CareItemError.invalidPayload }
            if value.recordID == recordID {
                value.recordID = nil
                row.payload = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
            }
        }
    }
}
