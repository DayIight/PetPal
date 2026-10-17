# M1 多宠物档案管理

## 架构说明
M1 采用标准 MVVM：`PetListView / PetDetailView / PetFormView`（View）→
`PetListViewModel / PetFormViewModel`（@Published 状态 + 校验入口）→
`PetRepository` 协议 → `CoreDataPetRepository`（Core Data 本地实现）。
View 不直接持有 NSManagedObject，层间只传值类型 `Pet`，保证可测试性。
校验逻辑独立为纯函数 `PetValidator`，UI 仅消费 `[PetField: String]` 错误字典做高亮。
本模块使用本地持久化，不接触 CloudKit 或账号服务。
删除宠物为真实级联：`CoreDataPetRepository.delete` 同事务删除
该宠物的全部 `CDRecord` / `CDReminder` / `CDWeightSample` / `CDCareItem`，保存成功后清理头像、记录图片及医疗文件；
pending 通知撤销由 App 层经 `PetListViewModel.reminderCleanup` 钩子在删库成功后重排，删除失败时保留提醒。

## 数据模型（Core Data 实体 `CDPet`，输出形式：架构说明）

| 属性 | 类型 | 约束 |
|---|---|---|
| id | UUID | 主键 |
| species | String(enum) | 必填，猫/狗/其他，驱动品种预设与 M2 模板过滤 |
| nickname | String | 必填，1-20 字符（trim 后） |
| breed | String | 必填，`BreedCatalog` 按物种给预设列表（狗/猫各 Top10）+ 自定义输入 |
| birthday | Date | 必填，禁止晚于今天（Picker 层 + 校验双层拦截） |
| adoptionDate | Date? | 选填 |
| weightKg | Double | 0.1...100.0，步进 0.1，显示 1 位小数 |
| neuterStatus | String(enum) | 未绝育/已绝育/计划中 |
| chipNumber | String? | 选填，正则 `^\d{15}$` |
| allergens | [String] (Transformable) | 预设标签多选 + 自定义 |
| vetName / vetPhone | String? | 电话正则 `^\+?[\d\s-]{5,20}$` |
| avatarFileName | String? | 仅存文件名，原图压缩至最长边 ≤1080px 存 Documents |
| createdAt | Date | 排序依据 |

## 视图层级
```
PetListView（排序 segmented：添加时间/昵称）
 └─ NavigationLink → PetDetailView
      ├─ 头部头像可点击 → AvatarPickerView（拍照/相册/移除，即时保存）
      ├─ 编辑 → PetFormView（编辑/新建共用）
      └─ 删除 → confirmationDialog 二次确认
PetFormView
 ├─ AvatarPickerView（头像 → AvatarStore 压缩落盘，保存时生效）
 ├─ DatePicker(in: ...Date()) 生日/领养日
 ├─ 其他信息（选填）：芯片号/兽医/兽医电话，空串存 nil，格式由 PetValidator 保存时拦截
 └─ 错误高亮：errors[field] 非空时红框 + 文案，禁止提交
```

## 状态管理
- `PetListViewModel`：订阅 `repo.petsPublisher`，排序切换仅改本地数组顺序；
  删除失败置 `errorMessage` 触发 Toast。
- `PetFormViewModel`：持有 `draft: Pet`（值类型），`save()` 先跑 `PetValidator`，
  有错则回填 `errors` 字典并返回 false，View 据此高亮且不 dismiss。
- ViewModel 标注 `@MainActor`；档案和照护资料与记录、提醒共用 `CoreDataStack` 的 `viewContext`，写入完成后发布刷新通知。

## 照护资料持久化

当前模型为 Core Data V4，保留 V1–V3 模型用于迁移。新增 `CDCareItem` 将四类资料存为 Codable JSON；`CareItemStore` 按 `petID` 和 `category` 查询，校验 JSON 中的身份、档案归属及类别，避免跨宠物更新。

| 属性 | 类型 | 用途 |
|---|---|---|
| id | UUID | 照护项目身份，与 payload 的 id 一致 |
| petID | UUID | 已存在的宠物档案，与 payload 的 petID 一致 |
| category | String | `quickAction`、`medicalDocument`、`medicationCourse` 或 `careInstructions` |
| payload | String | 对应值类型编码的 JSON，医疗资料只存文件名及元数据 |
| createdAt | Date | 项目创建时间，更新时保留 |

`CareItemStore` 默认立即保存并发送 `.careItemsDidChange`。需要与提醒共同提交时使用 `commit: false`，由调用方统一保存或回滚；用药疗程与关联提醒采用同一事务。各类别的字段和数量限制由相应 Repository 校验。

医疗文件保存在 `AvatarStore.directory`，使用随机 UUID 文件名。删除宠物清理该宠物四类照护资料及医疗文件；单独删除已关联的健康记录，仅解除医疗资料的记录关联，保留资料及文件。模块入口和用法见 [日常记录](../M2_DailyRecords/README.md)、[用药疗程](../M4_Reminders/README.md) 及 [医疗资料与交接卡](../M5_Dashboard/README.md)。

## 完整备份与恢复

在「我的 → 数据备份」导出或恢复 `.petpalbackup` 文件，也可查看每周本机自动备份状态。当前导出格式为 v2，兼容恢复 v1 备份。v2 包含全部宠物的数据库、头像、记录图片、医疗文件，以及常用快捷、医疗资料元数据、用药疗程和照护说明。

`PortableBackup` 在独立快照中校验数据与媒体引用，`CareItemBackup` 校验四类 payload、关联宠物、健康记录及疗程提醒。恢复时先校验并准备新数据库与随机命名的媒体文件，再替换数据库；校验与准备期间可取消，提交失败会回滚。备份文件未加密，可能包含医疗资料与紧急联系信息，应导出到可信位置。本机自动备份保留最近两份，卸载 App 会清除本机数据和本机副本。

## 关键交互逻辑（输出形式：代码骨架，见 PetProfileSkeleton.swift）
1. 头像：`AvatarPickerView`（拍照 / `PhotosPicker` 相册 / 移除）→ `AvatarStore.save` 等比压缩至 ≤1080px、
   JPEG 0.8 → 存 Documents。表单内在 `save()` 时落盘并写库（失败回滚新文件，成功清理被替换的旧文件）；
   详情页点头像即时保存。
2. 提交：`save()` → `PetValidator.errors` → 空则 create/update，非空则逐字段红框高亮。
3. 删除：详情页 `confirmationDialog` → `repo.delete` → 预留 `onPetDeleted` 钩子（M4 联动清理提醒）。

关键 SwiftUI 片段（视图层约定，实现随可运行原型交付）：
```swift
DatePicker("生日", selection: $vm.draft.birthday, in: ...Date(), displayedComponents: .date)
TextField("昵称", text: $vm.draft.nickname)
    .overlay(RoundedRectangle(cornerRadius: 8)
        .stroke(vm.errors[.nickname] != nil ? Color.red : .clear))
    .accessibilityLabel("昵称").accessibilityHint("必填，一到二十个字符")
.confirmationDialog("确认删除该宠物档案？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
    Button("删除", role: .destructive) { vm.delete(pet) }   // 同时提示将清理关联提醒
    Button("取消", role: .cancel) {}
}
```

## 测试要点（输出形式：代码骨架，见 PetProfileTests.swift）
- `PetValidatorTests`：空昵称/超长、未来生日、越界体重、非法芯片号与电话 —— 逐项断言错误键。
- `CoreDataPetRepositoryTests`：in-memory store 验证 CRUD 与 publisher 推送。
- 覆盖率目标：本模块 Validator + Repository 行覆盖 ≥70%。
