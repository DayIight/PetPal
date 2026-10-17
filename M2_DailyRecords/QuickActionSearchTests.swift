import XCTest
@testable import PetPal

final class QuickActionTests: XCTestCase {
    func test_draftHasFreshIdentityAndTimeAndClearsEventSpecificFields() throws {
        let petID = UUID(), now = Date(timeIntervalSince1970: 1_800_000_000)
        var old = PetPal.Record(petID: petID, kind: .vaccine,
            answers: ["vaccineName": "狂犬疫苗", "hospital": "动物医院", "nextDue": "2028-01-01"],
            note: "常用备注", mood: "😊", photoFileNames: ["old.jpg"],
            createdAt: now.addingTimeInterval(-1000), occurredAt: now.addingTimeInterval(-500))
        old.completedReminderID = UUID(); old.completedDueAt = old.eventDate; old.completedDay = "old-day"
        old.wantsNextReminder = true; old.nextReminderHour = 18; old.nextReminderMinute = 30
        let action = QuickAction(name: "常用疫苗", record: old)
        let draft = try action.makeDraft(petID: petID, now: now)
        XCTAssertNotEqual(draft.id, old.id)
        XCTAssertEqual(draft.createdAt, now); XCTAssertEqual(draft.eventDate, now)
        XCTAssertEqual(draft.answers["vaccineName"], "狂犬疫苗")
        XCTAssertEqual(draft.answers["hospital"], "动物医院")
        XCTAssertNil(draft.answers["nextDue"])
        XCTAssertEqual(draft.note, old.note); XCTAssertEqual(draft.mood, old.mood)
        XCTAssertTrue(draft.photoFileNames.isEmpty)
        XCTAssertNil(draft.completedReminderID); XCTAssertNil(draft.completedDueAt); XCTAssertNil(draft.completedDay)
        XCTAssertFalse(draft.wantsNextReminder)
        XCTAssertEqual(draft.nextReminderHour, 9); XCTAssertEqual(draft.nextReminderMinute, 0)
        XCTAssertThrowsError(try action.makeDraft(petID: UUID(), now: now))
    }

    func test_customDraftKeepsSchemaButDropsDateAnswers() throws {
        let field = CustomTemplate.Field(title: "下次日期", type: .date)
        let text = CustomTemplate.Field(title: "地点", type: .text)
        let template = CustomTemplate(name: "自定义照护", fields: [field, text])
        let record = PetPal.Record(petID: UUID(), kind: .custom,
            answers: [field.id.uuidString: "2026-01-01", text.id.uuidString: "家中"],
            templateName: template.name, templateID: template.id, templateSnapshot: template,
            templateSchemaVersion: 1)
        let draft = try QuickAction(name: "照护", record: record).makeDraft(petID: record.petID)
        XCTAssertEqual(draft.templateSnapshot, template)
        XCTAssertEqual(draft.templateName, template.name)
        XCTAssertNil(draft.answers[field.id.uuidString])
        XCTAssertEqual(draft.answers[text.id.uuidString], "家中")
    }

    func test_namedFavoriteKeepsSavedSnapshotWhenLaterRecordDiffers() throws {
        let petID = UUID()
        var source = PetPal.Record(petID: petID, kind: .feeding,
            answers: ["food": "早餐粮", "grams": "50", "mealTime": "早"])
        let favorite = QuickAction(name: "早餐", record: source)
        source.answers = ["food": "晚餐粮", "grams": "100", "mealTime": "晚"]
        let draft = try favorite.makeDraft(petID: petID)
        XCTAssertEqual(draft.answers["food"], "早餐粮")
        XCTAssertEqual(draft.answers["grams"], "50")
        XCTAssertEqual(draft.answers["mealTime"], "早")
        XCTAssertNotEqual(try favorite.makeDraft(petID: petID).id, draft.id)
    }

    func test_perPetLimitPersistenceRenameDeleteAndIsolation() throws {
        let stack = CoreDataStack(inMemory: true), pets = CoreDataPetRepository(stack: stack)
        let a = Pet(nickname: "甲", breed: "柯基"), b = Pet(nickname: "乙", breed: "猫")
        try pets.create(a); try pets.create(b)
        let repository = QuickActionRepository(store: CareItemStore(stack: stack))
        for index in 0..<6 {
            try repository.save(QuickAction(name: "早餐\(index)", record: PetPal.Record(petID: a.id)))
        }
        XCTAssertThrowsError(try repository.save(QuickAction(name: "第七项", record: PetPal.Record(petID: a.id))))
        try repository.save(QuickAction(name: "乙早餐", record: PetPal.Record(petID: b.id)))
        let reopened = QuickActionRepository(store: CareItemStore(stack: stack))
        XCTAssertEqual(try reopened.actions(petID: a.id).count, 6)
        XCTAssertEqual(try reopened.actions(petID: b.id).map(\.name), ["乙早餐"])
        var first = try XCTUnwrap(reopened.actions(petID: a.id).first)
        first.name = "改名"
        try reopened.save(first)
        XCTAssertEqual(try reopened.actions(petID: a.id).first?.name, "改名")
        XCTAssertThrowsError(try reopened.delete(id: first.id, petID: b.id))
        try reopened.delete(id: first.id, petID: a.id)
        XCTAssertEqual(try reopened.actions(petID: a.id).count, 5)
        XCTAssertEqual(try reopened.actions(petID: b.id).count, 1)
    }

    func test_codablePayloadRejectsInvalidNamesAndUnknownKinds() throws {
        let action = QuickAction(name: "早餐", record: PetPal.Record(petID: UUID()))
        XCTAssertEqual(try JSONDecoder().decode(QuickAction.self, from: JSONEncoder().encode(action)), action)
        var invalid = action; invalid.name = "  "
        XCTAssertNotNil(invalid.validationError)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(action)) as? [String: Any])
        object["kindRawValue"] = "不存在的类型"
        invalid = try JSONDecoder().decode(QuickAction.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNotNil(invalid.validationError)
    }
}

final class RecordSearchTests: XCTestCase {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return result
    }
    private func date(_ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: minute))!
    }

    func test_textMatchesTypeTemplateAnswerAndNoteWhileScopingPet() {
        let petID = UUID()
        let records = [
            PetPal.Record(petID: petID, kind: .walking, answers: ["place": "湖边"]),
            PetPal.Record(petID: petID, kind: .custom, note: "Café 后休息", templateName: "晚间护理"),
            PetPal.Record(petID: UUID(), kind: .walking, answers: ["place": "湖边"])
        ]
        for query in ["遛弯", "湖边", "晚间护理", "CAFE"] {
            XCTAssertEqual(RecordSearchFilter(query: query).results(in: records, petID: petID).count, 1)
        }
        XCTAssertTrue(RecordSearchFilter(query: "不存在").results(in: records, petID: petID).isEmpty)
    }

    func test_combinedFiltersIncludeWholeBoundaryDaysAcrossDST() {
        let petID = UUID()
        let first = PetPal.Record(petID: petID, kind: .walking, note: "湖边", occurredAt: date(7, 0))
        let last = PetPal.Record(petID: petID, kind: .walking, note: "湖边", occurredAt: date(8, 23, 59))
        let records = [first, last,
            PetPal.Record(petID: petID, kind: .walking, note: "湖边", occurredAt: date(9, 0)),
            PetPal.Record(petID: petID, kind: .feeding, note: "湖边", occurredAt: date(8))]
        let filter = RecordSearchFilter(query: "湖边", kind: .walking, startDate: date(7, 18), endDate: date(8, 1))
        XCTAssertEqual(filter.results(in: records, petID: petID, calendar: calendar).map(\.id), [last.id, first.id])
    }

    func test_invalidRangeReturnsNoResultsAndResetRestoresUnfilteredMode() {
        let petID = UUID(), record = PetPal.Record(petID: UUID())
        var filter = RecordSearchFilter(query: "粮", kind: .feeding, startDate: date(9), endDate: date(8))
        XCTAssertNotNil(filter.validationError(calendar: calendar))
        XCTAssertTrue(filter.results(in: [record], petID: petID, calendar: calendar).isEmpty)
        filter.reset()
        XCTAssertFalse(filter.isActive)
        XCTAssertNil(filter.validationError(calendar: calendar))
    }
}
