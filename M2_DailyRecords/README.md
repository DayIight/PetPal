# M2 结构化日常记录系统

2026-10-06 补充：时间轴与日历都可打开详情并编辑/删除；删除成功后清理照片和关联体重、提醒。体检体重统一校验为 0.1–100kg，并与来源记录同步。疫苗/驱虫的可选下次日期可关联一次性提醒。新自定义记录保存模板 ID、schema 版本、字段标题/类型/选项快照，模板更改或删除后仍可查看和编辑；没有完整快照的旧记录保留原答案，提供查看/删除并说明编辑限制。

MVP 范围：7 类预设模板、时间轴视图、图片附件（≤9 张）、备注 + 心情标签。
波3进展（2026-09-25）：自定义模板与日历月视图已全量落地（逻辑+UI）——`CustomTemplate`
（7 种字段类型、Codable JSON 存 `CDCustomTemplate`、上限 20 个超限抛 `limitExceeded`）、
`CalendarGridBuilder`（月网格 + 每日计数纯函数）、`RecordKind.custom` 与
`Record.templateName` 快照；UI 在 `RecordCalendarView.swift` / `CustomTemplateViews.swift`。
注意：`CalendarDay.id` 必须为稳定身份（占位格 "blank-N"、日格 "d-<时间戳>"），
随机 UUID 会导致 SwiftUI 无限重渲染（已修复，勿回退）。
仍延后：15s 视频压缩。
一期补齐（2026-10-04）：表单图片九宫格（`RecordPhotoPicker`）、记录编辑入口（详情页「编辑」复用表单，
`RecordFormViewModel` 编辑模式走 `update` 保留 createdAt）、心情预设+自定义（`MoodPicker`，自定义 ≤10 字）、
体检模板新增「体重(kg)」字段并自动抽取到 `WeightRepository`（`WeightExtraction`，编辑重存同日同值去重）。

## 架构说明（本轮输出形式：架构说明）
M2 沿用 MVVM + Repository：`TimelineView / RecordFormView` →
`TimelineViewModel / RecordFormViewModel` → `RecordRepository` 协议 →
`CoreDataRecordRepository`（与 M1 共用 `CoreDataStack`，新增 `CDRecord` 实体）。
模板元数据为纯代码定义（`RecordKind.fields`），不建表，新增模板只改枚举；
答案以 `[String: String]` 字典存 Transformable 字段，数字/日期序列化为字符串，
换取 schema 稳定——自定义模板（延后）接入时无需 Core Data 迁移。
时间轴分组为纯函数 `TimelineGrouper`，输入排序后记录、输出"日倒序+组内时间倒序"分区，独立可测。
所有记录强制携带 `petID`，Repository 只提供按宠物维度的查询接口，从协议层杜绝跨宠物查看。
媒体边界：图片 ≤9 张、单张 ≤10MB（JPEG/HEIC/PNG），落盘复用 M1 压缩策略；视频整条延后。

## 数据模型（Core Data 实体 `CDRecord`，输出形式：架构说明）

| 属性 | 类型 | 约束 |
|---|---|---|
| id | UUID | 主键 |
| petID | UUID | 必填，关联 M1 宠物，级联删除 |
| kind | String | RecordKind 原始值（7 类之一） |
| answers | Transformable | `[String: String]`，键为模板字段 key |
| note | String | ≤200 字 |
| mood | String | 预设表情或自定义文本，1 个 |
| photoFileNames | Transformable | `[String]`，≤9，文件名指向 Documents |
| createdAt | Date | 时间轴分组与排序依据 |

预设模板核心字段（`RecordKind.fields` 定义，示例）：
- 喂食：食物类型(文本*)、克数(数字*)、用餐时段(单选：早/午/晚*)
- 疫苗：疫苗名称(文本*)、接种医院(文本)、下次截止日期(日期)
- 遛弯：时长(数字,分钟)、地点(文本)；训练：科目(文本*)、时长(数字)
- 驱虫：药品名(文本*)、下次日期(日期)；体检：医院(文本)、结论(文本)、体重(数字,自动抽取到看板)
- 美容：项目(多选)、门店(文本)

## 视图层级（输出形式：架构说明）
```
RecordTabView（按宠物切换，宠物选择器置顶）
 └─ TimelineView：Section(按日) → RecordRow（头像/类型图标/摘要/心情）
      └─ RecordDetailView（支持编辑——复用 RecordFormView 数据驱动表单，`RecordRepository.update` 保留原 createdAt 原位更新；2026-09-20 整改落地，M-01）
RecordFormView（选模板 → 动态渲染字段 → 备注/心情/图片九宫格）
```
日历月视图、视频附件为延后项，接口预留（`Record.videoFileName` 占位注释）。

## 状态管理（输出形式：架构说明）
- `TimelineViewModel`：订阅 `repo.recordsPublisher(petID:)`，`.map(TimelineGrouper.group)`
  直接产出 sections；宠物切换重建订阅。
- `RecordFormViewModel`：持有 `draft: Record`；字段渲染由 `kind.fields` 驱动，
  `answers` 字典写回；`save()` 先校验再落库。

## 关键交互逻辑（输出形式：代码骨架，见 DailyRecordSkeleton.swift）
1. 模板驱动表单：`ForEach(kind.fields)` 按字段类型渲染文本/数字/单选控件。
2. 图片：`PhotosPicker(maxSelectionCount: 9)` → `MediaPolicy` 校验 ≤10MB → 压缩落盘。
3. 时间轴：字典按 `Calendar.startOfDay` 分组，日倒序、组内 createdAt 倒序。

## 测试要点（输出形式：代码骨架，见 DailyRecordTests.swift）
- `RecordValidatorTests`：备注超 200 字、图片超 9 张、必填字段缺失；
  number 字段类型与范围校验（2026-09-20 整改，M-02：非数字/越界拒绝，选填留空放行）。
- `TimelineGrouperTests`：跨日分组、日倒序、组内时间倒序。
- `CoreDataRecordRepositoryTests`：按 petID 隔离查询、删除后推送更新、update 保留 createdAt 原位更新。

## 独立验收清单（M2 MVP）
- [x] 7 类模板字段与规格一致，必填项缺失时禁止保存并提示
- [x] 备注超过 200 字被拦截；心情标签单选（预设+自定义，2026-10-04 落地）
- [x] 单条记录图片 1-9 张，单张 >10MB 被拒绝并提示（表单九宫格 2026-10-04 落地）
- [x] 时间轴按日倒序分组、组内按创建时间倒序，行内显示头像/类型/摘要
- [x] 切换宠物后仅显示该宠物记录，无跨宠物数据
- [x] 删除记录后时间轴即时刷新
- [ ] 深色模式与 Dynamic Type 适配（同 M1 规范）
- [x] Validator/Grouper/Repository 单元测试通过
