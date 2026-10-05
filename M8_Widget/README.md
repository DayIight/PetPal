# M8 Widget 小组件（L-01）

范围（2026-09-26 动工）：WidgetKit「今日提醒 + 宠物头像」小组件，
systemSmall / systemMedium 两种尺寸，点击深链到对应宠物页。
诊断报告 L-01 的其余平台特性（App Intents / CoreSpotlight / Handoff）仍延后。

## 架构说明（输出形式：架构说明）

快照方案，不迁移 Core Data：

```
PetPal App ──写──> App Group 共享容器（group.com.petpal.prototype）
                     ├─ widget-snapshot.json   宠物列表 + 当前宠物 + 完整提醒重复规则
                     └─ avatars/               当前宠物头像副本（widget 无法读 App 私有目录）
PetPalWidget Extension ──读──> 快照 → TimelineProvider → SwiftUI 视图
widget 点击 ──> petpal://pet/<uuid> ──> DeepLinkRouter（复用 H-06 通路）
```

- `WidgetSnapshot.swift`（App 与 Widget 共享编译，不 import WidgetKit/SwiftUI）：
  快照模型 + `WidgetSnapshotStore`（共享容器读写、头像复制；共享权限不足时明确返回不可用）
  + `WidgetSnapshotQueries`（当前宠物/今日未过提醒，纯函数）。
- `WidgetSnapshotSyncer.swift`（仅 App target）：组装并写快照，触发点三处——
  ①宠物列表/当前宠物变更（订阅 `CurrentPetStore`）②提醒增删/重排（`ReminderService.onDidChange`）
  ③回前台（`RootTabView` 监听 scenePhase）。写完 `WidgetCenter.reloadAllTimelines()`。
- 快照语义：`reminders` 保留全部重复规则，widget 按查询日期计算当天提醒，
  跨日不依赖 App 再次打开。旧版缺少 `repeatRule` 的快照仅在生成当天有效。
- Widget 侧（`PetPalWidget/PetPalWidget.swift`）：预生成未来 7 天各提醒到点和午夜的条目，
  使过点提醒从列表消失，并在跨日后显示新的提醒；窗口末尾再请求下一轮时间线。
  快照缺失时 30 分钟后重试，未建档时渲染引导态；iOS 17+ 使用 widget 容器背景。
  条目实际展示及刷新时机由 WidgetKit 调度。
- 快照读取或写入失败时记录日志并保留上一次成功快照，不用空提醒覆盖有效数据。
- 共享容器不可用时不回退到 App 私有 Documents。读取失败显示「打开 PetPal 同步宠物数据」，
  只有成功读取的快照确实没有宠物时才显示建档引导；两种状态都可以点开 App。

## 数据契约（widget-snapshot.json）

| 字段 | 类型 | 说明 |
|---|---|---|
| generatedAt | Date | 快照生成时间 |
| currentPetID | UUID? | 当前选中宠物；nil 时取 pets 第一只 |
| pets[] | PetEntry | id / nickname / species(rawValue) / avatarFileName? |
| reminders[] | ReminderEntry | id / petID / petName / type(rawValue) / hour / minute / repeatRule?；完整重复规则 |

## 深链契约

- small 整卡 `.widgetURL`，medium 每行 `Link`：`petpal://pet/<uuid>`
- App 侧 `DeepLinkRouter.handle(url:)` 解析后 `openPet(id:)`，落点为「我的」tab 的宠物详情页。

## 测试要点（见 WidgetSnapshotTests.swift）

- 快照 write/read round-trip；缺文件读返回 nil；头像复制进 avatars/ 子目录。
- `remainingReminders` 过滤（已过时间/其他宠物排除）与排序；空快照不崩。
- 提醒到点和跨日的时间线条目、月/年规则跨日计算、旧版 JSON 兼容及过期处理。
- 完整规则写入快照；读取失败保留旧文件，不发出刷新请求。
- `fires(rule:on:)`：daily/weekly/monthly/yearly 当天匹配边界（固定时区日历）。
- `ReminderService` 的 save/removeAll/rescheduleAll 均触发 `onDidChange`（权限被拒也触发）。
- `DeepLinkRouter.handle(url:)`：合法 petpal://pet/<uuid> 入栈；异构 scheme/host/非法 uuid 忽略。
- 应用安装包的 URL scheme 注册、主图标名称和 Assets.car 资源存在。
- 已运行测试 App 的真实 App Group 容器可读写，防止无签名构建的纯逻辑测试出现假通过。
- 共享容器缺失时不写入私有 Documents，也不发出刷新请求。

## 独立验收清单（M8）

- [ ] 真机/模拟器添加小组件，显示当前宠物头像与今日下一条提醒（small/medium 各一）
- [ ] 新增/删除提醒、切换当前宠物后，widget 在刷新后内容随之更新
- [ ] 点击 widget 唤起 App 并落在对应宠物详情页（杀进程态同样验证）
- [ ] 未建档时 widget 显示引导态而非空白
- [x] 快照读写/过滤/排序/触发钩子/深链解析单测通过
- 模拟器：使用 `./scripts/build-ios.sh` 构建；保留 Xcode 签名流程和 entitlements 打包，
  `project.yml` 对模拟器设置 ad-hoc 签名 `-`，无需开发者证书。不要传 `CODE_SIGNING_ALLOWED=NO`，
  该选项会跳过共享权限打包，导致 App 和 Widget 无法访问同一容器。
- 真机：App 与 Widget 需要同一有效签名 Team，并在开发者账号与配置描述文件中启用
  `group.com.petpal.prototype`；`DEVELOPMENT_TEAM` 当前为空，需按实际账号配置。
- 埋点（widget 添加率/唤起率）依赖分析 SDK，并入 L-02 商业化决策时一并评估，本轮不接。
