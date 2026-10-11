# PetPal — 宠物日常与健康记录（iOS / SwiftUI）

<img src="M6_Design/AppIcon/AppIcon-Monet-v2.png" alt="PetPal App Icon" width="120" align="right">

![Platform](https://img.shields.io/badge/platform-iOS%2016.0%2B-lightgrey)
![Swift](https://img.shields.io/badge/Swift%205.9%2B-orange?logo=swift&logoColor=white)
![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-blue)
![Tests](https://img.shields.io/badge/tests-222%20unit-brightgreen)
[![iOS CI](https://github.com/DayIight/PetPal/actions/workflows/ios-ci.yml/badge.svg)](https://github.com/DayIight/PetPal/actions/workflows/ios-ci.yml)

以宠物为中心的本地生活记录工具：档案管理、日常记录、重复提醒、成长看板，
以及桌面小组件、完整数据备份与恢复。首版聚焦本地工具，社交演示源码退出正式构建。数据默认只存本地 Core Data。

## 功能一览

- **宠物档案**：增删改查、品种目录、头像压缩、多宠物切换、删除级联清理与二次确认
- **日常记录**：8 类预设模板（含服药）+ 自定义模板，历史补录与发生时间编辑、时间轴 / 日历双视图，备注与心情，记录编辑与删除、字段定义快照
- **提醒**：每日/每周/每月/每年/一次性、编辑与暂停、权限回补、月末夹到月底、滚动预排截止日期、疫苗/驱虫下次日期关联、待办完成/逾期状态与记录联动
- **首次使用引导**：页内三步引导（建档 → 记录 → 提醒），可跳过，进度按已保存数据更新；在「我的」可重新打开
- **成长看板**：手录体重编辑与删除、体检来源联动、体重折线图（月/年聚合）、月度打卡热力图、疫苗/驱虫/体检时间线、按日期范围导出当前宠物的就医 PDF（档案、过敏源、体重、疫苗、驱虫、体检与用药）
- **数据备份**：完整数据库与照片包、后台导出/导入准备、恢复准备可取消、每周自动备份与失败状态
  - 完整备份最大 200 MB，数据库所有实体合计最多 100,000 条；超限备份会在恢复迁移前被拒绝，保留当前数据。一次性提醒日期必须为有限值且处于 Foundation 支持的 `Date.distantPast ... Date.distantFuture` 范围；正常过期日期和八年以后的日期仍受支持。
  - 备份最多 1,000 张单帧 JPEG/PNG；单张 ≤10 MiB、边长 ≤4,096px、≤16,000,000 像素，总计 ≤500,000,000 像素。恢复最终替换仍与主上下文串行提交或回滚，真机耗时待验收。迁移版本保存在数据库元信息中，避免每次启动重复扫描。
- **隐私与支持**：离线隐私政策，正式网址与联系信息的配置入口、主动复制反馈模板
- **桌面小组件**：每只宠物一页的今日提醒卡片，iOS 17 起左右箭头循环翻页、记住页面；点击提醒进入对应宠物的记录页，App Group 快照共享，深链 `petpal://records/<uuid>`

## 技术栈与架构

- Swift 5.9+ 工具链（语言模式 Swift 5，`SWIFT_STRICT_CONCURRENCY=targeted`）
- SwiftUI / iOS 16.0+（Swift Charts、NavigationStack、presentationDetents）
- MVVM + Repository 边界：健康与档案数据走 Core Data；保留的社交原型不参与当前构建
- 跨实例一致性：各 Repository 写库后经 NotificationCenter 广播，订阅方 ViewModel
  持有实例原地刷新

## 模块总览

| 模块 | 目录 | 内容 |
|---|---|---|
| M1 宠物档案 | `M1_PetProfile/` | 档案 CRUD、校验、头像、宠物管理页 |
| M2 日常记录 | `M2_DailyRecords/` | 预设/自定义模板、时间轴、日历、记录编辑 |
| M3 社交（归档原型） | `M3_Social/` | 信息流、评论、消息跳转、发布表单（Mock），退出正式构建 |
| M4 提醒 | `M4_Reminders/` | 通知调度、重复规则、深链路由 |
| M5 看板 | `M5_Dashboard/` | 体重曲线、热力图、健康时间线、PDF 导出 |
| M6 设计规范 | `M6_Design/` | 设计 Token、语义化颜色、无障碍约定、根导航、应用图标资产 |
| M7 原型 | `M7_Prototype/` | App 入口、四标签栏、体重录入、UI 自动化 |
| M8 小组件 | `M8_Widget/` + `PetPalWidget/` | WidgetKit 快照同步与今日提醒卡片 |

## 最近更新（2026-10-11）

- B4/B5/A5：首次引导、完整就医报告与中文发布材料；[发布材料与真机验收步骤](docs/release/zh-Hans/README.md)。当前 PRD 已与四标签本地 App 对齐，历史愿景单独归档。

- B1：预设与自定义记录支持发生时间；时间轴、日历、热力图与体检体重按实际发生时间统计，旧记录沿用原时间。
- B2：首页和提醒页显示今日与逾期待办，保存记录后完成单次任务；重启和备份恢复保留状态，删除记录恢复待办。服药提醒使用新增的服药记录表单。
- B3：健康时间线加入驱虫，将本次已完成与下次计划状态分开展示。
- Core Data V3 增加可选字段，支持 V1/V2 升级与旧备份恢复。行为约定及验收见 [B1–B3 交付记录](PetPal_B1-B3交付记录_2026-10-11.md)。

## 更新（2026-10-09）

- 备份读取、快照处理、编解码及恢复准备迁至后台，新增取消及临时媒体清理；自动备份合并重复请求并更新页面状态
- 旧体重迁移新增数据库版本标记；补充图片预算和异常 Core Data 集合运行验证
- 测试数量按本轮验证更新，UI 与真机/兼容性结果分别记录，详见 [备份与上线跟进](PetPal_备份与上线跟进_2026-10-09.md)

## 更新（2026-10-06）

- P0 首轮整改：本地四标签导航、退出社交演示构建、照片写入失败与 Core Data 回滚、完整备份导出和恢复、离线隐私与支持页、DiskSpace 用途声明
- P1 补充：提醒串行重排与权限刷新、完整重复日期规则、Widget 跨日时间线和 URL 注册、体检来源体重同步、自定义记录字段快照、V1 数据库与备份迁移
- 正式运营方、隐私政策公开网址和支持渠道暂缺；签名、真机通知、正式 App Group、最低系统及商店验收仍待完成
- 详见 [P0 整改记录](PetPal_P0整改记录_2026-10-06.md)

## 更新（2026-10-05）

- 应用图标切换为莫奈简洁版 **V2（奶油白）**：仅白狗橘猫大头像贴脸，无气泡无风景，
  象牙白主调；同批归档 5 个候选变体（`AppIcon-Monet-v1~v5.png`），原版带爱心气泡
  的 `AppIcon-Monet-1024.png` 保留可随时回切

## 历史更新（2026-10-04）

- 应用图标焕新为**莫奈印象派油画风格**：奶油白垂耳狗与橘猫闭眼相依，头顶爱心
  对话气泡，暖橙 × 雾蓝破碎笔触，高明度治愈基调（母版与深浅背景预览见
  `M6_Design/AppIcon/`，设计说明见该目录《AppIcon设计规范.md》）
- 图标双通道同步更新：Icon Studio 合成图标 `PetPalSocial.icon`（iOS 26+ 实际
  生效通道）与 `PetPalSocial.appiconset` 均已替换，构建产物验证通过
- 清理旧图标方案的历史导出与中间稿，旧版本可从 git 历史恢复

## 历史更新（2026-09-27）

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
