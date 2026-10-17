# M2 结构化日常记录系统

支持 8 类预设模板与自定义模板、时间轴与日历月视图、历史补录、记录详情及编辑/删除。单条记录可附加最多 9 张图片、备注和预设或自定义心情。常用快捷可复用填写内容，搜索与筛选用于查找当前宠物的历史记录。

体检体重范围为 0.1–100kg，记录编辑或删除时同步关联体重；疫苗与驱虫可按下次日期关联提醒。自定义记录保存字段定义快照，模板更改或删除后仍可查看和编辑；没有完整快照的旧记录保留原答案，支持查看与删除，并说明编辑限制。

自定义模板最多 20 个、支持 7 种字段类型；元数据以 Codable JSON 存入 `CDCustomTemplate`。日历网格由 `CalendarGridBuilder` 生成，`CalendarDay.id` 使用稳定身份，避免 SwiftUI 重复渲染。视频附件暂不支持。

## 架构说明
M2 沿用 MVVM + Repository：`TimelineView / RecordFormView` →
`TimelineViewModel / RecordFormViewModel` → `RecordRepository` 协议 →
`CoreDataRecordRepository`（与 M1 共用 `CoreDataStack`，新增 `CDRecord` 实体）。
模板元数据为纯代码定义（`RecordKind.fields`），不建表，新增模板只改枚举；
答案以 `[String: String]` 字典存 Transformable 字段，数字/日期序列化为字符串，
换取 schema 稳定——自定义模板通过字段快照保留历史定义。
时间轴分组为纯函数 `TimelineGrouper`，输入排序后记录、输出"日倒序+组内时间倒序"分区，独立可测。
所有记录强制携带 `petID`，Repository 只提供按宠物维度的查询接口，从协议层杜绝跨宠物查看。
媒体边界：图片 ≤9 张、单张 ≤10MB（JPEG/HEIC/PNG），落盘复用 M1 压缩策略；视频整条延后。

## 数据模型（Core Data 实体 `CDRecord`，输出形式：架构说明）

| 属性 | 类型 | 约束 |
|---|---|---|
| id | UUID | 主键 |
| petID | UUID | 必填，关联 M1 宠物，级联删除 |
| kind | String | RecordKind 原始值（8 类之一） |
| answers | Transformable | `[String: String]`，键为模板字段 key |
| note | String | ≤200 字 |
| mood | String | 预设表情或自定义文本，1 个 |
| photoFileNames | Transformable | `[String]`，≤9，文件名指向 Documents |
| createdAt | Date | 创建时间，编辑保留 |
| occurredAt | Date? | V3 实际发生时间，旧记录回退 createdAt；用于时间轴、日历、热力图与体检体重 |
| completedReminderID / completedDueAt / completedDay | UUID? / Date? / String? | V3 单次任务完成关联，与记录同事务保存，编辑时保留 |

预设模板核心字段（`RecordKind.fields` 定义，示例）：
- 喂食：食物类型(文本*)、克数(数字*)、用餐时段(单选：早/午/晚*)
- 疫苗：疫苗名称(文本*)、接种医院(文本)、下次截止日期(日期)
- 遛弯：时长(数字,分钟)、地点(文本)；训练：科目(文本*)、时长(数字)
- 驱虫：药品名(文本*)、下次日期(日期)；体检：医院(文本)、结论(文本)、体重(数字,自动抽取到看板)
- 美容：项目(多选)、门店(文本)
- 服药：药品名(文本*)、实际用量(文本*)

## 视图层级
```
RecordTabView（按宠物切换，宠物选择器置顶）
 └─ TimelineView：Section(按日) → RecordRow（头像/类型图标/摘要/心情）
      └─ RecordDetailView（支持编辑——复用 RecordFormView 数据驱动表单，`RecordRepository.update` 保留原 createdAt 原位更新）
RecordFormView（选模板 → 动态渲染字段 → 备注/心情/图片九宫格）
```
日历月视图支持按月查看每日记录数量；视频附件暂不支持。

## 状态管理
- `TimelineViewModel`：订阅 `repo.recordsPublisher(petID:)`，`.map(TimelineGrouper.group)`
  直接产出 sections；宠物切换重建订阅。
- `RecordFormViewModel`：持有 `draft: Record`；字段渲染由 `kind.fields` 驱动，
  `answers` 字典写回；`save()` 先校验再落库。

## 关键交互逻辑（输出形式：代码骨架，见 DailyRecordSkeleton.swift）
1. 模板驱动表单：`ForEach(kind.fields)` 按字段类型渲染文本/数字/单选控件。
2. 图片：`PhotosPicker(maxSelectionCount: 9)` → `MediaPolicy` 校验 ≤10MB → 压缩落盘。
3. 时间轴：字典按 `Calendar.startOfDay` 分组，日倒序、组内按发生时间倒序（旧记录回退到 createdAt）。

## 测试要点（输出形式：代码骨架，见 DailyRecordTests.swift）
- `RecordValidatorTests`：备注超 200 字、图片超 9 张、必填字段缺失；
  number 字段类型与范围校验（非数字/越界拒绝，选填留空放行）。
- `TimelineGrouperTests`：跨日分组、日倒序、组内时间倒序。
- `CoreDataRecordRepositoryTests`：按 petID 隔离查询、删除后推送更新、update 保留 createdAt 原位更新。

## 补录与任务联动

预设及自定义记录表单可选择过去或当前的发生时间。日历可回溯到最早记录月份；热力图仍按原规则展示最近 24 个月。时间轴与详情带年份，方便跨年回看。体检记录更改发生时间后原位更新其体重样本，保留记录创建时间。

从待办进入表单时携带具体任务身份；保存失败或取消不会完成任务。重复提交被拒绝，删除完成记录后重新显示对应任务。服药预设记录药品名和实际用量，不生成用药建议。

## 常用快捷

在「今日 → 管理常用快捷」添加预设记录类型，或从已保存记录建立快捷项，包括拥有完整模板快照的自定义记录。编辑时填写快捷名称和常用内容，每只宠物最多保存 6 项；可重命名、修改内容或删除，也可主动用最近同类记录重设内容。

`QuickAction` 保留设置时的记录类型、答案、备注、心情和自定义模板快照，后续新增记录不会自动覆盖它。名称为 1–30 字。`QuickActionRepository` 将值类型存入 V4 `CDCareItem` 的 `quickAction` 类别，并检查宠物归属和数量。

点击快捷项后，`makeDraft` 生成新的记录身份，以当前时间作为发生时间，清除照片、日期字段和原任务完成关联。`PresetRecordFormView(prefilling:)` 展示预填内容，用户核对必填项并点击保存后才新增记录；取消不会写入历史或完成待办。

## 搜索与筛选

在「记录」输入关键词，可匹配记录类型、模板名称、答案内容或备注，英文忽略大小写和音符差异。点筛选按钮选择全部或某一记录类型，也可开启日期范围；文字、类型和日期条件同时生效。

`RecordSearchFilter` 仅返回当前 `petID` 的记录，按实际发生时间倒序排列，旧记录回退创建时间。日期包含首尾全天；开始日期晚于结束日期时显示错误，不返回结果。点击「清除搜索与筛选」恢复原时间轴或日历。筛选只影响展示，不改动记录。

医疗资料可以关联当前宠物的疫苗、驱虫、体检或服药记录。删除这类记录时，Repository 在同一事务中解除医疗资料关联，医疗文件继续保留；资料入口见 [M5 使用说明](../M5_Dashboard/README.md)。
