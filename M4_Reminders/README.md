# M4 智能提醒系统

范围：通知权限请求与拒绝引导、五类提醒（喂食/疫苗/驱虫/体检/服药）、
每日/每周多选/每月/每年重复、提前量（5m/15m/30m/1h/1d/3d）、
通知正文含宠物昵称、点击通知跳转、删除宠物联动清理。表单已接入全部规则与提前量。记录页的提醒入口提供列表、新建、编辑、暂停/恢复和确认删除。

2026-10-05 P1 修复：保存错误会留在表单中供修改或重试；保存期间防重复提交。
启动、回前台及变更时区时重新读取系统通知权限并补排，设置中开启通知后无需重建配置。
查询/撤销/新增通知串行执行，失败时尝试恢复此前的通知；已保存的配置仍保留。

2026-10-06 P2 管理流程：编辑沿用原提醒 ID，替换同前缀通知而不新增配置。暂停状态持久化，撤销该条提醒的主通知与提前通知；前台补排过滤已暂停项，小组件快照也不包含它们。恢复时重新检查权限并按当前配置调度。单条删除先提交数据库，再撤销通知；数据库失败保留配置和原通知。列表仅展示当前宠物的提醒，权限不足提供设置入口。

## 架构说明（本轮输出形式：架构说明）
三层拆分：`ReminderService`（编排层，协调权限/存储/调度）→
`ReminderRepository`（Core Data 存提醒配置，本地库）+
`NotificationScheduling`（UNUserNotificationCenter 协议化包装，测试用 Mock 替换）。
规则即数据：共享文件 `PetPal/Models/ReminderSchedule.swift` 中的 `RepeatRule` 为 Codable 枚举，JSON 存库；
`ReminderTriggerBuilder` 纯函数把规则映射为 `UNCalendarNotificationTrigger` 数组
（每周多选拆为多个 trigger）。无效星期和不存在的年重复日期在保存前拒绝。
通知正文由 `ReminderContentBuilder` 纯函数生成，强制包含【宠物昵称】；
userInfo 携带 petID/reminderID，App 层 `UNUserNotificationCenterDelegate` 据此路由到对应页面。
联动：M1 删除宠物先收集通知 id，数据库级联删除提交成功后，
经 `PetListViewModel.reminderCleanup` 调用 `ReminderService.cancel(reminderIDs:)` 撤销通知。
删除失败保留档案、文件和通知。独立 `removeAll(petID:)` 也先提交删除，再撤销通知。
时区/日历变更：已落地（2026-09-20 整改，M-06）——监听 `NSSystemTimeZoneDidChange` 后
`rescheduleAll()` 按库中配置全量重排；提醒落库时同时存 `petName`，重排无需回查 M1。
提醒配置与送达解耦（M-03）：合法配置的 `save` 先落库，权限不足仅跳过调度。

月/年提前提醒根据每次实际发生日期生成一次性通知，预排未来 12 次；
例如每月 1 日提前 1 天，分别落在 1 月 31 日、2 月 28/29 日、3 月 31 日。
启动、回前台或变更时区时补齐窗口；长期不打开 App 时，窗口用完后提前通知会停止，
主提醒仍使用系统重复通知。31 日跳过短月，2 月 29 日跳过平年；提前 1/3 天按日历日移动。
调度检查总计 64 个 pending 请求的预算，超限时保留配置并提示减少提醒后重试。

## 数据模型（Core Data 实体 `CDReminder`，输出形式：架构说明）

| 属性 | 类型 | 说明 |
|---|---|---|
| id | UUID | 同时作为通知 identifier 前缀（多 trigger 时 `#序号` 后缀） |
| petID | UUID | 必填，绑定具体宠物 |
| petName | String | 随提醒落库（整改新增），时区重排时重建通知正文无需回查 M1 |
| type | String | ReminderType 五类之一 |
| hour / minute | Int16 | 具体提醒时间 |
| repeatRule | String | RepeatRule 的 JSON 编码 |
| advance | String | AdvanceOption 的原始值 |
| isEnabled | Bool | 默认 true；暂停状态持久化，旧库迁移后默认启用 |

## 权限与跳转流程（输出形式：架构说明）
1. 保存时先校验规则，再调用 `requestPermission()`；仅未决定授权时请求系统权限。
2. denied：配置落库后弹 Alert「通知权限未开启」→ `UIApplication.openSettingsURLString` 跳系统设置。
3. 点击通知：delegate 读 userInfo → DeepLink 路由至对应宠物档案页/记录页。

## 关键交互逻辑（输出形式：代码骨架，见 ReminderSkeleton.swift）
- 保存提醒 = 校验配置 → 读取权限 → 存库 → 等待撤销同 id 旧调度 → 重建 trigger 组。
- 数据库失败回滚未提交变更；调度失败不关闭表单，重试沿用原 id，避免重复配置。
- 撤销一律按 id 前缀匹配，兼容每周多选产生的多 trigger。

## 测试要点（输出形式：代码骨架，见 ReminderTests.swift）
- 正文必含【昵称】与动作词；每日 trigger repeats=true 且时分正确；每周多选产出 N 个 trigger。
- 权限被拒时 Service 不调度且状态为 denied；保存后 Mock 收到请求；removeAll 撤销+清库。
- 设置中重新授权、冷启动补排、延迟撤销与并发重排、调度失败恢复、容量不足、数据库回滚。
- 编辑不重复、暂停/恢复、暂停后补排、单条删除隔离、保存/删除失败保留原通知、小组件过滤暂停项。
- 月长、跨年、闰年、已过提前时间及夏令时日历日移动；空星期表单错误保留的 UI 回归。

## 独立验收清单（M4 MVP）
- [ ] 首次使用弹出系统权限请求；被拒后出现引导 Alert 并可跳转系统设置
- [ ] 五类提醒均可创建，通知正文格式为「该给【昵称】XX了」
- [ ] 每日重复到点触发（真机/模拟器验证）
- [ ] 点击通知跳转到对应宠物详情页（已接线：AppDelegate → DeepLinkRouter → NavigationPath）
- [ ] 删除宠物后其全部提醒被撤销且不再触发（级联链路已实测）
- [ ] 权限被拒时提醒仍落库，界面给出开启引导，不再静默丢失
- [x] 时区变更后按库中配置全量重排（`rescheduleAll` 单测覆盖；真机改时区走查待定）
- [x] Scheduler/Builder/Service 单测通过（UN 框架经协议 Mock）
