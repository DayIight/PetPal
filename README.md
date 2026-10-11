# PetPal — 宠物日常与健康记录（iOS / SwiftUI）

![PetPal App Icon](M6_Design/AppIcon/AppIcon-Monet-v2.png)

![Platform](https://img.shields.io/badge/platform-iOS%2016.0%2B-lightgrey)

![Swift](https://img.shields.io/badge/Swift%205.9%2B-orange?logo=swift\&logoColor=white)

![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-blue)

![iOS CI](https://github.com/DayIight/PetPal/actions/workflows/ios-ci.yml/badge.svg)

PetPal 是无需注册的本地宠物日常与健康记录工具，支持 iPhone 和 iPad。通过「今日 / 记录 / 成长 / 我的」四个标签管理宠物档案、记录、提醒和健康资料，数据默认保存在本机 Core Data。

## 功能介绍

- **宠物档案**：管理多只宠物的物种、品种、生日、体重、头像、过敏源及兽医联系方式，随时切换当前宠物。
- **日常记录**：喂食、遛弯、训练、驱虫、疫苗、体检、美容、服药共 8 类预设模板，也可创建自定义模板；支持照片、备注、心情、历史补录与编辑删除，通过时间轴或日历回看。
- **提醒与待办**：支持每日、每周、每月、每年及一次性提醒，显示今日和逾期待办。填写并保存对应记录后完成该次任务，删除完成记录可恢复待办；疫苗、驱虫记录可关联下次提醒。
- **首次使用引导**：按「创建档案 → 保存第一条记录 → 设置提醒」完成入门，可跳过，也可从「我的」重新打开。
- **成长看板**：查看体重月／年曲线、多宠物体重对比、月度打卡热力图及疫苗／驱虫／体检时间线，管理手录体重；历史事件与下次计划分别显示。
- **就医 PDF**：按全部日期或自定义范围导出当前宠物的档案、过敏源、体重及疫苗／驱虫／体检／用药资料，支持系统分享。
- **完整备份与恢复**：导出全部宠物的数据库和照片，支持恢复准备取消及每周本机自动备份，页面显示备份状态。
- **隐私与支持**：提供离线隐私说明和反馈模板；宠物资料无需上传到开发者服务器。
- **桌面小组件**：显示宠物头像与今日提醒，点击进入对应宠物的记录页；iOS 17 起可通过左右箭头切换宠物页面。

## 开始使用

1. 打开 App，在「今日」按引导创建第一只宠物；之后可在「我的」管理更多档案或切换宠物。
2. 在「记录」选择预设或自定义模板，填写内容后保存。补录历史事件时选择实际发生时间，再通过时间轴或日历查看。
3. 在提醒管理中选择类型、重复规则和时间。保存时可授权通知；没有通知权限仍可在 App 中查看待办。
4. 点击今日或逾期待办，填写并保存对应记录，完成本次任务。取消或保存失败时任务保持待办状态。
5. 在「成长」查看体重与健康时间线；在「我的 → 数据备份」定期导出完整备份。

## 导出就医报告

在「成长 → 导出 PDF」选择全部日期或自定义范围，生成后通过系统分享面板保存或发送。报告固定使用当前宠物，日期范围包含首尾整天；档案和过敏源采用导出时的当前值，下次日期标为计划。

报告包含已填写的芯片号、兽医联系方式及健康内容，分享前请核对范围和接收方。报告用于就诊沟通，不提供诊断或治疗建议。

## 备份与恢复

在「我的 → 数据备份」导出 `.petpalbackup` 文件，并保存到 App 外的可信位置。恢复时选择备份文件，按页面提示确认；文件校验和恢复准备期间可以取消，进入数据库替换后会完成提交或回滚。

本机每周自动备份保留两份。卸载 App 会同时清除本机数据及本机备份，因此仍需定期导出。完整备份包含全部宠物的资料和照片，文件未加密，分享与存放时应妥善保管。

## 添加桌面小组件

在 iOS 主屏幕长按空白处，进入小组件列表并选择 PetPal，添加小号或中号卡片。iOS 17 起可通过箭头循环查看多只宠物，小组件记住上次查看的宠物；iOS 16 显示 App 当前宠物。

点击卡片或提醒进入对应宠物的记录页。真机共享数据需要 App 与 Widget 使用相同、有效签名的 App Group，配置方法见 [真机安装与验收教程](docs/release/zh-Hans/真机与TestFlight验收.md)。

## 构建与测试

本机需安装完整 Xcode 和 iOS Simulator 运行时。首次配置开发工具路径：

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

打开仓库中的 `PetPal.xcodeproj`，选择 `PetPal` scheme 和 iPhone／iPad 模拟器，再点击 Run。命令行构建：

```sh
./scripts/build-ios.sh
```

运行单元测试与 UI 测试：

```sh
./scripts/test-ios.sh
```

脚本默认选择可用的 iPhone 模拟器；也可通过 `PETPAL_TEST_DEVICE_ID` 指定设备。真机安装、签名配置和 TestFlight 验收步骤见 [操作教程](docs/release/zh-Hans/真机与TestFlight验收.md)。

修改工程配置时编辑 `project.yml`，再执行：

```sh
xcodegen generate
```

## 技术栈与模块

项目使用 Swift 5.9+ 工具链、Swift 5 语言模式和 SwiftUI，最低支持 iOS 16.0。界面采用 MVVM，业务数据通过 Repository 访问 Core Data；Repository 写库后通过 NotificationCenter 通知订阅方刷新。图表使用 Swift Charts，小组件使用 WidgetKit。

| 模块        | 功能与开发说明                                           |
| --------- | ------------------------------------------------- |
| M1 宠物档案   | [档案管理、校验、头像与级联删除](M1_PetProfile/README.md)        |
| M2 日常记录   | [预设／自定义模板、时间轴、日历与记录编辑](M2_DailyRecords/README.md) |
| M3 社交原型   | [归档演示源码说明](M3_Social/README.md)，不参与正式构建           |
| M4 提醒     | [通知调度、重复规则与任务联动](M4_Reminders/README.md)          |
| M5 成长看板   | [体重、健康时间线与就医报告](M5_Dashboard/README.md)           |
| M6 设计规范   | [设计 Token、颜色、无障碍与首次引导](M6_Design/README.md)       |
| M7 App 组装 | [App 入口、运行方法与 UI 自动化](M7_Prototype/README.md)     |
| M8 小组件    | [Widget 快照、翻页与深链](M8_Widget/README.md)            |

## 文档入口

- [项目文档索引](docs/project/INDEX.md)：产品需求、诊断、上线评估、整改、交付、验收与历史更新记录。
- [中文发布材料与操作教程](docs/release/zh-Hans/README.md)：商店素材、截图、审核说明及真机／TestFlight 验收步骤。
- [历史产品愿景](docs/archive/README.md)：保留的产品规划资料。
