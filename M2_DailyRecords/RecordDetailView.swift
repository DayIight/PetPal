import SwiftUI
import Combine

@MainActor final class RecordDetailViewModel: ObservableObject {
    @Published private(set) var record: Record
    @Published var error: String?
    private let repo: RecordRepository
    private var subscription: AnyCancellable?
    init(record: Record, repo: RecordRepository) {
        self.record = record; self.repo = repo
        subscription = repo.recordsPublisher(petID: record.petID).receive(on: DispatchQueue.main)
            .sink { [weak self] records in
                if let latest = records.first(where: { $0.id == record.id }) { self?.record = latest }
            }
    }
    func delete() -> Bool {
        do { try repo.delete(id: record.id); return true }
        catch { self.error = "删除失败，原记录已保留，请重试。"; return false }
    }
}

struct RecordDetailView: View {
    @StateObject private var vm: RecordDetailViewModel
    @State private var showEdit = false
    @State private var showDelete = false
    @Environment(\.dismiss) private var dismiss

    init(record: Record) {
        _vm = StateObject(wrappedValue: RecordDetailViewModel(record: record, repo: CoreDataRecordRepository()))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("记录") {
                    LabeledContent("类型", value: vm.record.displayKind)
                    LabeledContent("时间", value: vm.record.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
                Section("内容") {
                    if vm.record.kind == .custom && vm.record.templateSnapshot == nil {
                        Text("这条历史记录未保存字段名称。以下保留原始答案。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(vm.record.fields, id: \.key) { field in
                        LabeledContent(field.title, value: displayValue(field))
                    }
                }
                Section("备注与心情") {
                    LabeledContent("备注", value: vm.record.note.isEmpty ? "—" : vm.record.note)
                    LabeledContent("心情", value: vm.record.mood.isEmpty ? "—" : vm.record.mood)
                }
                if !vm.record.photoFileNames.isEmpty {
                    Section("照片") {
                        ForEach(vm.record.photoFileNames, id: \.self) { file in
                            if let image = AvatarStore.load(fileName: file) {
                                Image(uiImage: image).resizable().scaledToFit()
                                    .accessibilityLabel("记录照片")
                            } else { Label("照片文件暂时无法读取", systemImage: "photo") }
                        }
                    }
                }
                Section {
                    Button("删除记录", role: .destructive) { showDelete = true }
                        .accessibilityIdentifier("record.delete")
                }
            }
            .accessibilityIdentifier("calendar.recordDetail")
            .navigationTitle("记录详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("record.detailDone")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("编辑") { showEdit = true }.accessibilityIdentifier("record.edit")
                }
            }
            .sheet(isPresented: $showEdit) {
                NavigationStack {
                    RecordEditorView(vm: RecordFormViewModel(repo: CoreDataRecordRepository(),
                        petID: vm.record.petID, kind: vm.record.kind, editing: vm.record)) { showEdit = false }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { showEdit = false }.accessibilityIdentifier("record.cancelEdit")
                        }
                    }
                }
            }
            .confirmationDialog("删除这条记录？", isPresented: $showDelete, titleVisibility: .visible) {
                Button("确认删除记录", role: .destructive) { if vm.delete() { dismiss() } }
            } message: { Text("记录及其照片将被删除，此操作无法撤销。") }
            .alert("操作失败", isPresented: Binding(get: { vm.error != nil }, set: { if !$0 { vm.error = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(vm.error ?? "请重试") }
        }
    }

    private func displayValue(_ field: TemplateField) -> String {
        let value = vm.record.answers[field.key] ?? ""
        if value.isEmpty { return "—" }
        if case .toggle = field.kind { return value == "true" ? "是" : "否" }
        return value
    }
}
