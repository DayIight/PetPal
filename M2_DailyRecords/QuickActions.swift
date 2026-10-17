import Foundation
import SwiftUI

/// A favorite stores reusable content, never a record's event identity or media.
struct QuickAction: Identifiable, Equatable, Codable {
    var id = UUID()
    var petID: UUID
    var name: String
    var kindRawValue: String
    var answers: [String: String]
    var note: String
    var mood: String
    var templateName: String?
    var templateID: UUID?
    var templateSnapshot: CustomTemplate?
    var templateSchemaVersion: Int

    var kind: RecordKind? { RecordKind(rawValue: kindRawValue) }
    var validationError: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 30 { return "快捷名称需为1–30个字" }
        guard let kind else { return "快捷记录类型无效" }
        if note.count > 200 || mood.count > 10 { return "快捷内容超过长度限制" }
        if kind == .custom {
            guard let template = templateSnapshot, template.id == templateID,
                  templateName == template.name, !template.fields.isEmpty,
                  templateSchemaVersion == 1 else { return "自定义快捷模板不完整" }
        } else if templateSnapshot != nil || templateID != nil || templateName != nil || templateSchemaVersion != 0 {
            return "快捷模板与记录类型不一致"
        }
        return nil
    }

    init(name: String, record: Record) {
        petID = record.petID; self.name = name
        kindRawValue = record.kind.rawValue
        note = record.note; mood = record.mood
        templateName = record.templateName; templateID = record.templateID
        templateSnapshot = record.templateSnapshot; templateSchemaVersion = record.templateSchemaVersion
        answers = Self.reusableAnswers(record.answers, fields: record.templateSnapshot?.templateFields ?? record.kind.fields)
    }

    func makeDraft(petID: UUID, now: Date = Date()) throws -> Record {
        guard petID == self.petID else { throw CareItemError.wrongOwner }
        if let validationError { throw QuickActionError.invalid(validationError) }
        guard let kind else { throw CareItemError.invalidPayload }
        return Record(petID: petID, kind: kind,
            answers: Self.reusableAnswers(answers, fields: templateSnapshot?.templateFields ?? kind.fields),
            note: note, mood: mood, templateName: templateName, templateID: templateID,
            templateSnapshot: templateSnapshot, templateSchemaVersion: templateSchemaVersion,
            createdAt: now, occurredAt: now)
    }

    private static func reusableAnswers(_ answers: [String: String], fields: [TemplateField]) -> [String: String] {
        let allowedKeys = Set(fields.compactMap { field -> String? in
            if case .date = field.kind { return nil }
            return field.key
        })
        return answers.filter { allowedKeys.contains($0.key) }
    }
}

enum QuickActionError: LocalizedError {
    case limitExceeded, invalid(String)
    var errorDescription: String? {
        switch self {
        case .limitExceeded: return "每只宠物最多保存6个常用快捷，请先删除一个。"
        case .invalid(let message): return message
        }
    }
}

final class QuickActionRepository {
    static let maximumCount = 6
    private let store: CareItemStore
    init(store: CareItemStore = CareItemStore()) { self.store = store }

    func actions(petID: UUID) throws -> [QuickAction] {
        let actions = try store.items(QuickAction.self, category: .quickAction, petID: petID)
        guard actions.allSatisfy({ $0.validationError == nil }) else { throw CareItemError.invalidPayload }
        return actions
    }
    func save(_ action: QuickAction) throws {
        if let error = action.validationError { throw QuickActionError.invalid(error) }
        let existing = try actions(petID: action.petID)
        if !existing.contains(where: { $0.id == action.id }), existing.count >= Self.maximumCount {
            throw QuickActionError.limitExceeded
        }
        try store.upsert(action, id: action.id, petID: action.petID, category: .quickAction)
    }
    func delete(id: UUID, petID: UUID) throws {
        guard try actions(petID: petID).contains(where: { $0.id == id }) else { throw CareItemError.wrongOwner }
        try store.delete(id: id)
    }
}

struct QuickActionsSection: View {
    let pet: Pet
    let onManage: () -> Void
    let onSelect: (Record) -> Void
    @State private var actions: [QuickAction] = []
    @State private var error: String?
    private let repository = QuickActionRepository()

    var body: some View {
        Section("常用快捷") {
            ForEach(actions) { action in
                Button {
                    do { onSelect(try action.makeDraft(petID: pet.id)) }
                    catch { self.error = error.localizedDescription }
                } label: {
                    Label(action.name, systemImage: action.kind?.symbolName ?? "note.text")
                }
                .accessibilityIdentifier("today.quick.\(action.id.uuidString)")
                .a11y(action.name, hint: "预填记录，核对后点保存")
            }
            if actions.isEmpty {
                Text("添加常用记录，填好后核对保存。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button("管理常用快捷", action: onManage)
                .accessibilityIdentifier("today.manageQuickActions")
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .onAppear(perform: load)
        .onReceive(NotificationCenter.default.publisher(for: .careItemsDidChange)) { _ in load() }
    }
    private func load() {
        do { actions = try repository.actions(petID: pet.id); error = nil }
        catch { actions = []; self.error = "快捷加载失败：\(error.localizedDescription)" }
    }
}

struct QuickActionManagementView: View {
    let pet: Pet
    @State private var actions: [QuickAction] = []
    @State private var records: [Record] = []
    @State private var editing: QuickAction?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private let repository = QuickActionRepository()

    var body: some View {
        NavigationStack {
            List {
                Section("\(pet.nickname)的常用快捷（\(actions.count)/6）") {
                    ForEach(actions) { action in
                        Button { editing = action } label: {
                            HStack {
                                Label(action.name, systemImage: action.kind?.symbolName ?? "note.text")
                                Spacer()
                                Text("编辑").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("quickActions.edit.\(action.id.uuidString)")
                    }
                    .onDelete(perform: delete)
                    if actions.isEmpty { Text("还没有常用快捷").foregroundStyle(.secondary) }
                }
                Section("添加记录类型") {
                    ForEach(RecordKind.presetCases) { kind in
                        Button {
                            let recent = records.first(where: { $0.kind == kind }) ?? Record(petID: pet.id, kind: kind)
                            editing = QuickAction(name: kind.rawValue, record: recent)
                        } label: { Label(kind.rawValue, systemImage: kind.symbolName) }
                        .disabled(actions.count >= QuickActionRepository.maximumCount)
                        .accessibilityIdentifier("quickActions.add.\(kind.rawValue)")
                    }
                }
                if !records.isEmpty {
                    Section("将已保存的记录设为常用") {
                        ForEach(records) { record in
                            Button {
                                editing = QuickAction(name: String(record.displayKind.prefix(30)), record: record)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(record.displayKind)
                                    Text(record.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    Text(record.eventDate.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .disabled(actions.count >= QuickActionRepository.maximumCount)
                            .accessibilityIdentifier("quickActions.favorite.\(record.id.uuidString)")
                        }
                    }
                }
                Section {
                    Text("最多6项。快捷项保留设定时的常用内容，照片、任务完成状态和日期计划会清除；每次打开后仍需核对并保存。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let error { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("常用快捷")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear(perform: load)
            .sheet(item: $editing, onDismiss: load) { QuickActionEditor(action: $0, records: records, repository: repository) }
        }
    }
    private func load() {
        do {
            actions = try repository.actions(petID: pet.id)
            records = try CoreDataRecordRepository().records(petID: pet.id).sorted { $0.eventDate > $1.eventDate }
            error = nil
        } catch { self.error = "加载失败：\(error.localizedDescription)" }
    }
    private func delete(at offsets: IndexSet) {
        do {
            for index in offsets { try repository.delete(id: actions[index].id, petID: pet.id) }
            load()
        } catch { self.error = "删除失败：\(error.localizedDescription)" }
    }
}

private struct QuickActionEditor: View {
    @State var action: QuickAction
    let records: [Record]
    let repository: QuickActionRepository
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("快捷名称") {
                    TextField("例如：早餐", text: $action.name).accessibilityIdentifier("quickActions.name")
                }
                Section("常用填写内容") {
                    Text(action.templateName ?? action.kindRawValue)
                    ForEach((action.templateSnapshot?.templateFields ?? action.kind?.fields ?? []).filter {
                        if case .date = $0.kind { return false }; return true
                    }, id: \.key) { field in
                        TextField(field.title, text: Binding(get: { action.answers[field.key] ?? "" }, set: { action.answers[field.key] = $0 }))
                            .accessibilityIdentifier("quickActions.field.\(field.key)")
                    }
                    TextField("备注", text: $action.note)
                    if let latest = records.first(where: { $0.kind == action.kind && $0.templateID == action.templateID }) {
                        Button("用最近同类记录重设内容") {
                            let replacement = QuickAction(name: action.name, record: latest)
                            let id = action.id; action = replacement; action.id = id
                        }
                    }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .navigationTitle("设置常用快捷")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存快捷") {
                        action.name = action.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        do { try repository.save(action); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                    .accessibilityIdentifier("quickActions.save")
                }
            }
        }
    }
}
