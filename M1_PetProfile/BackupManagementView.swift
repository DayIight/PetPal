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
    @ObservedObject private var stack = CoreDataStack.shared
    @State private var backups: [URL] = []
    @State private var document: BackupDocument?
    @State private var showExport = false
    @State private var showImport = false
    @State private var importData: Data?
    @State private var confirmRestore = false
    @State private var busy = false
    @State private var canCancel = false
    @State private var operationTask: Task<Void, Never>?
    @State private var operationStatus = "正在处理备份"
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
                    .disabled(busy || stack.backupInProgress || stack.loadError != nil)
                Button("从文件导入恢复") { showImport = true }
                    .accessibilityIdentifier("backup.import").disabled(busy || stack.backupInProgress)
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
                        .disabled(busy || stack.backupInProgress)
                    }
                }
            }
            if busy {
                ProgressView(operationStatus)
                if canCancel {
                    Button("取消处理", role: .cancel) {
                        canCancel = false
                        operationStatus = "正在取消，请稍候"
                        operationTask?.cancel()
                    }.accessibilityIdentifier("backup.cancel")
                }
            } else if stack.backupInProgress {
                ProgressView("正在处理备份，请稍候")
            }
        }
        .navigationTitle("数据备份")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() }.disabled(busy) } }
        .interactiveDismissDisabled(busy)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: .backupStatusDidChange)) { _ in refresh() }
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
                readImport(url, securityScoped: true)
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
        startOperation("正在生成完整备份") {
            document = BackupDocument(data: try await PortableBackup.createAsync())
            showExport = true
        }
    }
    private func exportExisting(_ url: URL) {
        startOperation("正在读取备份") {
            document = BackupDocument(data: try await PortableBackup.background { _ in try PortableBackup.readFile(url) })
            showExport = true
        }
    }
    private func readImport(_ url: URL, securityScoped: Bool = false) {
        startOperation("正在读取备份") {
            let access = securityScoped && url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            importData = try await PortableBackup.background { _ in try PortableBackup.readFile(url) }
            confirmRestore = true
        }
    }
    private func restore() {
        guard let data = importData else { return }
        startOperation("正在校验并准备恢复") {
            defer { importData = nil; refresh() }
            try await PortableBackup.restoreAsync(data, willCommit: {
                canCancel = false
                operationStatus = "正在替换数据，请稍候"
            })
            operationStatus = "正在重建提醒"
            message = await PortableBackup.rebuildNotifications() ?? "完整数据已恢复，请检查宠物、照片与提醒。"
        }
    }
    private func startOperation(_ status: String, work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; canCancel = true; operationStatus = status
        operationTask = Task { @MainActor in
            defer { busy = false; canCancel = false; operationTask = nil }
            do { try await work() }
            catch is CancellationError { importData = nil; message = "处理已取消，当前数据未被替换。" }
            catch { message = "备份处理失败：\(error.localizedDescription)" }
        }
    }
}
