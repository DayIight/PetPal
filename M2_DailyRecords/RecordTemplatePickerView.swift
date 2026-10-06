import SwiftUI

// MARK: - 记录模板选择（预设 7 类图标网格 + 已有自定义模板 + 模板管理入口）
struct RecordTemplatePickerView: View {
    let pet: Pet?
    @State private var templates: [CustomTemplate] = []
    @State private var showTemplates = false
    @State private var dismissAll = false
    private let templateRepo = CoreDataCustomTemplateRepository()
    @Environment(\.dismiss) private var dismiss

    /// sheet 内导航目标（RecordKind 与 CustomTemplate 均不适合直接做 path 元素）
    private enum Destination: Hashable {
        case preset(RecordKind)
        case custom(UUID)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    if pet == nil {
                        Text("请先创建宠物档案（「我的」tab），再记日常")
                            .font(.body).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("record.noPet")
                    }
                    Text("预设记录").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: DS.Spacing.sm)],
                              spacing: DS.Spacing.sm) {
                        ForEach(RecordKind.presetCases) { kind in
                            NavigationLink(value: Destination.preset(kind)) {
                                VStack(spacing: DS.Spacing.sm) {
                                    Image(systemName: kind.symbolName)
                                        .font(.title3)
                                        .frame(width: 48, height: 48)
                                        .background(Color.groupedBackground,
                                                    in: RoundedRectangle(cornerRadius: DS.Radius.control,
                                                                         style: .continuous))
                                        .foregroundStyle(Color.accentColor)
                                    Text(kind.rawValue).font(.caption)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, DS.Spacing.sm)
                            }
                            .a11y(kind.rawValue, hint: "为\(pet?.nickname ?? "当前宠物")记一条\(kind.rawValue)")
                            .accessibilityIdentifier("record.template.\(kind.rawValue)")
                            .disabled(pet == nil)
                            .opacity(pet == nil ? 0.5 : 1)
                        }
                    }
                    if !templates.isEmpty {
                        Text("自定义模板").font(.headline)
                        VStack(spacing: DS.Spacing.sm) {
                            ForEach(templates) { template in
                                NavigationLink(value: Destination.custom(template.id)) {
                                    HStack(spacing: DS.Spacing.sm) {
                                        Image(systemName: "rectangle.stack")
                                            .foregroundStyle(Color.accentColor)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(template.name).font(.body)
                                            Text("\(template.fields.count) 个字段")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    .padding(DS.Spacing.sm)
                                    .background(Color.groupedBackground,
                                                in: RoundedRectangle(cornerRadius: DS.Radius.control,
                                                                     style: .continuous))
                                }
                                .a11y("记\(template.name)", hint: "按模板为\(pet?.nickname ?? "当前宠物")创建记录")
                                .accessibilityIdentifier("record.template.custom.\(template.name)")
                                .disabled(pet == nil)
                                .opacity(pet == nil ? 0.5 : 1)
                            }
                        }
                    }
                    Button("管理自定义模板") { showTemplates = true }
                        .font(.callout)
                        .a11y("管理自定义模板", hint: "新建或编辑自定义记录模板")
                        .accessibilityIdentifier("record.template.manage")
                        .padding(.top, DS.Spacing.xs)
                }
                .padding(DS.Spacing.md)
            }
            .background(Color.pageBackground)
            .navigationTitle("记一条日常")
            .navigationBarTitleDisplayMode(.inline)
            .presentationDetents([.medium, .large])
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .preset(let kind):
                    if let pet {
                        PresetRecordFormView(petID: pet.id, kind: kind) { dismiss() }
                    }
                case .custom(let templateID):
                    if let pet, let template = templates.first(where: { $0.id == templateID }) {
                        CustomRecordFormView(template: template, petID: pet.id)
                    }
                }
            }
            .sheet(isPresented: $showTemplates) { TemplateListView() }
            .onAppear { templates = (try? templateRepo.all()) ?? [] }
        }
    }
}
