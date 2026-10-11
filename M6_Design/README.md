# M6 设计与无障碍规范（横切约束）

MVP 范围：设计 Token（8pt 网格/圆角/阴影）、语义化颜色与深色模式、
「今日 / 记录 / 成长 / 我的」四标签栏、基础 VoiceOver 标注规范。
延后增强：图表逐点数据朗读精修、Accessibility Large 全页面走查、快照测试。

## 架构说明
本模块不产出业务功能，输出三类可执行约束：
1) `DS` 设计 Token——间距（4/8/16/24/32）、圆角（8 控件/12 卡片/16 弹层）、
统一卡片阴影参数，全 App 只允许引用 Token，禁止散落字面量；
2) 语义化颜色扩展——`pageBackground/cardBackground` 等命名封装系统语义色，
深色模式零额外代码自动适配；正文/辅助文本只用 `.primary/.secondary`；
3) `a11y` ViewModifier 约定——所有可交互元素必须 `label`；`hint` 仅在 label 无法
说清操作结果时提供；
图片必须提供替代文本。合规性由逐模块验收清单 + UI 走查保证。
底部导航使用 `TabView`，默认进入「今日」。记录入口位于记录页；社交信息流、消息及悬浮发布入口已退出正式构建。

## 设计 Token 表（输出形式：代码骨架，见 DesignSkeleton.swift）
| 类别 | 取值 | 用途 |
|---|---|---|
| 间距 | 4/8/16/24/32 | 8pt 网格，xs-xl |
| 圆角 | 8 / 12 / 16 | 控件 / 卡片 / 弹层 |
| 阴影 | black 8%, r8, y2 | 统一卡片阴影 |
| 颜色 | systemBackground / secondarySystemBackground / label / secondaryLabel / accentColor | 仅语义色 |
| 字体 | .largeTitle/.headline/.body/.footnote 文本样式 | 自动适配 Dynamic Type |

## 无障碍规则
- 交互元素：`accessibilityLabel`（是什么）必填；`accessibilityHint`（会怎样）仅在 label
  不足以说明结果时提供；`accessibilityTraits` 按角色标注。
- 图片：装饰图 `accessibilityHidden(true)`；内容图必须有 alt 文本。
- 图表（M5）：禁止逐点朗读上百个数据点；使用 iOS 15+ `AXChartDescriptor`
  （`accessibilityChartDescriptor`）一次描述整图语义（坐标轴/序列/极值），
  另提供"朗读数据表"入口。
- Dynamic Type：禁用固定字号；布局用 VStack/HStack 自适应性，Accessibility Large 下走查不截断。

## 非功能需求落点（横切提醒，详见各模块）
- 性能：真机 Release 冷启动 P95 ≤2s 为待验收目标；正式版本使用本地头像和记录照片，保存时压缩最长边 ≤1080px、JPEG 0.8；工程已移除 Kingfisher。备份读取、快照处理、图片校验和编码在后台执行。
- 错误处理：网络失败/权限被拒/存储不足 → 统一 Toast/Alert（各 ViewModel 的 `toast` 字段已是挂点）。
- 数据安全：健康数据保存在本机 Core Data；每周保留两份完整备份，用户可导出未加密 `.petpalbackup` 文件；当前无 App 云同步。PDF 导出前检查可用存储空间。备份恢复准备可取消，数据库替换阶段完整提交或回滚。

## 首次使用引导

`Onboarding.swift` 在今日页显示建档、第一条记录、第一个提醒三步，按同一宠物已保存数据推进。可跳过、完成后不再自动出现；老用户升级不自动弹出；我的页可重新打开。引导解释本机保存与外部完整备份，不在启动时请求通知授权。
