import WidgetKit
import SwiftUI
import AppIntents

// MARK: - 时间线条目
struct PetPalReminderEntry: TimelineEntry {
    let date: Date
    let page: WidgetPetPage?                // nil = 无快照/无宠物 → 引导态
    let remaining: [WidgetSnapshot.ReminderEntry]   // 今日未过提醒，升序
    let directory: URL                      // 快照所在容器（头像按文件名从这里取）
    var pet: WidgetSnapshot.PetEntry? { page?.pet }
}

// MARK: - Provider：读 App Group 快照；日更时间线 + App 侧 reloadAllTimelines 兜底
struct PetPalReminderProvider: TimelineProvider {
    func placeholder(in context: Context) -> PetPalReminderEntry {
        let pet = WidgetSnapshot.PetEntry(id: UUID(), nickname: "小白", species: "狗")
        let other = WidgetSnapshot.PetEntry(id: UUID(), nickname: "豆豆", species: "猫")
        let snapshot = WidgetSnapshot(generatedAt: Date(), currentPetID: pet.id,
                                      pets: [pet, other], reminders: [])
        return PetPalReminderEntry(date: Date(), page: WidgetPetPage.resolve(in: snapshot, selectedPetID: nil),
                                   remaining: [.init(id: UUID(), petID: pet.id, petName: pet.nickname,
                                                     type: "喂食", hour: 8, minute: 0)],
                                   directory: WidgetSnapshotStore.sharedDirectory)
    }
    func getSnapshot(in context: Context, completion: @escaping (PetPalReminderEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : makeEntry())
    }
    func getTimeline(in context: Context,
                     completion: @escaping (Timeline<PetPalReminderEntry>) -> Void) {
        let now = Date()
        let directory = WidgetSnapshotStore.sharedDirectory
        guard let snapshot = WidgetSnapshotStore.read(from: directory) else {
            completion(Timeline(entries: [makeEntry(now: now)], policy: .after(now.addingTimeInterval(3600))))
            return
        }
        let page = selectedPage(in: snapshot, directory: directory)
        let entries = WidgetSnapshotQueries.timelineDates(in: snapshot, petID: page?.pet.id, now: now).map { date in
            PetPalReminderEntry(date: date, page: page,
                                remaining: WidgetSnapshotQueries.remainingReminders(in: snapshot, petID: page?.pet.id, now: date), directory: directory)
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private func makeEntry(now: Date = Date()) -> PetPalReminderEntry {
        let directory = WidgetSnapshotStore.sharedDirectory
        guard let snapshot = WidgetSnapshotStore.read(from: directory) else {
            return PetPalReminderEntry(date: now, page: nil, remaining: [], directory: directory)
        }
        let page = selectedPage(in: snapshot, directory: directory)
        return PetPalReminderEntry(
            date: now, page: page,
            remaining: WidgetSnapshotQueries.remainingReminders(in: snapshot, petID: page?.pet.id, now: now),
            directory: directory)
    }

    private func selectedPage(in snapshot: WidgetSnapshot, directory: URL) -> WidgetPetPage? {
        // iOS 16 保持随 App 当前宠物展示；iOS 17 起才使用可交互的页面选择。
        let selectedID: UUID?
        if #available(iOS 17.0, *) { selectedID = WidgetPetPageStore.selectedPetID(from: directory) }
        else { selectedID = nil }
        return WidgetPetPage.resolve(in: snapshot, selectedPetID: selectedID)
    }
}

// MARK: - 视图（每只宠物一页；iOS 17 使用 App Intent 按钮翻页）
struct PetPalReminderWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PetPalReminderEntry

    /// 主题色淡渐变底：浅色下柔和、深色下自动压暗，提醒内容保持可读
    private var background: some View {
        LinearGradient(colors: [Color.accentColor.opacity(0.16), Color.accentColor.opacity(0.04)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        Group {
            if #available(iOS 17.0, *) {
                content.id(entry.pet?.id)
                    .transition(.identity)
                    .animation(nil, value: entry.pet?.id)
                    .invalidatableContent()
                    .containerBackground(for: .widget) { background }
            } else {
                ZStack { background; content }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetURL(recordsURL ?? URL(string: "petpal://")!)
    }

    @ViewBuilder private var content: some View {
        if let pet = entry.pet {
            switch family {
            case .systemMedium: mediumBody(pet: pet)
            default: smallBody(pet: pet)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "pawprint.circle.fill")
                    .font(.system(size: 34))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                Text("打开 PetPal 建立宠物档案")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("PetPal，尚未建立宠物档案")
        }
    }

    private var showsPaging: Bool {
        if #available(iOS 17.0, *) { return (entry.page?.count ?? 0) > 1 }
        return false
    }

    @ViewBuilder private var pageControls: some View {
        if #available(iOS 17.0, *), let page = entry.page,
           let previous = page.previousPetID, let next = page.nextPetID {
            HStack(spacing: 0) {
                pageButton(petID: previous, isPrevious: true, symbol: "chevron.left", label: "上一只宠物")
                Text("\(page.index + 1) / \(page.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("第 \(page.index + 1) 页，共 \(page.count) 只宠物")
                pageButton(petID: next, isPrevious: false, symbol: "chevron.right", label: "下一只宠物")
            }
        }
    }

    @available(iOS 17.0, *)
    private func pageButton(petID: UUID, isPrevious: Bool, symbol: String, label: String) -> some View {
        Button(intent: SelectWidgetPetIntent(petID: petID, isPrevious: isPrevious)) {
            Image(systemName: symbol)
                .font(.caption.bold())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .accessibilityLabel(label)
    }

    private var recordsURL: URL? {
        entry.pet.map { URL(string: "petpal://records/\($0.id.uuidString)")! }
    }

    /// 提醒类型 → SF Symbol（与 App 内 M2/M4 同一套图标语义）
    private func icon(for type: String) -> String {
        switch type {
        case "喂食": return "fork.knife"
        case "疫苗": return "syringe.fill"
        case "驱虫": return "pill.fill"
        case "体检": return "stethoscope"
        case "服药": return "pills.fill"
        default: return "bell.fill"
        }
    }

    private func avatar(pet: WidgetSnapshot.PetEntry, size: CGFloat) -> some View {
        let image = pet.avatarFileName
            .flatMap { UIImage(contentsOfFile: WidgetSnapshotStore.avatarURL(fileName: $0, in: entry.directory).path) }
        return Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "pawprint.fill")
                    .resizable().scaledToFit().padding(size * 0.24)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(width: size, height: size)
        .background(Circle().fill(Color(.systemBackground)))
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 2))
        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        .accessibilityHidden(true)
    }

    private func timeText(_ r: WidgetSnapshot.ReminderEntry) -> String {
        String(format: "%02d:%02d %@", r.hour, r.minute, r.type)
    }

    /// 下一项提醒胶囊：图标 + 时间类型，主题色浅底
    private func reminderPill(_ r: WidgetSnapshot.ReminderEntry) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon(for: r.type))
            Text(timeText(r)).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
    }

    private var doneMark: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
            Text("今日暂无待提醒")
        }
        .font(.caption)
        .foregroundStyle(.green)
    }

    private func smallBody(pet: WidgetSnapshot.PetEntry) -> some View {
        VStack(spacing: showsPaging ? 2 : 8) {
            VStack(spacing: 6) {
                avatar(pet: pet, size: showsPaging ? 40 : 56)
                Text(pet.nickname).font(.headline).lineLimit(1)
                if let next = entry.remaining.first {
                    reminderPill(next)
                } else {
                    doneMark
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(pet.nickname)，\(entry.remaining.first.map { "下一项提醒 \(timeText($0))" } ?? "今日暂无待提醒")")
            pageControls
        }
        .padding(12)
    }

    /// 提醒行：类型图标圆点 + 等宽时间 + 类型；下一项高亮
    private func reminderRow(_ r: WidgetSnapshot.ReminderEntry, isNext: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(for: r.type))
                .font(.caption)
                .frame(width: 22, height: 22)
                .background(Circle().fill(isNext ? Color.accentColor : Color.accentColor.opacity(0.15)))
                .foregroundStyle(isNext ? Color.white : Color.accentColor)
            Text(String(format: "%02d:%02d", r.hour, r.minute))
                .font(.callout.bold().monospacedDigit())
            Text(r.type)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, showsPaging ? 3 : 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(isNext ? 0.12 : 0))
        )
    }

    private func mediumBody(pet: WidgetSnapshot.PetEntry) -> some View {
        HStack(spacing: 12) {
            VStack(spacing: 6) {
                avatar(pet: pet, size: showsPaging ? 48 : 60)
                Text(pet.nickname).font(.headline).lineLimit(1)
                pageControls
            }
            .frame(width: showsPaging ? 118 : 90)
            Divider()
            if entry.remaining.isEmpty {
                doneMark
                    .font(.callout)
                    .frame(maxWidth: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(entry.remaining.prefix(3).enumerated()), id: \.element.occurrenceKey) { i, r in
                        Link(destination: recordsURL!) {
                            reminderRow(r, isNext: i == 0)
                        }
                        .accessibilityHint("打开\(pet.nickname)的记录页")
                    }
                    if entry.remaining.count > 3 {
                        Text("还有 \(entry.remaining.count - 3) 项")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.leading, 30)
                    }
                }
            }
        }
        .padding(12)
    }
}

// MARK: - Widget 声明
struct PetPalReminderWidget: Widget {
    let kind = WidgetPetPageStore.widgetKind
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PetPalReminderProvider()) { entry in
            PetPalReminderWidgetView(entry: entry)
        }
        .configurationDisplayName("今日提醒")
        .description("每只宠物一页，查看今日提醒；iOS 17 起可点击箭头切换宠物。")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

@main
struct PetPalWidgetBundle: WidgetBundle {
    var body: some Widget { PetPalReminderWidget() }
}
