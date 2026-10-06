# M8 Widget 小组件（L-01）

范围：WidgetKit「今日提醒 + 宠物头像」小组件，支持 systemSmall / systemMedium。
每只宠物对应一页；iOS 17 及以上点击左右箭头循环翻页，显示“当前页 / 宠物总数”，
点击提醒或卡片内容通过深链打开该页宠物的「记录」页，自动选中对应宠物。
iOS 16 保持展示 App 当前宠物，不显示翻页按钮。
CoreSpotlight / Handoff 仍延后。

## 翻页规则

- 默认展示 App 当前宠物，此后记住小组件上次查看的宠物，不改变 App 内的当前选择。
- 顺序与快照中的宠物列表一致，前后循环；只有一只宠物时不显示翻页按钮，无宠物时显示建档引导。
- 小、中尺寸及同类型多个小组件共用页面选择；系统在交互完成后刷新，其他实例在刷新时采用相同选择。
- 按宠物 ID 持久化，而非页码。列表重排保留同一只宠物；所选宠物被删除后回退到有效的 App 当前宠物或第一只。
- 按钮携带目标宠物 ID 和方向，避免旧时间线或重复执行导致多翻一页；两只宠物时左右交互仍有不同身份，目标已删除时忽略该操作。
- 翻页只更新 widget-selected-pet.json，不修改快照、提醒配置、数据库或 App 当前宠物。

## 架构说明（输出形式：架构说明）

快照方案，不迁移 Core Data：

```
PetPal App ──写──> App Group 共享容器（group.com.petpal.prototype）
                     ├─ widget-snapshot.json   宠物列表 + 当前宠物 + 完整提醒规则
                     ├─ widget-selected-pet.json  小组件页面宠物 ID
                     └─ avatars/               所有宠物头像副本（widget 无法读 App 私有目录）
PetPalWidget Extension ──读──> 快照 + 页面选择 → TimelineProvider → SwiftUI 视图
左右箭头 ──> SelectWidgetPetIntent ──> 原子保存目标 ID ──> 刷新时间线
提醒/卡片点击 ──> petpal://records/<uuid> ──> DeepLinkRouter ──> 选中该宠物 + 记录 tab
```

- `WidgetSnapshot.swift`（App 与 Widget 共享编译，不 import WidgetKit/SwiftUI）：
  快照模型 + `WidgetSnapshotStore`（共享容器读写、头像复制、App Group 不可用时回退 Documents）
  + `WidgetSnapshotQueries`（指定宠物的今日未过提醒与时间线边界，纯函数）。
- `WidgetPetPaging.swift`（App 与 Widget 共享）：页面解析、相邻宠物 ID、独立页面存储。
- `SelectWidgetPetIntent.swift`（App 与 Widget 共享，iOS 17 起）：执行翻页，不打开 App；
  intent 完成后由系统刷新小组件，不同时发出额外的时间线重排请求。
- `WidgetSnapshotSyncer.swift`（仅 App target）：组装并写快照，触发点三处——
  ①宠物列表/当前宠物变更（订阅 `CurrentPetStore`）②提醒增删/重排（`ReminderService.onDidChange`）
  ③回前台（`RootTabView` 监听 scenePhase）。写完 `WidgetCenter.reloadAllTimelines()`。
- 快照语义：`reminders` 保留完整 RepeatRule、提前量及启用状态，Widget 按页面宠物与当地日历
  重算今日提醒，跨日无需依赖 App 再次打开。旧版无规则快照过了生成当天即失效。
- Widget 侧（`PetPalWidget/PetPalWidget.swift`）：生成包含今日、后续午夜及页面宠物提醒边界的时间线，
  在提醒触发后移除已过项；快照缺失/无宠物时渲染引导态。
- iOS 17 起采用 containerBackground，内容自行留出内边距；翻页按钮有 44 × 44 点命中区域和 VoiceOver 名称。
- 每页使用宠物 ID 作为视图身份，关闭整页切换的隐式动画，刷新过程中标记内容失效，减少显示和按钮目标不同步。

## 数据契约（widget-snapshot.json）

| 字段 | 类型 | 说明 |
|---|---|---|
| generatedAt | Date | 快照生成时间 |
| currentPetID | UUID? | App 当前宠物；小组件尚无有效页面选择时采用，nil 时取 pets 第一只 |
| pets[] | PetEntry | id / nickname / species(rawValue) / avatarFileName? |
| reminders[] | ReminderEntry | id / petID / petName / type / hour / minute / repeatRule? / advance? / isEnabled? |

widget-selected-pet.json 单独编码 UUID，缺失或损坏时采用默认页面，不影响快照读取。

## 深链契约

- 当前页整卡 `.widgetURL`，medium 提醒行同时使用 `Link`：`petpal://records/<uuid>`。
- 翻页按钮执行 App Intent，不触发深链；无提醒时也可点击卡片进入该宠物记录页。
- App 侧解析 `records` 路由，冷启动等待宠物加载后选中目标，切换到「记录」tab，并回到记录首页，便于点击「+」创建记录。
- 目标档案已删除时显示说明，避免把记录入口落到另一只宠物。旧 `petpal://pet/<uuid>` 档案路由继续可用。

## 测试要点（见 WidgetSnapshotTests.swift）

- 快照 write/read round-trip；缺文件读返回 nil；头像复制进 avatars/ 子目录。
- `remainingReminders` 过滤（已过时间/其他宠物排除）与排序；空快照不崩。
- 翻页覆盖：全部宠物双向循环、选择持久化、重排/删除回退、单宠/空态、旧目标忽略、写入失败保留快照。
- 指定宠物的提醒与时间线边界相互隔离，不随 App 当前宠物混入另一页。
- `fires(rule:on:)`：daily/weekly/monthly/yearly 当天匹配边界（固定时区日历）。
- `ReminderService` 的 save/removeAll/rescheduleAll 均触发 `onDidChange`（权限被拒也触发）。
- `DeepLinkRouter.handle(url:)`：合法 petpal://pet/<uuid> 入栈；异构 scheme/host/非法 uuid 忽略。
- `petpal://records/<uuid>` 保存目标并清空旧档案导航；连续不同宠物请求、非法路径和异构 URL 不误路由。

## 独立验收清单（M8）

- [x] 本地签名 iPhone 模拟器添加 small/medium，显示页面宠物及今日下一条提醒；正式签名真机待验收
- [ ] 新增/删除提醒、切换当前宠物后，widget 在刷新后内容随之更新
- [x] 本地签名 iPhone 模拟器：small 冷启动点击提醒进入对应宠物记录页；medium 在 App 已选另一只宠物时正确切换并进入记录页
- [x] iOS 27 模拟器 small/medium 双向循环翻页，姓名/提醒/页码/深链与页面宠物一致；iOS 17 及正式签名真机待验收
- [ ] App 回前台与当前宠物切换不会覆盖小组件已保存的页面；删除所选宠物后安全回退
- [ ] 未建档时 widget 显示引导态而非空白
- [x] 快照读写/过滤/排序/触发钩子/深链解析单测通过
- 真机注意：App Group 需有效签名 Team（DEVELOPMENT_TEAM 当前为空）；
  模拟器无签名构建下共享容器可能不可用，此时快照落 Documents、widget 走引导态，属预期降级。
- 埋点（widget 添加率/唤起率）依赖分析 SDK，并入 L-02 商业化决策时一并评估，本轮不接。

## 本轮验证（2026-10-06）

- 最终 167 项单元测试通过（含 9 项新增翻页测试、2 项记录页路由测试）；Release 无签名设备构建通过。
- 本地签名 iPhone 18 Pro / iOS 27.0：App Group 共享成功；两只宠物双向循环翻页复测通过，small/medium 均显示对应内容；小组件页面选择独立于 App 当前宠物。
- 初次交互复查发现 small 上一页按钮后显示偶尔滞后。最终加入方向参数以区分两只宠物时目标相同的按钮、使用页面视图身份、关闭整页隐式动画并采用系统交互刷新；连续上一页/下一页及循环边界复测通过。
- small 提醒点击冷启动 App 后显示「记录」与「当前宠物：小白」。在 App 改选「盖」后，小组件仍保留「小白」；medium 提醒点击再次进入「小白」记录页，验证目标宠物不会跟随 App 原先选择。
- 最终日志：build/WidgetPagingValidation/unit-tests-final.log、release-final.log、simulator-build.log；构建目录由 Git 忽略。
- 正式签名真机 App Group、iOS 16 展示兼容与 iOS 17 原始运行时交互仍待验收；模拟器验证不代表上架验收完成。
