import XCTest
import Combine
import CoreData
@testable import PetPal

// MARK: - 校验逻辑（目标：PetValidator 行覆盖 100%）
final class PetValidatorTests: XCTestCase {
    private func valid() -> Pet { Pet(nickname: "小白", breed: "柯基", birthday: Date(), weightKg: 8.5) }

    func test_emptyNickname_rejected() {
        var p = valid(); p.nickname = "   "
        XCTAssertNotNil(PetValidator.errors(for: p)[.nickname])
    }
    func test_nicknameOver20_rejected() {
        var p = valid(); p.nickname = String(repeating: "喵", count: 21)
        XCTAssertNotNil(PetValidator.errors(for: p)[.nickname])
    }
    func test_futureBirthday_rejected() {
        var p = valid(); p.birthday = Date().addingTimeInterval(86400)
        XCTAssertNotNil(PetValidator.errors(for: p)[.birthday])
    }
    func test_weightOutOfRange_rejected() {
        var p = valid(); p.weightKg = 100.1
        XCTAssertNotNil(PetValidator.errors(for: p)[.weight])
    }
    func test_chipMustBe15Digits() {
        var p = valid(); p.chipNumber = "12345"
        XCTAssertNotNil(PetValidator.errors(for: p)[.chip])
        p.chipNumber = "123456789012345"
        XCTAssertNil(PetValidator.errors(for: p)[.chip])
    }
    func test_validPet_passes() {
        XCTAssertTrue(PetValidator.errors(for: valid()).isEmpty)
    }
}

// MARK: - 物种与品种目录（H-01）
final class BreedCatalogTests: XCTestCase {
    func test_speciesDrivesBreedList() {
        XCTAssertTrue(BreedCatalog.breeds(for: .dog).contains("柯基"))
        XCTAssertTrue(BreedCatalog.breeds(for: .cat).contains("布偶"))
        XCTAssertTrue(BreedCatalog.breeds(for: .other).isEmpty)
    }
    func test_speciesRoundTripsThroughRepository() throws {
        let repo = CoreDataPetRepository(stack: CoreDataStack(inMemory: true))
        var latest: [Pet] = []
        var bag = Set<AnyCancellable>()
        repo.petsPublisher.sink { latest = $0 }.store(in: &bag)
        var p = Pet(nickname: "咪咪", breed: "布偶", birthday: Date(), weightKg: 4.2)
        p.species = .cat
        try repo.create(p)
        XCTAssertEqual(latest.first?.species, .cat)
        _ = bag
    }
}

// MARK: - H-02：删除宠物级联清理（记录/提醒/体重样本/关联文件）
final class PetCascadeDeleteTests: XCTestCase {
    func test_deletePet_cascadesRecordsRemindersWeightSamples() throws {
        let stack = CoreDataStack(inMemory: true)
        let petRepo = CoreDataPetRepository(stack: stack)
        let recordRepo = CoreDataRecordRepository(stack: stack)
        let reminderRepo = CoreDataReminderRepository(stack: stack)
        let weightRepo = CoreDataWeightRepository(stack: stack)

        let pet = Pet(nickname: "小白", breed: "柯基", birthday: Date(), weightKg: 8.5)
        try petRepo.create(pet)
        try recordRepo.create(PetPal.Record(petID: pet.id, kind: .feeding))
        try reminderRepo.save(Reminder(petID: pet.id, petName: "小白", type: .feeding, hour: 8, minute: 0))
        try weightRepo.add(WeightSample(petID: pet.id, kg: 8.5, date: Date()))

        try petRepo.delete(id: pet.id)

        // recordsPublisher 的 subject 只在自身增删时刷新；删除发生在 petRepo，
        // 需重新订阅（订阅即触发 reload）以读取库中真实状态
        var bag = Set<AnyCancellable>()
        var records: [PetPal.Record] = []
        recordRepo.recordsPublisher(petID: pet.id).sink { records = $0 }.store(in: &bag)
        XCTAssertTrue(records.isEmpty, "记录应随宠物删除")
        XCTAssertTrue(try reminderRepo.reminders(petID: pet.id).isEmpty, "提醒应随宠物删除")
        XCTAssertTrue(try weightRepo.samples(petID: pet.id).isEmpty, "体重样本应随宠物删除")
        _ = bag
    }

    @MainActor func test_viewModelDelete_invokesReminderCleanupAfterCommit() async throws {
        let stack = CoreDataStack(inMemory: true)
        let repo = CoreDataPetRepository(stack: stack)
        let vm = PetListViewModel(repo: repo)
        var cleanedIDs: [UUID] = []
        vm.reminderIDs = { [$0] }
        vm.reminderCleanup = { cleanedIDs.append(contentsOf: $0) }
        let pet = Pet(nickname: "豆豆", breed: "金毛", birthday: Date(), weightKg: 20)
        try repo.create(pet)
        await vm.delete(pet)
        XCTAssertEqual(cleanedIDs, [pet.id], "删除提交成功后应触发提醒清理钩子")
        XCTAssertEqual(vm.pets.count, 0)
    }
}

// MARK: - ViewModel 行为（排序、表单拦截）与头像存储
final class PetViewModelTests: XCTestCase {
    @MainActor func test_sortSwitchesBetweenNicknameAndCreatedAt() throws {
        let repo = CoreDataPetRepository(stack: CoreDataStack(inMemory: true))
        let older = Pet(nickname: "A狗", breed: "金毛", birthday: Date(), weightKg: 20,
                        createdAt: Date().addingTimeInterval(-3600))
        let newer = Pet(nickname: "B猫", breed: "柯基", birthday: Date(), weightKg: 8)
        try repo.create(older); try repo.create(newer)
        let vm = PetListViewModel(repo: repo)
        // publisher 经 receive(on: .main) 投递，需让主 runloop 跑一轮再断言
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(vm.pets.map(\.nickname), ["B猫", "A狗"])   // 默认添加时间倒序
        vm.sort = .nickname
        XCTAssertEqual(vm.pets.map(\.nickname), ["A狗", "B猫"])   // 昵称升序
    }

    @MainActor func test_formSave_invalidDraftBlocked_validDraftPersists() throws {
        let repo = CoreDataPetRepository(stack: CoreDataStack(inMemory: true))
        let vm = PetFormViewModel(repo: repo)
        XCTAssertFalse(vm.save())                       // 空昵称被拦截
        XCTAssertNotNil(vm.errors[.nickname])
        vm.draft.nickname = "小白"; vm.draft.breed = "柯基"
        XCTAssertTrue(vm.save())
        var latest: [Pet] = []
        var bag = Set<AnyCancellable>()
        repo.petsPublisher.sink { latest = $0 }.store(in: &bag)
        XCTAssertEqual(latest.count, 1)
        _ = bag
    }

    // 「其他信息」选填字段：合法值随保存入库，非法芯片号/电话被 PetValidator 拦截
    @MainActor func test_formSave_optionalInfo_persistsAndValidates() throws {
        let repo = CoreDataPetRepository(stack: CoreDataStack(inMemory: true))
        let vm = PetFormViewModel(repo: repo)
        vm.draft.nickname = "小白"; vm.draft.breed = "柯基"
        vm.draft.chipNumber = "12345"                   // 非15位：拦截
        XCTAssertFalse(vm.save())
        XCTAssertNotNil(vm.errors[.chip])
        vm.draft.chipNumber = "123456789012345"
        vm.draft.vetName = "王医生"; vm.draft.vetPhone = "138-0000-0000"
        XCTAssertTrue(vm.save())
        var latest: [Pet] = []
        var bag = Set<AnyCancellable>()
        repo.petsPublisher.sink { latest = $0 }.store(in: &bag)
        XCTAssertEqual(latest.first?.chipNumber, "123456789012345")
        XCTAssertEqual(latest.first?.vetName, "王医生")
        XCTAssertEqual(latest.first?.vetPhone, "138-0000-0000")
        _ = bag
    }
}

final class AvatarStoreTests: XCTestCase {
    static func makeImage(width: CGFloat = 600, height: CGFloat = 400) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { ctx in
            UIColor.orange.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }
    static func fileURL(_ name: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name)
    }

    func test_saveCompressesAndDeleteIsIdempotent() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 2000)).image { ctx in
            UIColor.orange.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 3000, height: 2000))
        }
        let name = try AvatarStore.save(image)
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let saved = UIImage(contentsOfFile: url.path)
        XCTAssertLessThanOrEqual(max(saved?.size.width ?? 0, saved?.size.height ?? 0), 1080)
        AvatarStore.delete(fileName: name)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        AvatarStore.delete(fileName: name)   // 幂等：重复删除不崩溃
        AvatarStore.delete(fileName: "")
    }
}

// MARK: - 表单头像（新建/编辑共用 PetFormViewModel：保存时落盘，替换/移除清理旧文件）
final class PetFormAvatarTests: XCTestCase {
    @MainActor private func makeVM(editing: Pet? = nil) throws -> PetFormViewModel {
        let repo = CoreDataPetRepository(stack: CoreDataStack(inMemory: true))
        if let editing { try repo.create(editing) }
        return PetFormViewModel(repo: repo, editing: editing)
    }
    @MainActor private func fillValid(_ vm: PetFormViewModel) {
        vm.draft.nickname = "小白"; vm.draft.breed = "柯基"
    }

    @MainActor func test_newPet_pickAvatar_savePersistsFile() throws {
        let vm = try makeVM(); fillValid(vm)
        vm.pickAvatar(AvatarStoreTests.makeImage())
        XCTAssertTrue(vm.save())
        let name = vm.draft.avatarFileName
        XCTAssertNotNil(name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: AvatarStoreTests.fileURL(name!).path))
        if let name { AvatarStore.delete(fileName: name) }   // 清理测试产物
    }

    @MainActor func test_edit_replaceAvatar_deletesOldFile() throws {
        let oldName = try AvatarStore.save(AvatarStoreTests.makeImage())
        var pet = Pet(nickname: "小白", breed: "柯基", birthday: Date(), weightKg: 8.5)
        pet.avatarFileName = oldName
        let vm = try makeVM(editing: pet)
        vm.pickAvatar(AvatarStoreTests.makeImage())
        XCTAssertTrue(vm.save())
        let newName = try XCTUnwrap(vm.draft.avatarFileName)
        XCTAssertNotEqual(newName, oldName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AvatarStoreTests.fileURL(oldName).path),
                       "被替换的旧头像文件应删除")
        XCTAssertTrue(FileManager.default.fileExists(atPath: AvatarStoreTests.fileURL(newName).path))
        AvatarStore.delete(fileName: newName)
    }

    @MainActor func test_edit_removeAvatar_clearsFieldAndDeletesFile() throws {
        let oldName = try AvatarStore.save(AvatarStoreTests.makeImage())
        var pet = Pet(nickname: "小白", breed: "柯基", birthday: Date(), weightKg: 8.5)
        pet.avatarFileName = oldName
        let vm = try makeVM(editing: pet)
        vm.removeAvatar()
        XCTAssertTrue(vm.save())
        XCTAssertNil(vm.draft.avatarFileName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AvatarStoreTests.fileURL(oldName).path))
    }

    @MainActor func test_invalidDraft_avatarFileNotWritten() throws {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let before = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let vm = try makeVM()   // 昵称为空，校验失败
        vm.pickAvatar(AvatarStoreTests.makeImage())
        XCTAssertFalse(vm.save())
        let after = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertEqual(Set(after), Set(before), "校验失败不得落盘头像文件")
    }
}

// MARK: - Core Data CRUD（in-memory store，不污染磁盘）
final class CoreDataPetRepositoryTests: XCTestCase {
    private var repo: CoreDataPetRepository!
    private var latest: [Pet] = []
    private var bag = Set<AnyCancellable>()
    override func setUp() {
        repo = CoreDataPetRepository(stack: CoreDataStack(inMemory: true))
        repo.petsPublisher.sink { [weak self] in self?.latest = $0 }.store(in: &bag)
    }

    func test_create_thenPublisherEmits() throws {
        try repo.create(Pet(nickname: "小白", breed: "柯基", birthday: Date(), weightKg: 8.5))
        XCTAssertEqual(latest.count, 1)
        XCTAssertEqual(latest.first?.nickname, "小白")
    }
    func test_update_thenDelete() throws {
        var p = Pet(nickname: "小白", breed: "柯基", birthday: Date(), weightKg: 8.5)
        try repo.create(p)
        p.weightKg = 9.0; try repo.update(p)
        XCTAssertEqual(latest.first?.weightKg, 9.0)
        try repo.delete(id: p.id)
        XCTAssertEqual(latest.count, 0)
    }
}

// MARK: - 跨实例一致性（RootTabView 的 petListVM 与 CurrentPetStore 各自实例化 repository）
final class PetRepositoryCrossInstanceTests: XCTestCase {
    private var bag = Set<AnyCancellable>()

    // 实例 A（CurrentPetStore）订阅，实例 B（建档表单）写库，A 应在广播后看到新宠物
    func test_createViaOtherInstance_emitsToSubscriber() throws {
        let stack = CoreDataStack(inMemory: true)
        let repoA = CoreDataPetRepository(stack: stack)
        let repoB = CoreDataPetRepository(stack: stack)
        var received: [[Pet]] = []
        repoA.petsPublisher.sink { received.append($0) }.store(in: &bag)
        try repoB.create(Pet(nickname: "小白", breed: "柯基", birthday: Date(), weightKg: 8.5))
        let drained = expectation(description: "main 队列投递完成")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertEqual(received.last?.count, 1)
        XCTAssertEqual(received.last?.first?.nickname, "小白")
    }
}

final class StorageFailureRegressionTests: XCTestCase {
    func test_avatarWriteFailure_throwsInsteadOfReturningMissingFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try AvatarStore.save(AvatarStoreTests.makeImage(), to: file))
        XCTAssertEqual(try Data(contentsOf: file), Data([1]))
    }

    @MainActor func test_failedAvatarWrite_preservesExistingProfileAndFile() throws {
        let stack = CoreDataStack(inMemory: true)
        let repo = CoreDataPetRepository(stack: stack)
        let oldName = try AvatarStore.save(AvatarStoreTests.makeImage())
        defer { AvatarStore.delete(fileName: oldName) }
        let pet = Pet(nickname: "小白", breed: "柯基", avatarFileName: oldName)
        try repo.create(pet)
        let vm = PetFormViewModel(repo: repo, editing: pet, saveAvatar: { _ in
            throw CocoaError(.fileWriteOutOfSpace)
        })
        vm.pickAvatar(AvatarStoreTests.makeImage())
        vm.draft.nickname = "新名字"
        XCTAssertFalse(vm.save())
        XCTAssertNotNil(vm.saveError)
        XCTAssertEqual(vm.draft.avatarFileName, oldName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: AvatarStoreTests.fileURL(oldName).path))
        XCTAssertEqual(try stack.container.viewContext.fetch(CDPet.fetchRequest()).first?.nickname, "小白")
    }

    @MainActor func test_failedDatabaseUpdate_rollsBackProfile_andRemovesOnlyNewAvatar() throws {
        var failWrites = false
        let stack = CoreDataStack(inMemory: true, saveContext: { context in
            if failWrites { throw CocoaError(.fileWriteOutOfSpace) }
            try context.save()
        })
        let repo = CoreDataPetRepository(stack: stack)
        let oldName = try AvatarStore.save(AvatarStoreTests.makeImage())
        defer { AvatarStore.delete(fileName: oldName) }
        let pet = Pet(nickname: "小白", breed: "柯基", avatarFileName: oldName)
        try repo.create(pet)
        var newName: String?
        let vm = PetFormViewModel(repo: repo, editing: pet, saveAvatar: { image in
            let name = try AvatarStore.save(image)
            newName = name
            return name
        })
        vm.draft.nickname = "不应落库"
        vm.pickAvatar(AvatarStoreTests.makeImage())
        failWrites = true
        XCTAssertFalse(vm.save())
        XCTAssertNotNil(vm.saveError)
        XCTAssertFalse(stack.container.viewContext.hasChanges)
        XCTAssertTrue(FileManager.default.fileExists(atPath: AvatarStoreTests.fileURL(oldName).path))
        let written = try XCTUnwrap(newName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AvatarStoreTests.fileURL(written).path))
        failWrites = false
        try CoreDataWeightRepository(stack: stack).add(WeightSample(petID: pet.id, kg: 5, date: Date()))
        let stored = try XCTUnwrap(stack.container.viewContext.fetch(CDPet.fetchRequest()).first)
        XCTAssertEqual(stored.nickname, "小白", "后续保存不能把之前失败的更新一并落库")
        XCTAssertEqual(stored.avatarFileName, oldName)
    }

    @MainActor func test_allRepositories_discardFailedInsertsBeforeAnotherWrite() throws {
        var failWrites = true
        let stack = CoreDataStack(inMemory: true, saveContext: { context in
            if failWrites { throw CocoaError(.fileWriteOutOfSpace) }
            try context.save()
        })
        let petID = UUID()
        XCTAssertThrowsError(try CoreDataPetRepository(stack: stack).create(Pet(nickname: "失败", breed: "柯基")))
        XCTAssertThrowsError(try CoreDataRecordRepository(stack: stack).create(PetPal.Record(petID: petID)))
        XCTAssertThrowsError(try CoreDataReminderRepository(stack: stack).save(
            Reminder(petID: petID, type: .feeding, hour: 8, minute: 0)))
        XCTAssertThrowsError(try CoreDataWeightRepository(stack: stack).add(
            WeightSample(petID: petID, kg: 5, date: Date())))
        XCTAssertThrowsError(try CoreDataCustomTemplateRepository(stack: stack).save(
            CustomTemplate(name: "失败模板", fields: [.init(title: "字段", type: .text)])))
        XCTAssertFalse(stack.container.viewContext.hasChanges)
        failWrites = false
        try CoreDataWeightRepository(stack: stack).add(WeightSample(petID: petID, kg: 6, date: Date()))
        let context = stack.container.viewContext
        XCTAssertTrue(try context.fetch(CDPet.fetchRequest()).isEmpty)
        XCTAssertTrue(try context.fetch(CDRecord.fetchRequest()).isEmpty)
        XCTAssertTrue(try context.fetch(CDReminder.fetchRequest()).isEmpty)
        XCTAssertTrue(try context.fetch(CDCustomTemplate.fetchRequest()).isEmpty)
        XCTAssertEqual(try context.fetch(CDWeightSample.fetchRequest()).map(\.kg), [6])
    }

    @MainActor func test_failedPetDeletion_preservesDataFilesAndNotificationCleanup() async throws {
        var failWrites = false
        let stack = CoreDataStack(inMemory: true, saveContext: { context in
            if failWrites { throw CocoaError(.fileWriteOutOfSpace) }
            try context.save()
        })
        let repo = CoreDataPetRepository(stack: stack)
        let reminderRepo = CoreDataReminderRepository(stack: stack)
        let oldName = try AvatarStore.save(AvatarStoreTests.makeImage())
        defer { AvatarStore.delete(fileName: oldName) }
        let pet = Pet(nickname: "小白", breed: "柯基", avatarFileName: oldName)
        try repo.create(pet)
        try CoreDataRecordRepository(stack: stack).create(PetPal.Record(petID: pet.id))
        try CoreDataWeightRepository(stack: stack).add(WeightSample(petID: pet.id, kg: 5, date: Date()))
        let reminder = Reminder(petID: pet.id, type: .feeding, hour: 8, minute: 0)
        try reminderRepo.save(reminder)
        let vm = PetListViewModel(repo: repo)
        vm.reminderIDs = { id in try reminderRepo.reminders(petID: id).map(\.id) }
        var cancelled: [UUID] = []
        vm.reminderCleanup = { cancelled.append(contentsOf: $0) }
        failWrites = true
        let deleted = await vm.delete(pet)
        XCTAssertFalse(deleted)
        XCTAssertNotNil(vm.toast)
        XCTAssertTrue(cancelled.isEmpty)
        let context = stack.container.viewContext
        XCTAssertEqual(try context.fetch(CDPet.fetchRequest()).count, 1)
        XCTAssertEqual(try context.fetch(CDRecord.fetchRequest()).count, 1)
        XCTAssertEqual(try context.fetch(CDWeightSample.fetchRequest()).count, 1)
        XCTAssertEqual(try reminderRepo.allReminders().map(\.id), [reminder.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: AvatarStoreTests.fileURL(oldName).path))
        XCTAssertFalse(context.hasChanges)
    }
}
