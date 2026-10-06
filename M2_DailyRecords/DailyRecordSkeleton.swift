import Foundation
import Combine
import CoreData
import SwiftUI

// MARK: - 模板定义
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

/// 顺序由 fields 数组保存。历史记录独立于之后的模板改名、改字段和删除。
struct RecordTemplateSnapshot: Equatable, Codable {
    var version = 1
    let templateID: UUID
    let name: String
    let fields: [CustomTemplate.Field]
    init(template: CustomTemplate) {
        templateID = template.id; name = template.name; fields = template.fields
    }
    var templateFields: [TemplateField] {
        CustomTemplate(id: templateID, name: name, fields: fields).templateFields
    }
}

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
        try stack.transaction {
            if try find(template.id) == nil, try all().count >= Self.maxCount {
                throw CustomTemplateError.limitExceeded
            }
            let e = try find(template.id) ?? stack.insert(CDCustomTemplate.self)
            e.id = template.id; e.name = template.name; e.createdAt = template.createdAt
            e.payload = String(data: try JSONEncoder().encode(template), encoding: .utf8)
        }
    }
    func delete(id: UUID) throws {
        try stack.transaction { if let e = try find(id) { ctx.delete(e) } }
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
        case .checkup: return [.text("hospital", "体检医院"), .text("conclusion", "结论")]
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
    var templateSnapshot: RecordTemplateSnapshot?
    var createdAt = Date()
    var fields: [TemplateField] {
        if kind != .custom { return kind.fields }
        if let templateSnapshot { return templateSnapshot.templateFields }
        // 旧记录没有字段定义，保留全部原始答案；不猜测已改变的模板含义。
        return answers.keys.sorted().enumerated().map {
            .text($0.element, "历史字段 \($0.offset + 1)（\($0.element.prefix(8))）")
        }
    }
    var summary: String {
        fields.compactMap { answers[$0.key] }.filter { !$0.isEmpty }
            .prefix(2).joined(separator: " · ")
    }
    /// 展示用类型名：自定义记录显示模板名，预设显示枚举文案
    var displayKind: String { templateSnapshot?.name ?? templateName ?? kind.rawValue }
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
        if r.photoFileNames.count > MediaPolicy.maxPhotos { e.append("最多附加9张图片") }
        for f in fields ?? r.fields {
            let value = r.answers[f.key] ?? ""
            if f.isRequired && value.isEmpty {
                e.append("「\(f.title)」为必填项")
                continue
            }
            // M-02：非空 number 字段必须可解析且在合理范围内，杜绝脏数据进入统计/图表
            if case .number = f.kind, !value.isEmpty {
                guard let n = Double(value), numberRange.contains(n) else {
                    e.append("「\(f.title)」需为 0.1-100000 之间的数字")
                    continue
                }
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
    private let deletePhoto: (String) -> Void
    private var subjects: [UUID: CurrentValueSubject<[Record], Never>] = [:]
    private var changeObserver: NSObjectProtocol?
    init(stack: CoreDataStack = .shared, deletePhoto: @escaping (String) -> Void = AvatarStore.delete) {
        self.stack = stack
        self.deletePhoto = deletePhoto
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
    private func saveContext(_ changes: () throws -> Void) throws {
        try stack.transaction(changes)
        NotificationCenter.default.post(name: .recordsDidChange, object: nil)
    }
    func create(_ record: Record) throws {
        try saveContext { try record.apply(to: stack.insert(CDRecord.self)) }
        reload(record.petID)
    }
    func update(_ record: Record) throws {   // M-01：保留原 createdAt，原位更新
        let r = CDRecord.fetchRequest(); r.predicate = NSPredicate(format: "id == %@", record.id as CVarArg)
        var removedPhotos: [String] = []
        try saveContext {
            guard let e = try ctx.fetch(r).first else { throw RepositoryError.notFound }
            removedPhotos = (e.photoFileNames ?? []).filter { !record.photoFileNames.contains($0) }
            try record.apply(to: e)
        }
        removedPhotos.forEach(deletePhoto)
        reload(record.petID)
    }
    func delete(id: UUID) throws {
        let r = CDRecord.fetchRequest(); r.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        var petID: UUID?
        var photos: [String] = []
        try saveContext {
            guard let e = try ctx.fetch(r).first else { return }
            petID = e.petID
            photos = e.photoFileNames ?? []
            ctx.delete(e)
        }
        photos.forEach(deletePhoto)
        if let petID { reload(petID) }
    }
}

private extension Record {   // 值类型 <-> CDRecord 映射
    init(_ e: CDRecord) {
        self.init(id: e.id ?? UUID(), petID: e.petID ?? UUID(),
                  kind: RecordKind(rawValue: e.kind ?? "") ?? .feeding,
                  answers: e.answers ?? [:], note: e.note ?? "", mood: e.mood ?? "",
                  photoFileNames: e.photoFileNames ?? [], templateName: e.templateName,
                  templateSnapshot: e.templateSnapshot.flatMap { try? JSONDecoder().decode(RecordTemplateSnapshot.self, from: Data($0.utf8)) },
                  createdAt: e.createdAt ?? Date())
    }
    func apply(to e: CDRecord) throws {
        e.id = id; e.petID = petID; e.kind = kind.rawValue; e.answers = answers
        e.note = note; e.mood = mood; e.photoFileNames = photoFileNames
        e.templateName = templateName; e.createdAt = createdAt
        e.templateSnapshot = try templateSnapshot.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
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
    @Published private(set) var pendingPhotos: [PendingRecordPhoto] = []
    private let repo: RecordRepository
    private let isEditing: Bool
    private let savePhoto: (UIImage) throws -> String
    private let deletePhoto: (String) -> Void
    private var hasSaved = false
    init(repo: RecordRepository, petID: UUID, kind: RecordKind,
         editing: Record? = nil, template: CustomTemplate? = nil,
         savePhoto: @escaping (UIImage) throws -> String = { try AvatarStore.save($0) },
         deletePhoto: @escaping (String) -> Void = AvatarStore.delete) {
        self.repo = repo; isEditing = editing != nil
        self.savePhoto = savePhoto; self.deletePhoto = deletePhoto
        draft = editing ?? Record(petID: petID, kind: kind)
        if editing == nil, let template {
            draft.templateName = template.name
            draft.templateSnapshot = RecordTemplateSnapshot(template: template)
        }
        if editing == nil {
            for field in draft.fields {
                if case .toggle = field.kind { draft.answers[field.key] = "false" }
                if case .date = field.kind, field.isRequired {
                    draft.answers[field.key] = RecordAnswerDate.table.string(from: Date())
                }
            }
        }
    }
    var photoCount: Int { draft.photoFileNames.count + pendingPhotos.count }
    @discardableResult func addPhoto(_ data: Data) -> Bool {
        guard photoCount < MediaPolicy.maxPhotos else { errors = ["最多附加9张图片"]; return false }
        guard MediaPolicy.isValidPhoto(data) else { errors = ["单张图片不能超过10MB"]; return false }
        guard let image = UIImage(data: data) else { errors = ["无法读取图片，请重新选择"]; return false }
        pendingPhotos.append(PendingRecordPhoto(image: image)); errors = []
        return true
    }
    func removePendingPhoto(id: UUID) { pendingPhotos.removeAll { $0.id == id } }
    func reportPhotoError() { errors = ["图片加载失败，请重新选择"] }
    @discardableResult func save() -> Bool {
        guard !hasSaved else { return true }
        errors = RecordValidator.errors(for: draft)
        if photoCount > MediaPolicy.maxPhotos { errors.append("最多附加9张图片") }
        guard errors.isEmpty else { return false }
        var files: [String] = []
        do {
            for photo in pendingPhotos { files.append(try savePhoto(photo.image)) }
            var saved = draft; saved.photoFileNames += files
            isEditing ? try repo.update(saved) : try repo.create(saved)
            draft = saved; pendingPhotos = []; hasSaved = true
            return true
        } catch {
            files.forEach(deletePhoto)
            errors = ["保存失败，请重试。原记录与照片已保留。"]
            return false
        }
    }
}

struct PendingRecordPhoto: Identifiable {
    let id = UUID()
    let image: UIImage
}
