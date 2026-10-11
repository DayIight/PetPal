# M7 App 入口与 UI 自动化

本模块组装宠物档案、日常记录、提醒和成长看板，提供「今日 / 记录 / 成长 / 我的」四个标签。模型、仓储与服务复用各业务模块。

## 在 Xcode 运行

1. 打开仓库根目录的 `PetPal.xcodeproj`，选择 `PetPal` scheme。
2. 选择已安装运行时的 iPhone 或 iPad 模拟器，点击 Run。
3. 首次使用按今日页引导创建宠物、保存记录和设置提醒。通知权限在保存提醒时申请；拒绝后仍可查看 App 待办。
4. 安装到真机时，按 [真机与 TestFlight 验收教程](../docs/release/zh-Hans/真机与TestFlight验收.md) 配置签名并运行。

工程由根目录 `project.yml` 管理；修改后运行 `xcodegen generate`。Core Data 模型位于 `PetPal/Models/PetPal.xcdatamodeld`，保留旧模型版本以支持数据迁移。

## 运行自动化测试

在仓库根目录执行 `./scripts/test-ios.sh`，或在 Xcode 中使用 Product → Test。指定模拟器时可设置 `PETPAL_TEST_DEVICE_ID`。构建与测试的完整入口见 [项目开发教程](../README.md#构建与测试)。

`PrototypeUITests` 覆盖建档、记录、提醒与任务完成等交互；`ReleaseFlowUITests` 用于引导、报告、分享、反馈与截图流程。表单错误时保持页面并展示原因，测试通过控件的 `accessibilityIdentifier` 定位。

## 发布材料与 UI 截图

中文商店材料和 Xcode 真机步骤位于 `docs/release/zh-Hans/`。`ReleaseFlowUITests` 覆盖引导、日期范围导出、系统分享、反馈模板及五个实际页面截图。`PreviewFixtures` 仅 Debug 接受 `--petpal-preview empty|demo`：内存数据库、独立偏好域、不发通知、不备份、不写 Widget 快照；Release 无演示资料入口。
