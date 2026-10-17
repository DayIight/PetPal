import Foundation
import SwiftUI
import Combine

struct RecordSearchFilter: Equatable {
    var query = ""
    var kind: RecordKind?
    var startDate: Date?
    var endDate: Date?

    var isActive: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || kind != nil || startDate != nil || endDate != nil
    }
    func validationError(calendar: Calendar = .current) -> String? {
        if let startDate, let endDate, calendar.startOfDay(for: startDate) > calendar.startOfDay(for: endDate) {
            return "开始日期不能晚于结束日期"
        }
        return nil
    }
    mutating func reset() { self = Self() }

    func results(in records: [Record], petID: UUID, calendar: Calendar = .current) -> [Record] {
        guard validationError(calendar: calendar) == nil else { return [] }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = startDate.map { calendar.startOfDay(for: $0) }
        let upper = endDate.flatMap { calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0)) }
        return records.filter { record in
            guard record.petID == petID else { return false }
            if let kind, record.kind != kind { return false }
            if let lower, record.eventDate < lower { return false }
            if let upper, record.eventDate >= upper { return false }
            if term.isEmpty { return true }
            let searchable = [record.kind.rawValue, record.templateName ?? "", record.note] + Array(record.answers.values)
            return searchable.contains {
                $0.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) != nil
            }
        }.sorted {
            $0.eventDate == $1.eventDate ? $0.id.uuidString < $1.id.uuidString : $0.eventDate > $1.eventDate
        }
    }
}

struct RecordSearchControls: View {
    @Binding var filter: RecordSearchFilter
    @State private var expanded = false

    var body: some View {
        VStack(spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索类型、模板、内容或备注", text: $filter.query)
                    .submitLabel(.search)
                    .accessibilityIdentifier("records.search")
                Button { expanded.toggle() } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                    .a11y("筛选记录", hint: "选择记录类型和日期范围")
                    .accessibilityIdentifier("records.filter")
            }
            if expanded {
                Picker("记录类型", selection: $filter.kind) {
                    Text("全部类型").tag(RecordKind?.none)
                    ForEach(RecordKind.allCases) { Text($0.rawValue).tag(Optional($0)) }
                }
                .accessibilityIdentifier("records.filter.kind")
                Toggle("限定日期范围", isOn: Binding(
                    get: { filter.startDate != nil || filter.endDate != nil },
                    set: { enabled in
                        filter.startDate = enabled ? Calendar.current.startOfDay(for: Date()) : nil
                        filter.endDate = enabled ? Calendar.current.startOfDay(for: Date()) : nil
                    }))
                    .accessibilityIdentifier("records.filter.dates")
                if filter.startDate != nil || filter.endDate != nil {
                    DatePicker("开始日期", selection: Binding(get: { filter.startDate ?? Date() }, set: { filter.startDate = $0 }), displayedComponents: .date)
                        .accessibilityIdentifier("records.filter.start")
                    DatePicker("结束日期", selection: Binding(get: { filter.endDate ?? Date() }, set: { filter.endDate = $0 }), displayedComponents: .date)
                        .accessibilityIdentifier("records.filter.end")
                    Text("包含开始与结束日期的全天记录").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = filter.validationError() {
                Text(error).font(.footnote).foregroundStyle(.red)
                    .accessibilityIdentifier("records.filter.error")
            }
            if filter.isActive {
                Button("清除搜索与筛选") { filter.reset() }
                    .accessibilityIdentifier("records.filter.reset")
            }
        }
        .padding(DS.Spacing.sm)
        .background(Color.groupedBackground, in: RoundedRectangle(cornerRadius: DS.Radius.control))
        .padding(.horizontal, DS.Spacing.md)
        .padding(.top, DS.Spacing.sm)
    }
}

@MainActor private final class RecordSearchViewModel: ObservableObject {
    @Published var records: [Record] = []
    private let repository: RecordRepository
    init(repository: RecordRepository, petID: UUID) {
        self.repository = repository
        repository.recordsPublisher(petID: petID).receive(on: DispatchQueue.main).assign(to: &$records)
    }
}

struct FilteredRecordsView: View {
    let pet: Pet
    let filter: RecordSearchFilter
    @StateObject private var vm: RecordSearchViewModel
    @State private var detail: Record?

    init(pet: Pet, filter: RecordSearchFilter) {
        self.pet = pet; self.filter = filter
        _vm = StateObject(wrappedValue: RecordSearchViewModel(repository: CoreDataRecordRepository(), petID: pet.id))
    }

    var body: some View {
        let results = filter.results(in: vm.records, petID: pet.id)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.Spacing.sm) {
                if filter.validationError() == nil {
                    Text("\(results.count)条结果 · \(pet.nickname)").font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("records.search.count")
                }
                if results.isEmpty {
                    VStack(spacing: DS.Spacing.md) {
                        Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                        Text(filter.validationError() == nil ? "没有符合条件的记录" : "请调整日期范围")
                            .font(.headline)
                        Text("可修改搜索词、类型或日期，或清除筛选。")
                            .font(.body).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(DS.Spacing.xl)
                    .accessibilityIdentifier("records.search.empty")
                }
                ForEach(results) { record in
                    Button { detail = record } label: {
                        CardContainer {
                            HStack(spacing: DS.Spacing.sm) {
                                Image(systemName: record.kind.symbolName).foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                                    Text(record.displayKind).font(.headline)
                                    if !record.summary.isEmpty { Text(record.summary).font(.body).foregroundStyle(.secondary).lineLimit(2) }
                                    if !record.note.isEmpty { Text(record.note).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                    Text(record.eventDate.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("records.row.\(record.id.uuidString)")
                }
            }
            .padding(DS.Spacing.md)
        }
        .sheet(item: $detail) { RecordDetailView(record: $0) }
    }
}
