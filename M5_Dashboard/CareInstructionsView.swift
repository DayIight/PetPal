import SwiftUI

struct CareInstructionsView: View {
    let pet: Pet
    private let repository = CareInstructionsRepository()
    @State private var instructions: CareInstructions
    @State private var loaded = false
    @State private var error: String?
    @State private var saved = false
    @State private var showExport = false
    @Environment(\.dismiss) private var dismiss
    init(pet: Pet) { self.pet = pet; _instructions = State(initialValue: CareInstructions(petID: pet.id)) }
    var body: some View {
        NavigationStack {
            Form {
                Section("照护安排 · \(pet.nickname)") {
                    Text("为临时照护者整理主人填写的安排，每项最多20,000字。")
                        .font(.footnote).foregroundStyle(.secondary)
                    field("饮食安排", text: $instructions.diet, id: "care.diet")
                    field("日常照护", text: $instructions.dailyCare, id: "care.daily")
                    field("注意事项", text: $instructions.notes, id: "care.notes")
                    field("紧急联系人", text: $instructions.emergencyContacts, id: "care.contacts")
                    if let validation = instructions.validationError { Text(validation).foregroundStyle(.red) }
                }
                Section {
                    Button("保存照护说明") { save() }.disabled(!loaded || instructions.validationError != nil).accessibilityIdentifier("care.save")
                    if saved { Text("已保存").foregroundStyle(.secondary) }
                    Button("保存并预览导出范围") { if save() { showExport = true } }.disabled(!loaded || instructions.validationError != nil).accessibilityIdentifier("care.export")
                    Text("分享前可以选择过敏信息、当前用药安排与兽医联系方式。交接卡仅属于这只宠物，不附带芯片号、其他病历或医疗原件。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("照护交接卡")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
            .onAppear {
                guard !loaded else { return }
                do { instructions = try repository.load(petID: pet.id) ?? CareInstructions(petID: pet.id); loaded = true }
                catch { self.error = error.localizedDescription }
            }
            .onChange(of: instructions) { _ in saved = false }
            .sheet(isPresented: $showExport) { CareCardExportView(pet: pet, instructions: instructions) }
            .alert("操作失败", isPresented: .init(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好", role: .cancel) {} } message: { Text(error ?? "请重试") }
        }
    }
    private func field(_ title: String, text: Binding<String>, id: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            TextField(title, text: text, axis: .vertical).lineLimit(3...8).accessibilityIdentifier(id)
        }
    }
    @discardableResult private func save() -> Bool {
        do { guard instructions.petID == pet.id else { throw CareItemError.wrongOwner }; try repository.save(instructions); saved = true; return true }
        catch { self.error = error.localizedDescription; return false }
    }
}

private struct CareCardExportView: View {
    let pet: Pet
    let instructions: CareInstructions
    @State private var options = CareCardOptions()
    @State private var medicationSchedules: [String] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var generating = false
    @State private var preview: PDFShareItem?
    @State private var exportedURL: URL?
    @Environment(\.dismiss) private var dismiss
    private var snapshot: CareCardSnapshot? { try? CareCardSnapshot(pet: pet, instructions: instructions, options: options, medicationSchedules: medicationSchedules) }
    var body: some View {
        NavigationStack {
            Form {
                Section("分享范围 · \(pet.nickname)") {
                    Toggle("过敏信息", isOn: $options.includeAllergies).accessibilityIdentifier("care.includeAllergies")
                    Toggle("进行中的用药安排", isOn: $options.includeMedication).accessibilityIdentifier("care.includeMedication")
                    Toggle("兽医联系方式", isOn: $options.includeVet).accessibilityIdentifier("care.includeVet")
                    Text("仅包含下方预览的资料。用药安排为主人填写的疗程，不提供诊断或处方建议。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let snapshot {
                    ForEach(snapshot.sections.indices, id: \.self) { index in
                        Section(snapshot.sections[index].title) { Text(snapshot.sections[index].text).textSelection(.enabled) }
                    }
                } else {
                    Section { Text("没有可导出的照护内容。请返回填写照护说明，或选择要分享的资料。").foregroundStyle(.secondary) }
                }
                Section {
                    Button(generating ? "正在生成…" : "生成 PDF 并预览") {
                        generating = true
                        Task { @MainActor in
                            await Task.yield()
                            do {
                                let current = try CareCardSnapshot(pet: pet, instructions: instructions, options: options, medicationSchedules: medicationSchedules)
                                let url = try CareCardPDFBuilder.makeDocument(snapshot: current)
                                exportedURL = url; preview = PDFShareItem(url: url)
                            } catch { self.error = error.localizedDescription }
                            generating = false
                        }
                    }.disabled(!loaded || generating || snapshot == nil).accessibilityIdentifier("care.generate")
                    Text("预览 PDF 后点击系统分享按钮，选择接收人。所有长文本将完整分页。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("预览交接卡范围")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(generating) } }
            .interactiveDismissDisabled(generating)
            .onAppear {
                do {
                    medicationSchedules = try CareItemStore().items(MedicationCourse.self, category: .medicationCourse, petID: pet.id).filter { $0.isActive() }.map(\.careCardSummary)
                    loaded = true
                } catch { self.error = error.localizedDescription }
            }
            .sheet(item: $preview, onDismiss: {
                if let url = exportedURL { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                exportedURL = nil
            }) { DocumentOriginalPreview(url: $0.url, title: "照护交接卡 · \(pet.nickname)") }
            .alert("导出失败", isPresented: .init(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好", role: .cancel) {} } message: { Text(error ?? "请重试") }
        }
    }
}
