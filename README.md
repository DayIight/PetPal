# PetPal — 宠物生活方式记录与分享（iOS / SwiftUI）

![Platform](https://img.shields.io/badge/platform-iOS%2016.0%2B-lightgrey)
![Swift](https://img.shields.io/badge/Swift%205.9%2B-orange?logo=swift&logoColor=white)
![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-blue)
![Tests](https://img.shields.io/badge/tests-83%20unit%20%2B%2014%20UI-brightgreen)
[![iOS CI](https://github.com/DayIight/PetPal/actions/workflows/ios-ci.yml/badge.svg)](https://github.com/DayIight/PetPal/actions/workflows/ios-ci.yml)

以宠物为中心的本地生活记录工具：档案管理、日常记录、重复提醒、成长看板，
外加 Mock 实现的宠友社交信息流与桌面小组件。数据默认只存本地 Core Data，隐私优先。

## 功能一览

- **宠物档案**：增删改查、品种目录、头像压缩、多宠物切换、删除级联清理与二次确认
- **日常记录**：7 类预设模板 + 自定义模板，时间轴 / 日历双视图，备注与心情，记录编辑
- **提醒**：每日重复、通知权限申请、点击通知深链到宠物详情、时区变更全量重排
- **成长看板**：体重折线图（月/年聚合）、月度打卡热力图、疫苗/体检时间线、A4 PDF 导出分享
- **宠友社交（Mock）**：信息流分页、点赞、两级评论、表情回应、收藏、系统分享
- **互动消息**：点赞/评论/回复通知，点击跳转对应动态的评论区并定位高亮目标评论
- **桌面小组件**：WidgetKit 今日提醒卡片，App Group 快照共享，深链 `petpal://pet/<uuid>`

## 技术栈与架构

- Swift 5.9+ 工具链（语言模式 Swift 5，`SWIFT_STRICT_CONCURRENCY=targeted`）
- SwiftUI / iOS 16.0+（Swift Charts、NavigationStack、presentationDetents）
- MVVM + Repository 边界：健康与档案数据走 Core Data；社交仅定义 `SocialRepository`
  协议 + Mock 实现，未来替换远程实现时上层零改动
- 跨实例一致性：各 Repository 写库后经 NotificationCenter 广播，订阅方 ViewModel
  持有实例原地刷新
- Kingfisher 图片加载（磁盘缓存上限 200MB）

## 模块总览

| 模块 | 目录 | 内容 |
|---|---|---|
| M1 宠物档案 | `M1_PetProfile/` | 档案 CRUD、校验、头像、宠物管理页 |
| M2 日常记录 | `M2_DailyRecords/` | 预设/自定义模板、时间轴、日历、记录编辑 |
| M3 社交 | `M3_Social/` | 信息流、评论、消息跳转、发布表单（Mock） |
| M4 提醒 | `M4_Reminders/` | 通知调度、重复规则、深链路由 |
| M5 看板 | `M5_Dashboard/` | 体重曲线、热力图、健康时间线、PDF 导出 |
| M6 设计规范 | `M6_Design/` | 设计 Token、语义化颜色、无障碍约定、根导航 |
| M7 原型 | `M7_Prototype/` | App 入口、五标签栏、体重录入、UI 自动化 |
| M8 小组件 | `M8_Widget/` + `PetPalWidget/` | WidgetKit 快照同步与今日提醒卡片 |

## 最近更新（2026-09-27）

- 消息页支持点击跳转到对应动态的评论区，评论类消息定位并高亮目标评论
- 记体重 / 宠物档案的体重支持数字键盘直接输入（保留 ±0.1 微调，越界保存前拦截）
- 修复记录页添加记录后时间轴/日历/看板不刷新的问题（ViewModel 未持有 Repository
  导致变更广播断开），附回归测试

## 构建与测试

仓库已包含可直接打开的 `PetPal.xcodeproj`。本机需要安装完整 Xcode，首次使用前执行：

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

构建 iOS 模拟器 App：

```sh
./scripts/build-ios.sh
```

运行全部单元测试与 UI 测试：

```sh
./scripts/test-ios.sh
```

如需修改工程配置，请编辑 `project.yml` 后执行 `xcodegen generate`。

## 里程碑

- 2026-09-20 整改基线：依据《PetPal_产品诊断报告_2026-09-20.md》完成 H/M/L 三级整改
  （详见《整改说明_2026-09-20.md》），全量单元测试 + UI 测试通过
- M1–M8 八轮交付完毕，组装步骤见 `M7_Prototype/README.md`
