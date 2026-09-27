# PetPal — 宠物生活方式记录与分享（iOS / SwiftUI）

技术栈：Swift 5.9+ 工具链（语言模式 Swift 5，`SWIFT_STRICT_CONCURRENCY=targeted`）/ SwiftUI /
iOS 16.0+（经确认上调，解锁 Swift Charts / NavigationStack / presentationDetents）/
MVVM + Repository / Core Data（本地）。
数据边界：健康与档案数据仅存本地 Core Data；云备份仅走 CloudKit 私有库（延后）；
模块3社交仅定义 Repository 协议 + Mock 实现，不接真实后端。

## 2026-09-20 整改基线

依据《PetPal_产品诊断报告_2026-09-20.md》完成 H/M/L 三级整改（详见《整改说明_2026-09-20.md》）：
物种字段与品种目录、删除宠物级联清理、存储错误态、发布 tab 上下文保留、隐私清单、
通知点击 DeepLink 路由、多宠物切换、记录编辑、数字校验、提醒落库与送达解耦、
媒体文件清理、时区变更全量重排。全量单元测试 + UI 测试通过，
结果留存于 `build/TestResults.xcresult`。

## MVP 分层总览

| 模块 | MVP 必须实现 | 可延后增强 |
|---|---|---|
| M1 宠物档案 | 增删改查、校验、排序、删除二次确认、头像压缩 | 头像拍摄、CloudKit 私有库同步 |
| M2 日常记录 | 7类预设模板、时间轴、图片附件(≤9)、备注+心情 | 自定义模板、15s视频压缩、日历视图 |
| M3 社交 | Repository 协议 + Mock（信息流/点赞/两级评论） | 表情回应、收藏转发、三方分享SDK |
| M4 提醒 | 通知权限、每日重复、标题含昵称、点击跳转 | 周/月/年重复、提前量、时区重建 |
| M5 看板 | 体重折线图（月/年切换） | 热力图、疫苗时间线、A4 PDF导出 |
| M6 规范 | 语义化颜色、深色模式、基础 VoiceOver | 图表数据点朗读、Accessibility Large 全量走查 |

可运行原型路径：建档案 → 记一条喂食 → 设一个每日提醒（M1→M2→M4 闭环）。

## 交付节奏
每轮一个模块；每模块交付：架构说明(≤300字)、代码骨架(≤150行)、测试骨架、验收清单。
已完成：M1（M1_PetProfile/）、M2（M2_DailyRecords/）、M3（M3_Social/，仅协议+Mock）、
M4（M4_Reminders/）、M5（M5_Dashboard/）、M6（M6_Design/，横切规范，无单测，清单验收）。
M7（M7_Prototype/，可运行原型闭环 + UI 自动化脚本）。
M8（M8_Widget/ + PetPalWidget/，WidgetKit 今日提醒小组件，App Group 快照共享，深链 petpal://pet/<uuid>）。

全部七轮交付完毕。组装步骤见 M7_Prototype/README.md。

## 直接构建

仓库已包含可直接打开的 `PetPal.xcodeproj`。本机需要安装完整 Xcode，并在首次使用前执行：

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
