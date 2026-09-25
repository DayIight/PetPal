# M4 智能提醒系统

MVP 范围：通知权限请求与拒绝引导、五类提醒（喂食/疫苗/驱虫/体检/服药）、
每日重复、通知标题含宠物昵称、点击通知跳转、删除宠物联动清理。
波4进展（2026-09-25）：提前量（5m/15m/30m/1h/1d/3d，`AdvanceOption`）已落地——
`ReminderTriggerBuilder.advanceTriggers` 用真实日历把主触发器日期成分整体前移
（周几回绕、跨月跨年由 Calendar 处理），调度时以 `#adv#` 标识挂第二组触发器，
随 id 前缀一并撤销；正文格式「提前30分钟：该给【小白】喂食了」。
仍延后：每周多选/提前量的 UI 编排（Picker 接线）。

## 架构说明（本轮输出形式：架构说明）
三层拆分：`ReminderService`（编排层，协调权限/存储/调度）→
`ReminderRepository`（Core Data 存提醒配置，本地库）+
`NotificationScheduling`（UNUserNotificationCenter 协议化包装，测试用 Mock 替换）。
规则即数据：`RepeatRule` 为 Codable 枚举，JSON 存库；
`ReminderTriggerBuilder` 纯函数把规则映射为 `UNCalendarNotificationTrigger` 数组
（每周多选拆为多个 trigger），已支持全部四种重复，仅 UI 编排延后。
通知正文由 `ReminderContentBuilder` 纯函数生成，强制包含【宠物昵称】；
userInfo 携带 petID/reminderID，App 层 `UNUserNotificationCenterDelegate` 据此路由到对应页面。
联动：M1 删除宠物调用 `ReminderService.removeAll(petID:)`，先撤销 pending 通知再删库
（2026-09-20 整改后经 `PetListViewModel.reminderCleanup` 真实接线，不再是空钩子）。
时区/日历变更：已落地（2026-09-20 整改，M-06）——监听 `NSSystemTimeZoneDidChange` 后
`rescheduleAll()` 按库中配置全量重排；提醒落库时同时存 `petName`，重排无需回查 M1。
提醒配置与送达解耦（M-03）：`save` 一律先落库，权限不足仅跳过调度，不再静默丢失。

## 数据模型（Core Data 实体 `CDReminder`，输出形式：架构说明）

| 属性 | 类型 | 说明 |
|---|---|---|
| id | UUID | 同时作为通知 identifier 前缀（多 trigger 时 `#序号` 后缀） |
| petID | UUID | 必填，绑定具体宠物 |
| petName | String | 随提醒落库（整改新增），时区重排时重建通知正文无需回查 M1 |
| type | String | ReminderType 五类之一 |
| hour / minute | Int16 | 具体提醒时间 |
| repeatRule | String | RepeatRule 的 JSON 编码 |

提前量（5分钟/15分钟/30分钟/1小时/1天/3天）不建模，实现时将触发时间前移即可，属延后项。

## 权限与跳转流程（输出形式：架构说明）
1. 首次进入提醒页 → `requestPermission()` → granted/denied 写入 `@Published`。
2. denied：弹 Alert「通知权限未开启」→ `UIApplication.openSettingsURLString` 跳系统设置。
3. 点击通知：delegate 读 userInfo → DeepLink 路由至对应宠物档案页/记录页。

## 关键交互逻辑（输出形式：代码骨架，见 ReminderSkeleton.swift）
- 保存提醒 = 存库 → 校验权限 → 撤销同 id 旧调度 → 按 RepeatRule 重建 trigger 组。
- 撤销一律按 id 前缀匹配，兼容每周多选产生的多 trigger。

## 测试要点（输出形式：代码骨架，见 ReminderTests.swift）
- 正文必含【昵称】与动作词；每日 trigger repeats=true 且时分正确；每周多选产出 N 个 trigger。
- 权限被拒时 Service 不调度且状态为 denied；保存后 Mock 收到请求；removeAll 撤销+清库。

## 独立验收清单（M4 MVP）
- [ ] 首次使用弹出系统权限请求；被拒后出现引导 Alert 并可跳转系统设置
- [ ] 五类提醒均可创建，通知正文格式为「该给【昵称】XX了」
- [ ] 每日重复到点触发（真机/模拟器验证）
- [ ] 点击通知跳转到对应宠物详情页（已接线：AppDelegate → DeepLinkRouter → NavigationPath）
- [ ] 删除宠物后其全部提醒被撤销且不再触发（级联链路已实测）
- [ ] 权限被拒时提醒仍落库，界面给出开启引导，不再静默丢失
- [x] 时区变更后按库中配置全量重排（`rescheduleAll` 单测覆盖；真机改时区走查待定）
- [ ] Scheduler/Builder/Service 单测通过（UN 框架经协议 Mock）
