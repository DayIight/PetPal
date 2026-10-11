# PetPal 1.0 中文发布材料

本目录准备可审核的本地材料，未向 App Store Connect 上传或发布。

- `metadata.json`：名称、副标题、推广文本、描述、关键词与版本说明，供粘贴。
- `审核说明.md`：实际功能与权限路径、审核备注、发布者待填写项。
- `acceptance.json`：真机、最低系统、TestFlight 的结构化待验收记录；补齐实测证据后才可标记通过。
- `真机与TestFlight验收.md`：Xcode 真机安装步骤、验收表、反馈流程。
- `screenshots/iphone/` 与 `screenshots/ipad/`：原生截图，按今日、记录、成长、报告、档案排序。详情见 `screenshots/manifest.json`。
- 根目录 `output/pdf/`：标准、长文本与空数据就医报告样例，全部为虚构测试资料。

资料版本：2026-10-11。需求基线为仓库根目录 `PetPal_PRD_2026-10-03.md`，历史社交愿景已单独归档。

材料检查：在仓库根目录执行 `python3 scripts/check_release_materials.py`。默认只检查材料；加 `--submission` 时还检查真实联系信息与签名配置，当前应报告尚缺项。

当前发布依赖：真实运营主体/政策/支持渠道、Team/正式 Bundle ID/App Group、真机与最低系统验收、TestFlight 分发验收。商店材料准备完成不等于 App 已可提交。

截图与字段限制已按 [Apple 截图规格](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications) 和 [版本信息](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information) 核对：本项目准备大屏 iPhone 与 13 英寸 iPad 原生截图；关键词按 UTF-8 100 字节限制检查，描述按 4000 字符检查。提交前仍应以后台对应版本的校验为准。

复现截图：运行 `ReleaseFlowUITests/test_storeScreenshots` 并指定 iPhone 18 Pro Max 与 iPad Pro 13-inch (M5)，随后用 `xcrun xcresulttool export attachments` 导出附件，再执行 `python3 scripts/export_release_attachments.py <附件目录>`。截图使用原生尺寸，不裁剪、不放大；清单含尺寸与 SHA-256。
