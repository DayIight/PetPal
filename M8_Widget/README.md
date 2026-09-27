# M8 Widget 小组件（L-01）

范围（2026-09-26 动工）：WidgetKit「今日提醒 + 宠物头像」小组件，
systemSmall / systemMedium 两种尺寸，点击深链到对应宠物页。
诊断报告 L-01 的其余平台特性（App Intents / CoreSpotlight / Handoff）仍延后。

## 架构说明（输出形式：架构说明）

快照方案，不迁移 Core Data：

```
PetPal App ──写──> App Group 共享容器（group.com.petpal.prototype）
                     ├─ widget-snapshot.json   宠物列表 + 当前宠物 + 当天会触发的提醒
                     └─ avatars/               当前宠物头像副本（widget 无法读 App 私有目录）
PetPalWidget Extension ──读──> 快照 → TimelineProvider → SwiftUI 视图
widget 点击 ──> petpal://pet/<uuid> ──> DeepLinkRouter（复用 H-06 通路）
```

- `WidgetSnapshot.swift`（App 与 Widget 共享编译，不 import WidgetKit/SwiftUI）：
  快照模型 + `WidgetSnapshotStore`（共享容器读写、头像复制、App Group 不可用时回退 Documents）
  + `WidgetSnapshotQueries`（当前宠物/今日未过提醒，纯函数）。
- `WidgetSnapshotSyncer.swift`（仅 App target）：组装并写快照，触发点三处——
  ①宠物列表/当前宠物变更（订阅 `CurrentPetStore`）②提醒增删/重排（`ReminderService.onDidChange`）
  ③回前台（`RootTabView` 监听 scenePhase）。写完 `WidgetCenter.reloadAllTimelines()`。
- 快照语义：`reminders` 只含「当天会触发」的提醒（Syncer 按 RepeatRule 与当天日历过滤，
  `WidgetSnapshotSyncer.fires(rule:on:)`），widget 侧无需理解重复规则，只按当前时刻过滤未过项。
- Widget 侧（`PetPalWidget/PetPalWidget.swift`）：TimelineProvider 读快照生成单条目，
  时间线策略 `.after(次日 0 点)` 日更；快照缺失/无宠物时渲染引导态，不崩。

## 数据契约（widget-snapshot.json）

| 字段 | 类型 | 说明 |
|---|---|---|
| generatedAt | Date | 快照生成时间 |
| currentPetID | UUID? | 当前选中宠物；nil 时取 pets 第一只 |
| pets[] | PetEntry | id / nickname / species(rawValue) / avatarFileName? |
| reminders[] | ReminderEntry | id / petID / petName / type(rawValue) / hour / minute；仅当天会触发项 |

## 深链契约

- small 整卡 `.widgetURL`，medium 每行 `Link`：`petpal://pet/<uuid>`
- App 侧 `DeepLinkRouter.handle(url:)` 解析后 `openPet(id:)`，落点为「我的」tab 的宠物详情页。

## 测试要点（见 WidgetSnapshotTests.swift）

- 快照 write/read round-trip；缺文件读返回 nil；头像复制进 avatars/ 子目录。
- `remainingReminders` 过滤（已过时间/其他宠物排除）与排序；空快照不崩。
- `fires(rule:on:)`：daily/weekly/monthly/yearly 当天匹配边界（固定时区日历）。
- `ReminderService` 的 save/removeAll/rescheduleAll 均触发 `onDidChange`（权限被拒也触发）。
- `DeepLinkRouter.handle(url:)`：合法 petpal://pet/<uuid> 入栈；异构 scheme/host/非法 uuid 忽略。

## 独立验收清单（M8）

- [ ] 真机/模拟器添加小组件，显示当前宠物头像与今日下一条提醒（small/medium 各一）
- [ ] 新增/删除提醒、切换当前宠物后，widget 在刷新后内容随之更新
- [ ] 点击 widget 唤起 App 并落在对应宠物详情页（杀进程态同样验证）
- [ ] 未建档时 widget 显示引导态而非空白
- [x] 快照读写/过滤/排序/触发钩子/深链解析单测通过
- 真机注意：App Group 需有效签名 Team（DEVELOPMENT_TEAM 当前为空）；
  模拟器无签名构建下共享容器可能不可用，此时快照落 Documents、widget 走引导态，属预期降级。
- 埋点（widget 添加率/唤起率）依赖分析 SDK，并入 L-02 商业化决策时一并评估，本轮不接。
