# M1 多宠物档案管理

## 架构说明（本轮输出形式：架构说明）
M1 采用标准 MVVM：`PetListView / PetDetailView / PetFormView`（View）→
`PetListViewModel / PetFormViewModel`（@Published 状态 + 校验入口）→
`PetRepository` 协议 → `CoreDataPetRepository`（Core Data 本地实现，唯一持久化边界）。
View 不直接持有 NSManagedObject，层间只传值类型 `Pet`，保证可测试性。
校验逻辑独立为纯函数 `PetValidator`，UI 仅消费 `[PetField: String]` 错误字典做高亮。
边界声明：本模块不接触 CloudKit 与任何网络；后续云同步仅通过替换 Repository 实现
（`CloudKitPetRepository`，私有库 + 加密字段）接入，协议与 ViewModel 不变。
删除宠物为真实级联（2026-09-20 整改，H-02）：`CoreDataPetRepository.delete` 同事务删除
该宠物的全部 CDRecord/CDReminder/CDWeightSample 并清理头像与记录图片文件；
pending 通知撤销由 App 层经 `PetListViewModel.reminderCleanup` 钩子在删库前完成。

## 数据模型（Core Data 实体 `CDPet`，输出形式：架构说明）

| 属性 | 类型 | 约束 |
|---|---|---|
| id | UUID | 主键 |
| species | String(enum) | 必填（2026-09-20 整改新增），猫/狗/其他，驱动品种预设与 M2 模板过滤 |
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

## 视图层级（输出形式：架构说明）
```
PetListView（排序 segmented：添加时间/昵称）
 └─ NavigationLink → PetDetailView
      ├─ 编辑 → PetFormView（编辑/新建共用）
      └─ 删除 → confirmationDialog 二次确认
PetFormView
 ├─ PhotosPicker / 相机（头像 → AvatarStore 压缩落盘）
 ├─ DatePicker(in: ...Date()) 生日/领养日
 └─ 错误高亮：errors[field] 非空时红框 + 文案，禁止提交
```

## 状态管理（输出形式：架构说明）
- `PetListViewModel`：订阅 `repo.petsPublisher`，排序切换仅改本地数组顺序；
  删除失败置 `errorMessage` 触发 Toast。
- `PetFormViewModel`：持有 `draft: Pet`（值类型），`save()` 先跑 `PetValidator`，
  有错则回填 `errors` 字典并返回 false，View 据此高亮且不 dismiss。
- 所有 ViewModel 标注 `@MainActor`，Repository 在后台 context 写、主线程发发布。

## 关键交互逻辑（输出形式：代码骨架，见 PetProfileSkeleton.swift）
1. 头像：`PhotosPicker` 取图 → `AvatarStore.save` 等比压缩至 ≤1080px、JPEG 0.8 → 存 Documents。
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

## 独立验收清单（M1）
- [ ] 昵称/品种/生日/体重为空或非法时无法保存，对应字段红框 + 错误文案
- [ ] 物种必选（猫/狗/其他），切换物种后品种预设列表随之变化，仍支持自定义输入
- [ ] 生日/领养日期选择器无法选中未来日期
- [ ] 芯片号非 15 位数字、兽医电话格式错误均被拦截
- [ ] 过敏源支持预设标签多选与自定义输入
- [ ] 列表支持按昵称/添加时间排序，切换即时生效
- [ ] 删除档案弹出二次确认；确认后该宠物的记录、提醒（含 pending 通知）、体重样本、头像与附件文件一并清除
- [ ] 相册选择头像后存储图最长边 ≤1080px
- [ ] 深色模式下无硬编码颜色；所有文本支持 Dynamic Type 不截断
- [ ] 单元测试通过且 Validator/Repository 覆盖率 ≥70%（含级联删除用例）
