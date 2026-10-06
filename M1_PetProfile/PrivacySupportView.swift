import SwiftUI

/// 正式发布前由运营方填入真实网址和联系信息；内置政策可离线阅读。
enum ReleaseContact {
    static func value(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
    static func webURL(_ key: String) -> URL? {
        guard let raw = value(key), let url = URL(string: raw), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}

struct PrivacySupportView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            Section("隐私政策 · 2026年10月6日") {
                Text("PetPal 帮助你在本机管理宠物档案、日常与健康记录、照片、提醒和成长报告。当前版本不提供账号、社区或 App 云同步，也不接入广告、跟踪或第三方统计服务。")
                if let operatorName = ReleaseContact.value("PetPalOperatorName") {
                    Text("运营方：\(operatorName)")
                }
                if let url = ReleaseContact.webURL("PetPalPrivacyPolicyURL") {
                    Link("在线隐私政策", destination: url)
                        .accessibilityIdentifier("privacy.policyLink")
                }
            }
            Section("数据与权限") {
                Text("你填写的宠物资料、健康记录、兽医联系信息和选择的照片保存在本机，PetPal 不将这些数据上传至开发者服务器。当前宠物选择和备份状态也保存在本机。")
                Text("相册选择只读取你选中的照片；拍摄照片时才申请相机权限。通知授权用于本地提醒，你可以在系统设置中撤回。宠物昵称与提醒内容可能显示在锁屏通知上，显示方式由系统通知设置控制。")
                Text("App 为生成报告检查可用磁盘空间，空间不足时显示错误。容量信息仅用于本机操作，不发送到设备外。桌面小组件通过系统 App Group 读取必要的宠物、头像和提醒快照。")
            }
            Section("导出、保存与删除") {
                Text("导出 PDF 或完整备份时，文件会发送到你主动选择的存储位置或分享对象。备份含健康记录和照片，未加密，请保存在可信位置。文件 App 可能使用你启用的 iCloud 或第三方服务，其处理方式由对应服务提供方决定。")
                Text("本机每周保存完整自动备份，保留最近两份。恢复时保留恢复前的数据库及其照片，便于诊断与回退。这些本机副本会随 App 卸载清除。")
                Text("你可以在 App 中编辑宠物档案，删除宠物及其关联记录、体重和提醒。删除当前数据不会删除已导出的文件或历史备份；请在文件 App 中管理导出的副本。卸载 App 会清除容器内数据。系统整机备份及恢复能力由你的设备与系统设置决定。")
            }
            Section("联系支持") {
                if let url = ReleaseContact.webURL("PetPalSupportURL") { Link("打开支持页面", destination: url) }
                if let email = ReleaseContact.value("PetPalSupportEmail"), let url = URL(string: "mailto:\(email)") {
                    Link("邮件联系：\(email)", destination: url)
                }
                if ReleaseContact.webURL("PetPalSupportURL") == nil && ReleaseContact.value("PetPalSupportEmail") == nil {
                    Text("测试期间，请通过获取本 App 的测试渠道联系开发者。")
                }
                Text("联系时可提供版本与操作步骤。请先导出备份，并仅在需要时主动提供相关数据。")
                Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")（\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1")）")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("隐私与支持")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
        .accessibilityIdentifier("privacy.content")
    }
}
