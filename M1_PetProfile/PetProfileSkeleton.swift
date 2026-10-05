import Foundation
import Combine
import CoreData
import SwiftUI

// MARK: - 物种与品种目录（物种驱动品种预设列表，自定义兜底）
enum PetSpecies: String, CaseIterable, Identifiable, Codable {
    case cat = "猫", dog = "狗", other = "其他"
    var id: String { rawValue }
}

enum BreedCatalog {
    static let cat = ["英短", "美短", "布偶", "暹罗", "橘猫", "缅因", "波斯", "折耳", "无毛猫", "狸花猫"]
    static let dog = ["柯基", "金毛", "拉布拉多", "泰迪", "柴犬", "边牧", "萨摩耶", "法斗", "哈士奇", "比熊"]
    static func breeds(for species: PetSpecies) -> [String] {
        switch species {
        case .cat: return cat
        case .dog: return dog
        case .other: return []
        }
    }
}

// MARK: - 值类型模型（层间唯一传递对象）
struct Pet: Identifiable, Equatable {
    var id = UUID()
    var species: PetSpecies = .dog   // 必填，驱动品种列表与 M2 模板过滤
    var nickname = ""                // 必填 1-20 字符
    var breed = ""                   // 必填，预设列表或自定义
    var birthday = Date()            // 必填，不得晚于今天
    var adoptionDate: Date?
    var weightKg = 1.0               // 0.1...100.0，步进0.1
    var neuterStatus: NeuterStatus = .intact
    var chipNumber: String?          // 选填，^\d{15}$
    var allergens: [String] = []     // 预设标签多选+自定义
    var vetName: String?, vetPhone: String?   // 电话 ^\+?[\d\s-]{5,20}$
    var avatarFileName: String?      // 仅存文件名，原图≤1080px存Documents
    var createdAt = Date()
}
enum NeuterStatus: String, CaseIterable, Identifiable {
    case intact = "未绝育", neutered = "已绝育", planned = "计划中"
    var id: String { rawValue }
}
enum PetField: Hashable { case nickname, breed, birthday, weight, chip, vetPhone }
enum PetSort { case nickname, createdAt }

// MARK: - 校验（纯函数，独立可测）
enum PetValidator {
    static func errors(for p: Pet) -> [PetField: String] {
        var e: [PetField: String] = [:]
        let name = p.nickname.trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name.count > 20 { e[.nickname] = "昵称需为1-20个字符" }
        if p.breed.isEmpty { e[.breed] = "请选择或填写品种" }
        if p.birthday > Date() { e[.birthday] = "生日不得晚于今天" }
        if !(0.1...100.0).contains(p.weightKg) { e[.weight] = "体重需在0.1-100.0kg之间" }
        if let c = p.chipNumber, !c.isEmpty,
           c.range(of: #"^\d{15}$"#, options: .regularExpression) == nil { e[.chip] = "芯片号需为15位数字" }
        if let t = p.vetPhone, !t.isEmpty,
           t.range(of: #"^\+?[\d\s-]{5,20}$"#, options: .regularExpression) == nil { e[.vetPhone] = "电话格式不正确" }
        return e
    }
}

// MARK: - Repository 边界（Core Data 本地；CloudKit 私有库实现可替换接入）
protocol PetRepository: AnyObject {
    var petsPublisher: AnyPublisher<[Pet], Never> { get }
    func create(_ pet: Pet) throws
    func update(_ pet: Pet) throws
    func delete(id: UUID) throws    // 调用方联动清理 M4 关联提醒
}

enum RepositoryError: Error { case notFound }

final class CoreDataStack {
    static let shared = CoreDataStack()
    let container: NSPersistentContainer
    /// 持久化加载失败时非 nil（H-03：不再静默吞错，UI 层据此展示错误态）
    private(set) var loadError: Error?
    private let persist: (NSManagedObjectContext) throws -> Void
    init(inMemory: Bool = false,
         saveContext: @escaping (NSManagedObjectContext) throws -> Void = { try $0.save() }) {
        persist = saveContext
        container = NSPersistentContainer(name: "PetPal")
        if inMemory, let description = container.persistentStoreDescriptions.first {
            description.type = NSInMemoryStoreType
            description.url = nil
        }
        container.loadPersistentStores { [weak self] _, e in
            if let e {
                self?.loadError = e
                assertionFailure("\(e)")   // Debug 下仍中断，Release 下由 UI 呈现错误态
            }
        }
    }
    /// Repository 的写入边界：保存失败清除未提交变更，避免后续操作把失败的草稿落库。
    func transaction<T>(_ changes: () throws -> T) throws -> T {
        let context = container.viewContext
        return try context.performAndWait {
            do {
                if let loadError { throw loadError }
                let result = try changes()
                try persist(context)
                return result
            } catch {
                context.rollback()
                throw error
            }
        }
    }
    /// 从本 stack 的 model 解析实体并插入 viewContext。
    /// 直接用 `CDX(context:)` 在多 container 同进程（测试场景）下会命中错误模型拷贝。
    func insert<T: NSManagedObject>(_ type: T.Type) -> T {
        let name = String(describing: type)
        guard let entity = container.managedObjectModel.entitiesByName[name] else {
            preconditionFailure("实体 \(name) 不在 PetPal 模型中")
        }
        return T(entity: entity, insertInto: container.viewContext)
    }
}

// CDPet 由 .xcdatamodeld 生成，属性与 Pet 一一对应（allergens 为 Transformable）
extension Notification.Name { static let petsDidChange = Notification.Name("PetPal.petsDidChange") }

final class CoreDataPetRepository: PetRepository {
    private let stack: CoreDataStack
    private let subject = CurrentValueSubject<[Pet], Never>([])
    private var changeObserver: NSObjectProtocol?
    var petsPublisher: AnyPublisher<[Pet], Never> { subject.eraseToAnyPublisher() }
    init(stack: CoreDataStack = .shared) {
        self.stack = stack
        reload()
        // UI 层各自实例化 repository（RootTabView 的 petListVM/currentPet、PetDetailView），
        // 共享同一底层库：任一实例写库后广播，其余实例重载，避免建档后同进程内其他实例脏读
        changeObserver = NotificationCenter.default.addObserver(
            forName: .petsDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.reload() }
    }
    deinit { if let o = changeObserver { NotificationCenter.default.removeObserver(o) } }
    private var ctx: NSManagedObjectContext { stack.container.viewContext }
    private func reload() {
        let r = CDPet.fetchRequest(); r.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        subject.send(((try? ctx.fetch(r)) ?? []).map(Pet.init))
    }
    private func save(_ changes: () throws -> Void) throws {
        try stack.transaction(changes)
        reload()
        NotificationCenter.default.post(name: .petsDidChange, object: nil)
    }
    func create(_ pet: Pet) throws { try save { pet.apply(to: stack.insert(CDPet.self)) } }
    func update(_ pet: Pet) throws {
        try save {
            guard let e = try find(pet.id) else { throw RepositoryError.notFound }
            pet.apply(to: e)
        }
    }
    // H-02 级联删除：先收集关联文件，再删 CDRecord/CDReminder/CDWeightSample/CDPet，最后清盘
    // 通知 id 由调用方先收集，数据库提交成功后再撤销通知。
    func delete(id: UUID) throws {
        var files: [String] = []
        try save {
            guard let e = try find(id) else { return }
            if let avatar = e.avatarFileName { files.append(avatar) }
            let recordReq = CDRecord.fetchRequest(); recordReq.predicate = NSPredicate(format: "petID == %@", id as CVarArg)
            let records = try ctx.fetch(recordReq)
            let reminderReq = CDReminder.fetchRequest(); reminderReq.predicate = NSPredicate(format: "petID == %@", id as CVarArg)
            let reminders = try ctx.fetch(reminderReq)
            let weightReq = CDWeightSample.fetchRequest(); weightReq.predicate = NSPredicate(format: "petID == %@", id as CVarArg)
            let weights = try ctx.fetch(weightReq)
            for r in records {
                files.append(contentsOf: r.photoFileNames ?? [])
                ctx.delete(r)
            }
            reminders.forEach(ctx.delete)
            weights.forEach(ctx.delete)
            ctx.delete(e)
        }
        NotificationCenter.default.post(name: .recordsDidChange, object: nil)
        files.forEach(AvatarStore.delete(fileName:))   // M-04：数据库落盘后再清文件
    }
    private func find(_ id: UUID) throws -> CDPet? {
        let r = CDPet.fetchRequest(); r.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return try ctx.fetch(r).first
    }
}

private extension Pet {   // 值类型 <-> CDPet 映射
    init(_ e: CDPet) {
        self.init(id: e.id ?? UUID(), species: PetSpecies(rawValue: e.species ?? "") ?? .dog,
                  nickname: e.nickname ?? "", breed: e.breed ?? "",
                  birthday: e.birthday ?? Date(), adoptionDate: e.adoptionDate, weightKg: e.weightKg,
                  neuterStatus: NeuterStatus(rawValue: e.neuterStatus ?? "") ?? .intact,
                  chipNumber: e.chipNumber, allergens: e.allergens ?? [], vetName: e.vetName,
                  vetPhone: e.vetPhone, avatarFileName: e.avatarFileName, createdAt: e.createdAt ?? Date())
    }
    func apply(to e: CDPet) {
        e.id = id; e.species = species.rawValue; e.nickname = nickname; e.breed = breed; e.birthday = birthday
        e.adoptionDate = adoptionDate; e.weightKg = weightKg; e.neuterStatus = neuterStatus.rawValue
        e.chipNumber = chipNumber; e.allergens = allergens; e.vetName = vetName
        e.vetPhone = vetPhone; e.avatarFileName = avatarFileName; e.createdAt = createdAt
    }
}

// MARK: - 头像压缩（最长边≤1080px，JPEG 0.8）与媒体文件清理（M-04）
enum AvatarStore {
    private static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    static func save(_ image: UIImage, to targetDirectory: URL? = nil) throws -> String {
        guard image.size.width > 0, image.size.height > 0 else { throw CocoaError(.fileWriteUnknown) }
        let scale = min(1, 1080 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1   // 锁定 1x：size 按像素计，否则 @3x 屏会产出 3 倍像素
        let data = UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.8) {
            _ in image.draw(in: CGRect(origin: .zero, size: size))
        }
        let name = UUID().uuidString + ".jpg"
        try data.write(to: (targetDirectory ?? directory).appendingPathComponent(name), options: .atomic)
        return name
    }
    /// 读取已落盘的头像/附件图片；文件不存在返回 nil（列表/详情展示用）
    static func load(fileName: String) -> UIImage? {
        guard !fileName.isEmpty else { return nil }
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }
    /// 已落盘图片的完整 file URL（M3 动态图片经 Kingfisher 按 URL 加载用）
    static func url(for fileName: String) -> URL {
        directory.appendingPathComponent(fileName)
    }
    /// 删除已落盘的头像/附件文件；文件不存在视为成功（幂等）
    static func delete(fileName: String) {
        guard !fileName.isEmpty else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
    }
}

// MARK: - ViewModel（@MainActor；View 只读 @Published）
@MainActor final class PetListViewModel: ObservableObject {
    @Published private(set) var pets: [Pet] = []
    @Published var sort: PetSort = .createdAt { didSet { applySort() } }
    @Published var toast: String?
    var reminderIDs: ((UUID) throws -> [UUID])?
    /// 数据库提交成功后撤销已收集的通知，失败不触碰旧调度。
    var reminderCleanup: (([UUID]) async -> Void)?
    private var deletingIDs = Set<UUID>()
    private let repo: PetRepository
    private var bag = Set<AnyCancellable>()
    init(repo: PetRepository) {
        self.repo = repo
        repo.petsPublisher.receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.pets = $0; self?.applySort() }.store(in: &bag)
    }
    private func applySort() {
        switch sort {
        case .nickname: pets.sort { $0.nickname < $1.nickname }
        case .createdAt: pets.sort { $0.createdAt > $1.createdAt }
        }
    }
    @discardableResult func delete(_ pet: Pet) async -> Bool {
        guard deletingIDs.insert(pet.id).inserted else { return false }
        defer { deletingIDs.remove(pet.id) }
        do {
            let ids = try reminderIDs?(pet.id) ?? []
            try repo.delete(id: pet.id)
            await reminderCleanup?(ids)
            return true
        } catch { toast = "删除失败，请重试"; return false }
    }
}

@MainActor final class PetFormViewModel: ObservableObject {
    @Published var draft: Pet
    @Published private(set) var pickedAvatar: UIImage?   // 新选头像，保存时才落盘
    @Published private(set) var avatarRemoved = false    // 标记移除，保存时才清文件
    @Published private(set) var errors: [PetField: String] = [:]
    @Published private(set) var saveError: String?
    private let repo: PetRepository, isEditing: Bool
    private let originalAvatarFileName: String?
    private let saveAvatar: (UIImage) throws -> String
    init(repo: PetRepository, editing: Pet? = nil,
         saveAvatar: @escaping (UIImage) throws -> String = { try AvatarStore.save($0) }) {
        self.repo = repo; isEditing = editing != nil; draft = editing ?? Pet()
        originalAvatarFileName = editing?.avatarFileName
        self.saveAvatar = saveAvatar
    }
    func pickAvatar(_ image: UIImage) { pickedAvatar = image; avatarRemoved = false }
    func removeAvatar() { pickedAvatar = nil; avatarRemoved = true }
    @discardableResult func save() -> Bool {
        errors = PetValidator.errors(for: draft)          // 非空：View 高亮并阻止提交
        saveError = nil
        guard errors.isEmpty else { return false }
        var newFile: String?
        do {
            if let pickedAvatar {
                let name = try saveAvatar(pickedAvatar)
                newFile = name
                draft.avatarFileName = name
            } else if avatarRemoved {
                draft.avatarFileName = nil
            }
            isEditing ? try repo.update(draft) : try repo.create(draft)
        } catch {
            if let newFile { AvatarStore.delete(fileName: newFile) }   // 回滚，避免孤儿文件
            draft.avatarFileName = originalAvatarFileName
            saveError = "保存失败，请重试。原档案与头像已保留。"
            return false
        }
        // 写库成功后清理被替换/移除的旧头像文件
        if (newFile != nil || avatarRemoved), let old = originalAvatarFileName, old != newFile {
            AvatarStore.delete(fileName: old)
        }
        return true
    }
}
