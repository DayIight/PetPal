import SwiftUI
import UIKit

enum SupportFeedback {
    static func template(version: String, build: String, system: String, device: String) -> String {
        """
        PetPal 问题反馈
        版本：\(version)（\(build)）
        系统：\(system)
        设备类型：\(device)（请补充具体型号）
        发生时间：
        操作步骤：1.  2.  3.
        预期结果：
        实际结果：
        是否可以重复：
        附件（可选，请遮盖私人信息）：
        """
    }
}

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
    @State private var copied = false
    var body: some View {
        List {
            Section("隐私政策 · 2026年10月17日") {
                Text("PetPal 帮助你在本机管理宠物档案、日常与健康记录、照片、提醒、用药疗程、医疗资料和照护说明，并生成就医报告与照护交接卡。当前版本不提供账号、社区或 App 云同步，也不接入广告、跟踪或第三方统计服务。")
                if let operatorName = ReleaseContact.value("PetPalOperatorName") {
                    Text("运营方：\(operatorName)")
                }
                if let url = ReleaseContact.webURL("PetPalPrivacyPolicyURL") {
                    Link("在线隐私政策", destination: url)
                        .accessibilityIdentifier("privacy.policyLink")
                }
            }
            Section("数据与权限") {
                Text("你填写的宠物资料、健康记录、用药安排、照护说明、兽医与紧急联系信息，以及选择的照片和医疗文件保存在本机，PetPal 不将这些数据上传至开发者服务器。医疗 PDF 保留导入文件，JPEG／PNG 图片按方向归一化后存储。当前宠物选择和备份状态也保存在本机。")
                Text("相册选择只读取你选中的照片；拍摄照片时才申请相机权限。通知授权用于本地提醒，你可以在系统设置中撤回。宠物昵称与提醒内容可能显示在锁屏通知上，显示方式由系统通知设置控制。")
                Text("医疗资料导入通过系统文件选择器读取你选中的文件，不扫描其他文件。医疗原件可能包含姓名、电话等信息，App 不自动解读其中的医疗内容。")
                Text("App 为生成报告检查可用磁盘空间，空间不足时显示错误。容量信息仅用于本机操作，不发送到设备外。桌面小组件通过系统 App Group 读取必要的宠物、头像和提醒快照。")
            }
            Section("导出、保存与删除") {
                Text("导出 PDF、医疗文件或完整备份时，文件会发送到你主动选择的存储位置或分享对象。就医报告包含当前宠物已填写的芯片号、过敏信息、兽医联系方式及所选日期范围的健康资料；医疗文件分享包含所选文件的内容。请在预览后核对接收人。")
                Text("照护交接卡默认包含你已填写的饮食安排、日常照护、注意事项和紧急联系人。过敏信息、进行中的用药安排和兽医联系方式默认关闭，可在导出范围页逐项选择并预览。交接卡不附带芯片号、其他病历、医疗文件或其他宠物资料。")
                Text("完整备份含全部档案字段（包括芯片号、兽医联系信息）、记录、提醒、体重、照片、常用快捷、医疗资料及文件、用药疗程，以及照护说明中的紧急联系信息。备份未加密，请保存在可信位置。文件 App 可能使用你启用的 iCloud 或第三方服务，其处理方式由对应服务提供方决定。")
                Text("本机每周保存完整自动备份，保留最近两份。恢复时保留恢复前的数据库及其媒体文件，便于诊断与回退。这些本机副本会随 App 卸载清除。")
                Text("你可以在 App 中编辑宠物档案与照护资料，删除医疗资料及对应文件，或删除宠物及其关联记录、体重、提醒和照护资料。删除已关联的健康记录只解除医疗资料关联，保留医疗文件。删除当前数据不会删除已导出的文件或历史备份；请在文件 App 中管理导出的副本。卸载 App 会清除容器内数据。系统整机备份及恢复能力由你的设备与系统设置决定。")
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
                Button("复制反馈模板") {
                    UIPasteboard.general.string = SupportFeedback.template(
                        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
                        build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1",
                        system: UIDevice.current.systemName + " " + UIDevice.current.systemVersion,
                        device: UIDevice.current.model)
                    copied = true
                }.accessibilityIdentifier("support.copyFeedback")
                Text("模板只含版本、系统及设备类型，不会附带宠物资料，也不会自动发送。")
                    .font(.footnote).foregroundStyle(.secondary)
                if copied { Text("已复制，请补充问题步骤后通过测试渠道或支持入口发送。").accessibilityIdentifier("support.copied") }
                Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")（\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1")）")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("隐私与支持")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
        .accessibilityIdentifier("privacy.content")
    }
}
