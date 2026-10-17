import SwiftUI
import QuickLook
import PDFKit
import UniformTypeIdentifiers

/// A cancelled sheet or pet switch releases the file unless metadata was committed.
private final class MedicalDocumentImportLease {
    let prepared: PreparedMedicalDocument
    private var committed = false
    init(_ prepared: PreparedMedicalDocument) { self.prepared = prepared }
    func commit() { committed = true }
    deinit { if !committed { MedicalDocumentImporter.discard(prepared) } }
}

private struct MedicalDocumentDraft: Identifiable {
    var id: UUID { document.id }
    var document: MedicalDocument
    var importedFile: MedicalDocumentImportLease?
}

struct MedicalDocumentsView: View {
    let pet: Pet
    private let repository = MedicalDocumentRepository()
    @State private var documents: [MedicalDocument] = []
    @State private var importing = false
    @State private var showImporter = false
    @State private var importTask: Task<Void, Never>?
    @State private var draft: MedicalDocumentDraft?
    @State private var deleting: MedicalDocument?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("仅显示 \(pet.nickname) 的资料。支持 PDF（20 MiB / 200页以内）、JPEG 和 PNG；不自动解读医疗内容。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if importing { ProgressView("正在安全导入…") }
                }
                if documents.isEmpty && !importing { Text("还没有医疗资料，点右上角 + 从文件导入。").foregroundStyle(.secondary) }
                ForEach(documents) { document in
                    Button { draft = MedicalDocumentDraft(document: document) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(document.title).foregroundStyle(.primary)
                            Text(RecordAnswerDate.table.string(from: document.documentDate) + (document.hospital.isEmpty ? "" : " · " + document.hospital))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("medical.document.\(document.id)")
                    .swipeActions { Button("删除", role: .destructive) { deleting = document } }
                }
            }
            .navigationTitle("医疗资料 · \(pet.nickname)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() }.disabled(importing) }
                ToolbarItem(placement: .confirmationAction) { Button { showImporter = true } label: { Image(systemName: "plus") }.disabled(importing).accessibilityLabel("导入医疗资料").accessibilityIdentifier("medical.import") }
            }
            .interactiveDismissDisabled(importing)
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf, .jpeg, .png]) { result in
                switch result { case .success(let url): importFile(url); case .failure(let failure): error = failure.localizedDescription }
            }
            .sheet(item: $draft, onDismiss: reload) { item in
                MedicalDocumentEditor(pet: pet, initial: item.document, importedFile: item.importedFile, repository: repository)
            }
            .confirmationDialog("删除这份资料及原件？", isPresented: .init(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    guard let value = deleting else { return }
                    do { try repository.delete(value, petID: pet.id); reload() } catch { self.error = error.localizedDescription }
                    deleting = nil
                }
            }
            .alert("操作失败", isPresented: .init(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好", role: .cancel) {} } message: { Text(error ?? "请重试") }
            .onAppear(perform: reload)
            .onReceive(NotificationCenter.default.publisher(for: .careItemsDidChange)) { _ in reload() }
            .onDisappear { importTask?.cancel() }
        }
    }
    private func reload() { do { documents = try repository.documents(petID: pet.id) } catch { self.error = error.localizedDescription } }
    private func importFile(_ url: URL) {
        importing = true
        importTask = Task { @MainActor in
            do {
                let prepared = try await MedicalDocumentImporter.prepare(from: url)
                guard !Task.isCancelled else { MedicalDocumentImporter.discard(prepared); importing = false; return }
                let title = String(url.deletingPathExtension().lastPathComponent.prefix(100))
                draft = MedicalDocumentDraft(document: MedicalDocument(petID: pet.id, title: title.isEmpty ? "医疗资料" : title, fileName: prepared.fileName), importedFile: MedicalDocumentImportLease(prepared))
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
            importing = false
        }
    }
}

private struct MedicalDocumentEditor: View {
    let pet: Pet
    let importedFile: MedicalDocumentImportLease?
    let repository: MedicalDocumentRepository
    private let recordRepository = CoreDataRecordRepository()
    @State private var document: MedicalDocument
    @State private var records: [Record] = []
    @State private var error: String?
    @State private var preview: PDFShareItem?
    @Environment(\.dismiss) private var dismiss
    init(pet: Pet, initial: MedicalDocument, importedFile: MedicalDocumentImportLease?, repository: MedicalDocumentRepository) {
        self.pet = pet; self.importedFile = importedFile; self.repository = repository
        _document = State(initialValue: initial)
    }
    private var missingImportedFile: Bool { importedFile != nil && !FileManager.default.fileExists(atPath: repository.directory.appendingPathComponent(document.fileName).path) }
    var body: some View {
        NavigationStack {
            Form {
                Section("资料信息 · \(pet.nickname)") {
                    TextField("标题（必填，最多100字）", text: $document.title).accessibilityIdentifier("medical.title")
                    DatePicker("资料日期", selection: $document.documentDate, displayedComponents: .date)
                    TextField("医院（选填）", text: $document.hospital)
                    TextField("备注（选填）", text: $document.notes, axis: .vertical).lineLimit(3...10)
                    Picker("关联健康记录（选填）", selection: $document.recordID) {
                        Text("不关联").tag(UUID?.none)
                        ForEach(records) { record in Text(record.displayKind + " · " + RecordAnswerDate.table.string(from: record.eventDate)).tag(Optional(record.id)) }
                    }
                    if let id = document.recordID, !records.contains(where: { $0.id == id }) { Text("关联记录已不存在，请选择不关联或其他记录。").foregroundStyle(.red) }
                    if let validation = document.validationError { Text(validation).foregroundStyle(.red) }
                    if missingImportedFile { Text("导入未能保存，请取消后重新选择文件。").foregroundStyle(.red) }
                }
                Section {
                    Button("查看原件与分享") {
                        let url = repository.directory.appendingPathComponent(document.fileName)
                        guard FileManager.default.fileExists(atPath: url.path) else { error = "原件文件已不存在。"; return }
                        preview = PDFShareItem(url: url)
                    }.accessibilityIdentifier("medical.preview")
                    Text("原件可能包含姓名、电话等资料，分享前请确认内容与接收人。").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(importedFile == nil ? "编辑医疗资料" : "导入医疗资料")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(document.validationError != nil || missingImportedFile).accessibilityIdentifier("medical.save") }
            }
            .onReceive(recordRepository.recordsPublisher(petID: pet.id)) { records = $0.filter { MedicalReport.healthKinds.contains($0.kind) } }
            .sheet(item: $preview) { DocumentOriginalPreview(url: $0.url, title: document.title) }
            .alert("保存失败", isPresented: .init(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好", role: .cancel) {} } message: { Text(error ?? "请重试") }
        }
    }
    private func save() {
        do {
            guard document.petID == pet.id else { throw CareItemError.wrongOwner }
            if let importedFile { try repository.create(document, prepared: importedFile.prepared); importedFile.commit() }
            else { try repository.update(document, petID: pet.id) }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct DocumentOriginalPreview: View {
    let url: URL
    let title: String
    @State private var pdf: PDFDocument?
    @State private var sharing = false
    @Environment(\.dismiss) private var dismiss
    init(url: URL, title: String) {
        self.url = url; self.title = title
        _pdf = State(initialValue: url.pathExtension.lowercased() == "pdf" ? PDFDocument(url: url) : nil)
    }
    var body: some View {
        NavigationStack {
            Group {
                if url.pathExtension.lowercased() == "pdf" {
                    if let pdf { OriginalPDFPreview(document: pdf) }
                    else { Text("PDF 无法读取，请重新导入文件。").foregroundStyle(.secondary) }
                } else { OriginalQuickLook(url: url) }
            }.ignoresSafeArea(edges: .bottom)
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button { sharing = true } label: { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("系统分享").accessibilityIdentifier("care.document.share") }
                }
                .sheet(isPresented: $sharing) { ActivityView(activityItems: [url]).ignoresSafeArea() }
        }
    }
}

private struct OriginalPDFPreview: UIViewRepresentable {
    let document: PDFDocument
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .systemBackground
        view.document = document
        view.accessibilityIdentifier = "care.document.pdf"
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}

private struct OriginalQuickLook: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
