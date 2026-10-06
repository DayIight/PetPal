# M5 成长数据看板

MVP 范围：体重变化折线图（按月/按年切换、Y 轴自适应、多宠物曲线叠加不同颜色）。
已交付增强（见 DashboardView.swift）：月度打卡热力图（5 档主题色透明度 + 每格 a11y 朗读）、
疫苗/体检时间线（nextDue 过期/待进行/已完成三态）、A4 PDF 导出（UIGraphicsPDFRenderer 三页：
基本信息/图表快照/原始数据表格，导出前检查磁盘剩余空间）与系统分享面板（UIActivityViewController）。

## 架构说明（本轮输出形式：架构说明）
关键技术决策：最低部署目标已上调至 iOS 16，MVP 渲染层直接使用 **Swift Charts**
（`LineMark` + `PointMark`，`chartYScale(domain:)` 绑定自适应 Y 域），
无需自绘 Path；聚合层与 ViewModel 与渲染框架无关，保持不变。
数据来源：新增 `CDWeightSample`（petID/date/kg）本地实体，仪表盘手动录入；
M2 体检记录与来源体重在同一事务中保存、更新和删除。手动体重可在成长页「管理体重记录」编辑/删除；来源体重由体检记录管理。
当前体重取日期最新的有效样本，无样本时取档案初始值；档案、看板与 PDF 使用同一宠物数据快照。
聚合逻辑为纯函数 `ChartSeriesBuilder`：按宠物分组 → 按月/年桶取均值 → 生成 `ChartSeries`，
Y 域 = 全序列 min/max ±10%  padding（下限 0.5kg），空数据返回 0...1 占位。
多曲线配色经 `ChartPalette` 按序取模，保证同屏不同色；颜色仅用于数据区分，
文本仍用语义化颜色。`DashboardViewModel` 持有粒度与宠物选择集，变更即重建序列。

## 数据模型（Core Data 实体 `CDWeightSample`，输出形式：架构说明）

| 属性 | 类型 | 说明 |
|---|---|---|
| id | UUID | 主键 |
| petID | UUID | 关联宠物，支持多宠物叠加 |
| kg | Double | 0.1...100.0（复用 M1 校验范围） |
| date | Date | 采样日期，聚合桶依据 |
| sourceRecordID | UUID? | 来源体检 ID；手录为空，编辑体检原位更新 |

## 视图层级（输出形式：架构说明）
```
DashboardView
 ├─ GranularityPicker（按月/按年 segmented）
 ├─ PetChipSelector（多选，控制叠加曲线）
 ├─ WeightLineChart（Swift Charts；VoiceOver：每点 accessibilityLabel="3月，8.5公斤"）
 └─ Legend（颜色点 + 宠物昵称）
```

## 状态管理与关键交互（输出形式：代码骨架，见 DashboardSkeleton.swift）
- `granularity` / `selectedPetIDs` 变更 → `rebuild()` 同步重建（数据量小，无需异步）。
- X 轴定位用桶起始日期归一化到 0...1，乘以图表宽度；Y 用 yDomain 反向映射。

## 测试要点（输出形式：代码骨架，见 DashboardTests.swift）
- 同月两条样本取均值；跨年分桶正确；年粒度合并月份。
- yDomain：单值 8.5 → 8.0...9.0；空数据 → 0...1。
- 多宠物序列 colorIndex 互不相同。

## 独立验收清单（M5 MVP）
- [ ] 按月/按年切换后 X 轴桶与数据点正确重排
- [ ] Y 轴随数据范围自适应，极值不被裁剪
- [ ] 勾选多只宠物时曲线颜色互不相同，图例对应正确
- [ ] 无数据时显示占位提示而非空白坐标系
- [ ] 折线数据点支持 VoiceOver 朗读「月份，体重」
- [ ] 深色模式下图表网格/文本使用语义化颜色
- [ ] Builder/Repository 单测通过
