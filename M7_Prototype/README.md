# M7 可运行原型（MVP 核心路径闭环）

范围：建档案 → 记一条喂食 → 设一个每日提醒。仅 View 层与接线，
模型/仓储/Service 复用 M1/M2/M4 骨架，零重复实现。

## Xcode 组装步骤（输出形式：架构说明）
1. 新建 App 工程：SwiftUI 生命周期、最低部署 iOS 16.0、Swift 5.9。
2. 新建 `PetPal.xcdatamodeld`，按下表建 4 个实体，Codegen 选 **Class Definition**：
   - `CDPet`：id UUID, nickname/breed/neuterStatus/chipNumber/vetName/vetPhone/avatarFileName String?,
     birthday/adoptionDate/createdAt Date?, weightKg Double, allergens Transformable
   - `CDRecord`：id/petID UUID?, kind/note/mood String?, answers/photoFileNames Transformable?, createdAt Date?
   - `CDReminder`：id/petID UUID?, type/repeatRule String?, hour/minute Integer 16
   - `CDWeightSample`：id/petID UUID?, kg Double, date Date?
3. 将 M1-M6 各 `*Skeleton.swift` 与本目录 `PrototypeApp.swift` 加入 App target；
   各 `*Tests.swift` 加入 Unit Test target；`PrototypeUITests.swift` 加入 UI Test target。
4. 本地通知无需额外 entitlement；首次保存提醒时系统弹权限框。
5. 入口为 `PetPalPrototypeApp`（`@main`）。M3 信息流需 Kingfisher 时再加 SPM 依赖，原型路径不涉及。

## 页面流转（输出形式：架构说明）
```
空态「创建第一个宠物档案」→ PetFormView(sheet)
  → 首页（多宠物切换 Menu + 当前宠物 + 两个入口 + 删除入口）
      ├─ 记一条喂食 → FeedingFormView(sheet，喂食模板字段)
      ├─ 设每日提醒 → ReminderFormView(sheet)
      │     ├─ 权限被拒 → 提醒仍落库 + Alert「去设置/稍后」（M-03）
      │     └─ 已授权 → ReminderService.save → 每日触发
      └─ 删除宠物 → confirmationDialog（告知连带范围）→ 级联清理（H-02）
通知点击 → AppDelegate(UN delegate) → DeepLinkRouter → NavigationPath → PetDetailView（H-06）
存储加载失败 → 全屏错误态视图（H-03，iOS 16 等效 ContentUnavailableView）
```

## 关键交互逻辑（输出形式：可运行原型，见 PrototypeApp.swift）
- 表单错误时 sheet 不关闭并红字列出原因（Validator 驱动，UI 测试据此断言）。
- 提醒保存前先 `requestPermission`，denied 走系统设置引导，granted 才调度。
- 全部可交互控件带 `accessibilityIdentifier`，供 UI 自动化定位。

## 测试策略汇总
- 单元测试：M1-M5 各模块 Validator/纯函数/Repository（in-memory），目标覆盖率 ≥70%。
  2026-09-20 整改新增：物种/品种目录、级联删除、提醒落库解耦、时区重排、数字校验、记录 update。
- UI 自动化三关键路径：发布记录 ✅（本目录）、设置提醒 ✅（本目录）、
  导出 PDF ⏳（随 M5 增强交付，脚本预留 `test_exportPDF` 占位）。
- 最近一次全量测试（2026-09-20）：单元 + UI 全部通过，结果留存 `build/TestResults.xcresult`。

## 独立验收清单（原型闭环）
- [ ] 昵称为空时点保存：sheet 不关、红字提示「昵称需为1-20个字符」
- [ ] 建档成功回首页，显示「当前宠物：小白」
- [ ] 喂食必填（食物/克数/时段）缺失时无法保存
- [ ] 完整喂食记录保存成功（错误列表为空、sheet 关闭）
- [ ] 首次保存提醒弹系统权限框；授权后提醒按每日重复触发
- [ ] 拒绝权限时出现「通知权限未开启」Alert 且「去设置」可跳系统设置
- [ ] 通知正文为「该给【小白】喂食了」，点击可唤起 App
- [ ] 两条 UI 测试脚本在模拟器通过
