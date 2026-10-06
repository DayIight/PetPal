import SwiftUI
import UniformTypeIdentifiers

extension UTType { static let petpalBackup = UTType(exportedAs: "com.petpal.backup", conformingTo: .data) }

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.petpalBackup] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw BackupError.damaged }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct BackupManagementView: View {
    @State private var backups: [URL] = []
    @State private var document: BackupDocument?
    @State private var showExport = false
    @State private var showImport = false
    @State private var importData: Data?
    @State private var confirmRestore = false
    @State private var busy = false
    @State private var message: String?
    @State private var lastDate: Date?
    @State private var backupError: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            Section("备份状态") {
                if let date = lastDate { LabeledContent("最近自动备份", value: date.formatted(date: .abbreviated, time: .shortened)) }
                else { Text("尚无完整自动备份") }
                if let backupError { Text(backupError).foregroundStyle(.red) }
                Text("每周自动保存完整备份，保留最近两份。自动备份仍在本机，请定期导出到文件 App 或其他设备。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button("导出完整备份") { exportCurrent() }
                    .accessibilityIdentifier("backup.export")
                    .disabled(busy || CoreDataStack.shared.loadError != nil)
                Button("从文件导入恢复") { showImport = true }
                    .accessibilityIdentifier("backup.import").disabled(busy)
            } footer: {
                Text("备份包含所有宠物、记录、体重、提醒、自定义模板及照片。恢复会替换当前数据，建议先导出当前备份。备份未加密，请妥善保管。")
            }
            if !backups.isEmpty {
                Section("本机完整备份") {
                    ForEach(backups, id: \.self) { url in
                        VStack(alignment: .leading) {
                            Text(url.deletingPathExtension().lastPathComponent).font(.caption).lineLimit(2)
                            HStack {
                                Button("导出") { exportExisting(url) }.buttonStyle(.borderless)
                                Button("恢复") { readImport(url) }.buttonStyle(.borderless)
                            }
                        }
                        .disabled(busy)
                    }
                }
            }
            if busy { ProgressView("正在处理，请稍候") }
        }
        .navigationTitle("数据备份")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() }.disabled(busy) } }
        .interactiveDismissDisabled(busy)
        .onAppear(perform: refresh)
        .fileExporter(isPresented: $showExport, document: document, contentType: .petpalBackup,
                      defaultFilename: "PetPal-\(DatabaseBackupManager.timestamp(Date()))") { result in
            document = nil
            switch result {
            case .success: message = "完整备份已导出。"
            case .failure(let error): message = "导出失败：\(error.localizedDescription)"
            }
        }
        .fileImporter(isPresented: $showImport, allowedContentTypes: [.petpalBackup]) { result in
            switch result {
            case .success(let url):
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                readImport(url)
            case .failure(let error): message = "导入失败：\(error.localizedDescription)"
            }
        }
        .confirmationDialog("用备份替换当前全部数据？", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("恢复备份", role: .destructive) { restore() }
            Button("取消", role: .cancel) { importData = nil }
        } message: { Text("原数据库副本将保留在本机。恢复后请检查提醒与照片。") }
        .alert("数据备份", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: { Text(message ?? "") }
    }
    private func refresh() {
        lastDate = UserDefaults.standard.object(forKey: "PetPal.lastCompleteBackupDate") as? Date
        backupError = UserDefaults.standard.string(forKey: "PetPal.lastBackupError")
        backups = (try? DatabaseBackupManager.completeBackups(in: DatabaseBackupManager.backupDirectory())) ?? []
    }
    private func exportCurrent() {
        busy = true
        // 与保存操作串行取得一致快照；Task 允许界面先展示处理状态。
        Task { @MainActor in
            defer { busy = false }
            do { document = BackupDocument(data: try PortableBackup.create()); showExport = true }
            catch { message = "备份失败：\(error.localizedDescription)" }
        }
    }
    private func exportExisting(_ url: URL) {
        do { document = BackupDocument(data: try readFile(url)); showExport = true }
        catch { message = "读取失败：\(error.localizedDescription)" }
    }
    private func readFile(_ url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= PortableBackup.maxBytes else { throw BackupError.tooLarge }
        return try Data(contentsOf: url)
    }
    private func readImport(_ url: URL) {
        do { importData = try readFile(url); confirmRestore = true }
        catch { message = "读取失败：\(error.localizedDescription)" }
    }
    private func restore() {
        guard let data = importData else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false; importData = nil; refresh() }
            do {
                try PortableBackup.restore(data)
                message = await PortableBackup.rebuildNotifications() ?? "完整数据已恢复，请检查宠物、照片与提醒。"
            } catch { message = "恢复失败：\(error.localizedDescription)" }
        }
    }
}
