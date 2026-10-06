import Foundation
import Combine
import CoreData
import SwiftUI

// MARK: - 模板定义（纯代码元数据；自定义模板延后，kind 预留 .custom）
struct TemplateField {
    enum Kind { case text, multiline, number, single([String]), multi([String]), toggle, date }
    let key: String, title: String, kind: Kind, isRequired: Bool
    static func text(_ k: String, _ t: String, _ r: Bool = false) -> Self { .init(key: k, title: t, kind: .text, isRequired: r) }
    static func multiline(_ k: String, _ t: String, _ r: Bool = false) -> Self { .init(key: k, title: t, kind: .multiline, isRequired: r) }
    static func number(_ k: String, _ t: String, _ r: Bool = false) -> Self { .init(key: k, title: t, kind: .number, isRequired: r) }
    static func single(_ k: String, _ t: String, _ o: [String], _ r: Bool = false) -> Self { .init(key: k, title: t, kind: .single(o), isRequired: r) }
    static func multi(_ k: String, _ t: String, _ o: [String], _ r: Bool = false) -> Self { .init(key: k, title: t, kind: .multi(o), isRequired: r) }
    static func toggle(_ k: String, _ t: String, _ r: Bool = false) -> Self { .init(key: k, title: t, kind: .toggle, isRequired: r) }
    static func date(_ k: String, _ t: String, _ r: Bool = false) -> Self { .init(key: k, title: t, kind: .date, isRequired: r) }
}

// MARK: - 自定义模板（≤20 个；payload 以 JSON 存 CDCustomTemplate，7 种字段类型全量支持）
struct CustomTemplate: Identifiable, Equatable, Codable {
    var id = UUID()
    var name: String
    var fields: [Field]
    var createdAt = Date()

    struct Field: Identifiable, Equatable, Codable {
        var id = UUID()
        var title: String
        var type: FieldType
        var options: [String] = []       // 仅 single/multi 使用
        var isRequired = false
    }
    enum FieldType: String, Codable, CaseIterable {
        case text, multiline, number, single, multi, toggle, date
    }
    /// 转为模板字段渲染/校验通用的 TemplateField（key 用字段 id，避免同名冲突）
    var templateFields: [TemplateField] {
        fields.map { f in
            let k = f.id.uuidString
            switch f.type {
            case .text: return .text(k, f.title, f.isRequired)
            case .multiline: return .multiline(k, f.title, f.isRequired)
            case .number: return .number(k, f.title, f.isRequired)
            case .single: return .single(k, f.title, f.options, f.isRequired)
            case .multi: return .multi(k, f.title, f.options, f.isRequired)
            case .toggle: return .toggle(k, f.title, f.isRequired)
            case .date: return .date(k, f.title, f.isRequired)
            }
        }
    }
}

enum CustomTemplateError: Error { case limitExceeded, emptyName, noFields }

protocol CustomTemplateRepository: AnyObject {
    func all() throws -> [CustomTemplate]
    func save(_ template: CustomTemplate) throws   // 新增超过 20 个抛 limitExceeded
    func delete(id: UUID) throws
}

final class CoreDataCustomTemplateRepository: CustomTemplateRepository {
    static let maxCount = 20
    private let stack: CoreDataStack
    init(stack: CoreDataStack = .shared) { self.stack = stack }
    private var ctx: NSManagedObjectContext { stack.container.viewContext }
    func all() throws -> [CustomTemplate] {
        let r = CDCustomTemplate.fetchRequest()
        r.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        return try ctx.fetch(r).compactMap(Self.decode)
    }
    func save(_ template: CustomTemplate) throws {
        if try find(template.id) == nil, try all().count >= Self.maxCount {
            throw CustomTemplateError.limitExceeded
        }
        let payload = String(data: try JSONEncoder().encode(template), encoding: .utf8)
        let e = try find(template.id) ?? stack.insert(CDCustomTemplate.self)
        e.id = template.id; e.name = template.name; e.createdAt = template.createdAt
        e.payload = payload
        try stack.save()
    }
    func delete(id: UUID) throws {
        if let e = try find(id) { ctx.delete(e); try stack.save() }
    }
    private func find(_ id: UUID) throws -> CDCustomTemplate? {
        let r = CDCustomTemplate.fetchRequest(); r.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return try ctx.fetch(r).first
    }
    private static func decode(_ e: CDCustomTemplate) -> CustomTemplate? {
        guard let payload = e.payload, let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CustomTemplate.self, from: data)
    }
}

enum RecordKind: String, CaseIterable, Identifiable {
    case feeding = "喂食", walking = "遛弯", training = "训练", deworming = "驱虫"
    case vaccine = "疫苗", checkup = "体检", grooming = "美容"
    case custom = "自定义"   // 自定义模板产生的记录；模板选择器需过滤掉本项
    var id: String { rawValue }
    static let presetCases: [RecordKind] = allCases.filter { $0 != .custom }
    var fields: [TemplateField] {
        switch self {
        case .custom: return []   // 字段由 CustomTemplate.templateFields 提供
        case .feeding: return [.text("food", "食物类型", true), .number("grams", "克数", true),
                               .single("mealTime", "用餐时段", ["早", "午", "晚"], true)]
        case .walking: return [.number("minutes", "时长(分钟)"), .text("place", "地点")]
        case .training: return [.text("subject", "训练科目", true), .number("minutes", "时长(分钟)")]
        case .deworming: return [.text("drug", "药品名", true), .date("nextDue", "下次日期")]
        case .vaccine: return [.text("vaccineName", "疫苗名称", true), .text("hospital", "接种医院"),
                               .date("nextDue", "下次截止")]
        case .checkup: return [.text("hospital", "体检医院"), .text("conclusion", "结论"),
                               .number("weightKg", "体重(kg)")]   // 保存时自动抽取到 WeightRepository（GAP-07）
        case .grooming: return [.text("items", "美容项目"), .text("shop", "门店")]
        }
    }
}

// MARK: - 值类型模型
struct Record: Identifiable, Equatable {
    var id = UUID()
    var petID: UUID = UUID()          // 必须关联具体宠物
    var kind: RecordKind = .feeding
    var answers: [String: String] = [:]
    var note = ""                     // ≤200 字
    var mood = ""                     // 1 个预设表情或自定义文本
    var photoFileNames: [String] = [] // ≤9 张
    var templateName: String?         // kind == .custom 时的模板名快照
    var templateID: UUID?
    var templateSnapshot: CustomTemplate?
    var templateSchemaVersion = 0
    var createdAt = Date()
    var wantsNextReminder = false
    var nextReminderHour = 9
    var nextReminderMinute = 0
    var summary: String { answers.values.prefix(2).joined(separator: " · ") }
    /// 展示用类型名：自定义记录显示模板名，预设显示枚举文案
    var displayKind: String { templateName ?? kind.rawValue }
}

// MARK: - 校验与媒体策略
enum MediaPolicy {
    static let maxPhotos = 9, maxPhotoBytes = 10 * 1024 * 1024
    static func isValidPhoto(_ data: Data) -> Bool { data.count <= maxPhotoBytes } // 类型由 PhotosPicker 过滤
}

enum RecordValidator {
    /// M-02：number 字段合法范围（克数/分钟等业务量级，超出视为脏数据）
    static let numberRange: ClosedRange<Double> = 0.1...100_000
    /// fields 缺省取预设模板字段；自定义模板记录传入 CustomTemplate.templateFields
    static func errors(for r: Record, fields: [TemplateField]? = nil) -> [String] {
        var e: [String] = []
        if r.note.count > 200 { e.append("备注最多200字") }
        if r.mood.count > 10 { e.append("心情标签最多10个字") }
        if r.photoFileNames.count > MediaPolicy.maxPhotos { e.append("最多附加9张图片") }
        for f in fields ?? r.kind.fields {
            let value = r.answers[f.key] ?? ""
            if f.isRequired && value.isEmpty {
                e.append("「\(f.title)」为必填项")
                continue
            }
            // M-02：非空 number 字段必须可解析且在合理范围内，杜绝脏数据进入统计/图表
            if case .number = f.kind, !value.isEmpty {
                let range = r.kind == .checkup && f.key == WeightExtraction.checkupWeightKey ? WeightValidator.kgRange : numberRange
                guard let n = Double(value), range.contains(n) else {
                    e.append(r.kind == .checkup && f.key == WeightExtraction.checkupWeightKey ? "体重需在0.1–100kg之间" : "「\(f.title)」需为 0.1-100000 之间的数字")
                    continue
                }
            }
        }
        if r.wantsNextReminder {
            guard r.kind == .vaccine || r.kind == .deworming,
                  let raw = r.answers["nextDue"], let date = RecordAnswerDate.parse(raw),
                  let due = Calendar.current.date(bySettingHour: r.nextReminderHour, minute: r.nextReminderMinute, second: 0, of: date), due > Date() else {
                e.append("下次提醒请选择未来日期和时间"); return e
            }
        }
        return e
    }
}

// MARK: - 时间轴分组（纯函数：日倒序，组内 createdAt 倒序）
enum TimelineGrouper {
    static func group(_ records: [Record]) -> [(day: Date, items: [Record])] {
        Dictionary(grouping: records) { Calendar.current.startOfDay(for: $0.createdAt) }
            .sorted { $0.key > $1.key }
            .map { ($0.key, $0.value.sorted { $0.createdAt > $1.createdAt }) }
    }
}

// MARK: - 日历月视图（纯函数：月网格 + 每日打卡计数）
struct CalendarDay: Equatable, Identifiable {
    let id: String    // 稳定身份：占位格 "blank-N"、日格 "d-<时间戳>"（随机 UUID 会导致 SwiftUI 无限重渲染）
    let date: Date?   // nil = 月外占位格
    let count: Int    // 当日记录数（0 = 无圆点）
}

enum CalendarGridBuilder {
    /// 记录 → [日（startOfDay): 当日条数]
    static func countsByDay(_ records: [Record]) -> [Date: Int] {
        Dictionary(grouping: records) { Calendar.current.startOfDay(for: $0.createdAt) }
            .mapValues(\.count)
    }
    /// 生成含 date 的月份的 7 列网格：月外占位格（nil）+ 当月每天，携带打卡数
    static func month(containing date: Date, counts: [Date: Int],
                      calendar: Calendar = .current) -> [CalendarDay] {
        let comps = calendar.dateComponents([.year, .month], from: date)
        guard let first = calendar.date(from: comps),
              let range = calendar.range(of: .day, in: .month, for: first) else { return [] }
        let weekday = calendar.component(.weekday, from: first)          // 1=周日
        let leading = (weekday - calendar.firstWeekday + 7) % 7          // 月前占位格数
        var days: [CalendarDay] = (0..<leading).map { CalendarDay(id: "blank-\($0)", date: nil, count: 0) }
        for day in range {
            guard let d = calendar.date(byAdding: .day, value: day - 1, to: first) else { continue }
            let dayStart = calendar.startOfDay(for: d)
            days.append(CalendarDay(id: "d-\(dayStart.timeIntervalSince1970)",
                                    date: d, count: counts[dayStart] ?? 0))
        }
        return days
    }
    /// 月份偏移（横向滚动历史月份用）：offset -1 = 上一个月
    static func month(offset: Int, from base: Date = Date(),
                      calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .month, value: offset, to: base) ?? base
    }
}

// MARK: - Repository 边界（仅按宠物维度查询，杜绝跨宠物）
protocol RecordRepository: AnyObject {
    func recordsPublisher(petID: UUID) -> AnyPublisher<[Record], Never>
    func create(_ record: Record) throws
    func update(_ record: Record) throws   // M-01：编辑入口（详情页复用表单）
    func delete(id: UUID) throws
}

// CDRecord：id/petID UUID、kind String、answers/photoFileNames Transformable、note/mood String、createdAt Date
extension Notification.Name { static let recordsDidChange = Notification.Name("PetPal.recordsDidChange") }

final class CoreDataRecordRepository: RecordRepository {
    private let stack: CoreDataStack
    private var subjects: [UUID: CurrentValueSubject<[Record], Never>] = [:]
    private var changeObserver: NSObjectProtocol?
    init(stack: CoreDataStack = .shared) {
        self.stack = stack
        // 表单/时间轴/日历/看板各自实例化 repository：任一实例写库后广播，其余存活实例重载已订阅的 petID
        changeObserver = NotificationCenter.default.addObserver(
            forName: .recordsDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.reloadAll() }
    }
    deinit { if let o = changeObserver { NotificationCenter.default.removeObserver(o) } }
    private var ctx: NSManagedObjectContext { stack.container.viewContext }
    func recordsPublisher(petID: UUID) -> AnyPublisher<[Record], Never> {
        if subjects[petID] == nil { subjects[petID] = .init([]) }
        reload(petID); return subjects[petID]!.eraseToAnyPublisher()
    }
    private func reloadAll() { subjects.keys.forEach(reload) }
    private func reload(_ petID: UUID) {
        let r = CDRecord.fetchRequest()
        r.predicate = NSPredicate(format: "petID == %@", petID as CVarArg)
        r.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        subjects[petID]?.send(((try? ctx.fetch(r)) ?? []).map(Record.init))
    }
    private func saveContext() throws {
        try stack.save()
        NotificationCenter.default.post(name: .recordsDidChange, object: nil)
        NotificationCenter.default.post(name: .weightsDidChange, object: nil)
        NotificationCenter.default.post(name: .petsDidChange, object: nil)
        NotificationCenter.default.post(name: .remindersDidChange, object: nil)
    }
    private func linkedWeights(_ id: UUID) throws -> [CDWeightSample] {
        let request = CDWeightSample.fetchRequest(); request.predicate = NSPredicate(format: "sourceRecordID == %@", id as CVarArg)
        return try ctx.fetch(request)
    }
    private func linkedReminders(_ id: UUID) throws -> [CDReminder] {
        let request = CDReminder.fetchRequest(); request.predicate = NSPredicate(format: "sourceRecordID == %@", id as CVarArg)
        return try ctx.fetch(request)
    }
    private func synchronizeDerivedData(_ record: Record) throws {
        let weights = try linkedWeights(record.id)
        let reminders = try linkedReminders(record.id)
        if let sample = WeightExtraction.sample(from: record) {
            let e = weights.first ?? stack.insert(CDWeightSample.self)
            e.id = e.id ?? UUID(); e.petID = sample.petID; e.kg = sample.kg; e.date = sample.date; e.sourceRecordID = record.id
            weights.dropFirst().forEach(ctx.delete)
        } else { weights.forEach(ctx.delete) }
        if record.wantsNextReminder, record.kind == .vaccine || record.kind == .deworming,
           let raw = record.answers["nextDue"], let date = RecordAnswerDate.parse(raw),
           let due = Calendar.current.date(bySettingHour: record.nextReminderHour, minute: record.nextReminderMinute, second: 0, of: date) {
            let petRequest = CDPet.fetchRequest(); petRequest.predicate = NSPredicate(format: "id == %@", record.petID as CVarArg)
            let name = try ctx.fetch(petRequest).first?.nickname ?? "宠物"
            let existing = reminders.first
            let reminder = Reminder(id: existing?.id ?? UUID(), petID: record.petID, petName: name,
                type: record.kind == .vaccine ? .vaccine : .deworming, hour: record.nextReminderHour, minute: record.nextReminderMinute,
                repeatRule: .once(at: due), advance: AdvanceOption(rawValue: existing?.advance ?? "") ?? .none,
                isEnabled: existing?.isEnabled ?? true, sourceRecordID: record.id)
            reminder.apply(to: existing ?? stack.insert(CDReminder.self))
            reminders.dropFirst().forEach(ctx.delete)
        } else { reminders.forEach(ctx.delete) }
    }
    private func validate(_ record: Record) throws {
        let relevantErrors = RecordValidator.errors(for: record, fields: record.kind == .checkup ? record.kind.fields : [])
        if let error = relevantErrors.first {
            throw NSError(domain: "PetPal.Record", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
        }
    }
    func create(_ record: Record) throws {
        try validate(record)
        do {
            record.apply(to: stack.insert(CDRecord.self)); try synchronizeDerivedData(record)
            try saveContext(); reload(record.petID)
        } catch { ctx.rollback(); throw error }
    }
    func update(_ record: Record) throws {
        try validate(record)
        let request = CDRecord.fetchRequest(); request.predicate = NSPredicate(format: "id == %@", record.id as CVarArg)
        guard let e = try ctx.fetch(request).first, e.petID == record.petID else { throw DataStoreError.missingItem }
        do { record.apply(to: e); try synchronizeDerivedData(record); try saveContext(); reload(record.petID) }
        catch { ctx.rollback(); throw error }
    }
    func delete(id: UUID) throws {
        let request = CDRecord.fetchRequest(); request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        guard let e = try ctx.fetch(request).first, let petID = e.petID else { throw DataStoreError.missingItem }
        let weights = try linkedWeights(id); let reminders = try linkedReminders(id)
        let files = e.photoFileNames ?? []
        ctx.delete(e); weights.forEach(ctx.delete); reminders.forEach(ctx.delete)
        try saveContext(); reload(petID)
        files.forEach(AvatarStore.delete(fileName:))
    }
}

private extension Record {   // 值类型 <-> CDRecord 映射
    init(_ e: CDRecord) {
        self.init(id: e.id ?? UUID(), petID: e.petID ?? UUID(),
                  kind: RecordKind(rawValue: e.kind ?? "") ?? .feeding,
                  answers: e.answers ?? [:], note: e.note ?? "", mood: e.mood ?? "",
                  photoFileNames: e.photoFileNames ?? [], templateName: e.templateName, templateID: e.templateID,
                  templateSnapshot: e.templateSnapshot.flatMap { try? JSONDecoder().decode(CustomTemplate.self, from: Data($0.utf8)) },
                  templateSchemaVersion: Int(e.templateSchemaVersion), createdAt: e.createdAt ?? Date(),
                  wantsNextReminder: e.wantsNextReminder, nextReminderHour: Int(e.nextReminderHour), nextReminderMinute: Int(e.nextReminderMinute))
    }
    func apply(to e: CDRecord) {
        e.id = id; e.petID = petID; e.kind = kind.rawValue; e.answers = answers
        e.note = note; e.mood = mood; e.photoFileNames = photoFileNames
        e.templateName = templateName; e.createdAt = createdAt
        e.templateID = templateID; e.templateSchemaVersion = Int16(templateSchemaVersion)
        e.templateSnapshot = templateSnapshot.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        e.wantsNextReminder = wantsNextReminder; e.nextReminderHour = Int16(nextReminderHour); e.nextReminderMinute = Int16(nextReminderMinute)
    }
}

// MARK: - ViewModel
@MainActor final class TimelineViewModel: ObservableObject {
    @Published private(set) var sections: [(day: Date, items: [Record])] = []
    // 必须持有 repo：repo deinit 会移除 recordsDidChange 观察者，广播链路随之断开
    private let repo: RecordRepository
    init(repo: RecordRepository, petID: UUID) {
        self.repo = repo
        repo.recordsPublisher(petID: petID).receive(on: DispatchQueue.main)
            .map(TimelineGrouper.group).assign(to: &$sections)
    }
}

@MainActor final class RecordFormViewModel: ObservableObject {
    @Published var draft: Record
    @Published private(set) var errors: [String] = []
    /// 本次新选、尚未落盘的照片（保存时才经 AvatarStore 压缩写盘，取消表单不留孤儿文件）
    @Published private(set) var pickedImages: [UIImage] = []
    let isEditing: Bool
    private let repo: RecordRepository
    private let weightRepo: WeightRepository?
    private let savePhoto: (UIImage) -> String?
    /// 自定义模板记录传入 CustomTemplate.templateFields；nil 时按 draft.kind.fields 校验
    private let validationFields: [TemplateField]?
    /// 编辑模式被移除的已落盘照片，保存成功后清理文件
    private var removedPhotoFileNames: [String] = []

    init(repo: RecordRepository, petID: UUID, kind: RecordKind,
         validationFields: [TemplateField]? = nil, templateName: String? = nil, templateSnapshot: CustomTemplate? = nil,
         weightRepo: WeightRepository? = nil,
         savePhoto: @escaping (UIImage) -> String? = { AvatarStore.save($0) }) {
        self.savePhoto = savePhoto
        self.repo = repo
        self.weightRepo = weightRepo
        self.validationFields = validationFields
        isEditing = false
        draft = Record(petID: petID, kind: kind, templateName: templateName, templateID: templateSnapshot?.id,
                       templateSnapshot: templateSnapshot, templateSchemaVersion: templateSnapshot == nil ? 0 : 1)
    }

    init(repo: RecordRepository, editing record: Record,
         validationFields: [TemplateField]? = nil, weightRepo: WeightRepository? = nil,
         savePhoto: @escaping (UIImage) -> String? = { AvatarStore.save($0) }) {
        self.savePhoto = savePhoto
        self.repo = repo
        self.weightRepo = weightRepo
        self.validationFields = record.templateSnapshot?.templateFields ?? validationFields
        isEditing = true
        draft = record
    }

    func addPhoto(_ data: Data) {   // >10MB 拒绝；落盘复用 M1 AvatarStore 压缩策略
        guard MediaPolicy.isValidPhoto(data) else { errors = ["单张图片不能超过10MB"]; return }
        guard let image = UIImage(data: data) else { errors = ["图片格式不支持"]; return }
        addPhoto(image)
    }

    func addPhoto(_ image: UIImage) {
        guard draft.photoFileNames.count + pickedImages.count < MediaPolicy.maxPhotos else {
            errors = ["最多附加9张图片"]; return
        }
        pickedImages.append(image)
    }

    func removePickedPhoto(at index: Int) {
        guard pickedImages.indices.contains(index) else { return }
        pickedImages.remove(at: index)
    }

    func removeSavedPhoto(_ fileName: String) {
        draft.photoFileNames.removeAll { $0 == fileName }
        removedPhotoFileNames.append(fileName)
    }

    @discardableResult func save() -> Bool {
        errors = RecordValidator.errors(for: draft, fields: validationFields)
        guard errors.isEmpty else { return false }
        // 新选照片压缩落盘（≤1080px、JPEG 0.8）；任一步失败回滚已写文件，不留孤儿
        var newNames: [String] = []
        for image in pickedImages {
            guard let name = savePhoto(image) else {
                newNames.forEach(AvatarStore.delete(fileName:))
                errors = ["图片保存失败，请重试"]; return false
            }
            newNames.append(name)
        }
        draft.photoFileNames += newNames
        do {
            isEditing ? try repo.update(draft) : try repo.create(draft)
        } catch {
            newNames.forEach(AvatarStore.delete(fileName:))
            draft.photoFileNames.removeAll { newNames.contains($0) }
            errors = ["保存失败，请重试"]; return false
        }
        removedPhotoFileNames.forEach(AvatarStore.delete(fileName:))
        return true
    }
}
