# M6 设计与无障碍规范（横切约束）

MVP 范围：设计 Token（8pt 网格/圆角/阴影）、语义化颜色与深色模式、
底部五标签栏（发布按钮居中突出）、基础 VoiceOver 标注规范。
延后增强：图表逐点数据朗读精修、Accessibility Large 全页面走查、快照测试。

## 架构说明（本轮输出形式：架构说明）
本模块不产出业务功能，输出三类可执行约束：
1) `DS` 设计 Token——间距（4/8/16/24/32）、圆角（8 控件/12 卡片/16 弹层）、
统一卡片阴影参数，全 App 只允许引用 Token，禁止散落字面量；
2) 语义化颜色扩展——`pageBackground/cardBackground` 等命名封装系统语义色，
深色模式零额外代码自动适配；正文/辅助文本只用 `.primary/.secondary`；
3) `a11y` ViewModifier 约定——所有可交互元素必须 `label`；`hint` 仅在 label 无法
说清操作结果时提供（2026-09-20 整改，M-05：Apple 无障碍指南要求 hint 按需而非强制）；
图片必须提供替代文本。合规性由逐模块验收清单 + UI 走查保证。
底部导航用 `TabView` + ZStack 悬浮发布按钮实现；中间占位 tag 拦截点击转 sheet，
发布后恢复来源 tab（2026-09-20 整改，H-04：不再强制跳回首页），占位 tab 对 VoiceOver 隐藏，
发布动作由悬浮按钮独立承担读屏焦点。

## 设计 Token 表（输出形式：代码骨架，见 DesignSkeleton.swift）
| 类别 | 取值 | 用途 |
|---|---|---|
| 间距 | 4/8/16/24/32 | 8pt 网格，xs-xl |
| 圆角 | 8 / 12 / 16 | 控件 / 卡片 / 弹层 |
| 阴影 | black 8%, r8, y2 | 统一卡片阴影 |
| 颜色 | systemBackground / secondarySystemBackground / label / secondaryLabel / accentColor | 仅语义色 |
| 字体 | .largeTitle/.headline/.body/.footnote 文本样式 | 自动适配 Dynamic Type |

## 无障碍规则（输出形式：架构说明）
- 交互元素：`accessibilityLabel`（是什么）必填；`accessibilityHint`（会怎样）仅在 label
  不足以说明结果时提供；`accessibilityTraits` 按角色标注。
- 图片：装饰图 `accessibilityHidden(true)`；内容图必须有 alt 文本。
- 图表（M5）：禁止逐点朗读上百个数据点；使用 iOS 15+ `AXChartDescriptor`
  （`accessibilityChartDescriptor`）一次描述整图语义（坐标轴/序列/极值），
  另提供"朗读数据表"入口。（2026-09-20 整改，M-05）
- Dynamic Type：禁用固定字号；布局用 VStack/HStack 自适应性，Accessibility Large 下走查不截断。

## 非功能需求落点（横切提醒，详见各模块）
- 性能：冷启动 <2s（懒加载 Repository）；图片走 Kingfisher 异步解码（随原型接入）。
- 错误处理：网络失败/权限被拒/存储不足 → 统一 Toast/Alert（各 ViewModel 的 `toast` 字段已是挂点）。
- 数据安全：健康数据仅本地 Core Data；云备份仅 CloudKit 私有库；PDF 导出前校验存储（随 M5 增强）。

## 独立验收清单（M6）
- [ ] 全工程无硬编码色值（搜 `#Color(red` 为零，曲线配色除外且有注释）
- [ ] 深色模式逐页走查无异常对比度/不可读文本
- [ ] 五标签栏图标为 SF Symbols，选中=主题色，未选中=secondaryLabel
- [ ] 发布按钮居中放大、主色圆形填充，点击弹出发布 sheet 而非切换页面
- [ ] 所有按钮/列表行具备 label+hint+traits；VoiceOver 顺序合理
- [ ] 系统字号调至 Accessibility Large，关键页面无截断重叠
