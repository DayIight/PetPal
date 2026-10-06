import WidgetKit
import SwiftUI

// MARK: - 时间线条目
struct PetPalReminderEntry: TimelineEntry {
    let date: Date
    let pet: WidgetSnapshot.PetEntry?       // nil = 无快照/无宠物 → 引导态
    let remaining: [WidgetSnapshot.ReminderEntry]   // 今日未过提醒，升序
    let directory: URL                      // 快照所在容器（头像按文件名从这里取）
}

// MARK: - Provider：读 App Group 快照；日更时间线 + App 侧 reloadAllTimelines 兜底
struct PetPalReminderProvider: TimelineProvider {
    func placeholder(in context: Context) -> PetPalReminderEntry {
        PetPalReminderEntry(date: Date(),
                            pet: .init(id: UUID(), nickname: "小白", species: "狗",
                                       avatarFileName: nil),
                            remaining: [.init(id: UUID(), petID: UUID(), petName: "小白",
                                              type: "喂食", hour: 8, minute: 0)],
                            directory: WidgetSnapshotStore.sharedDirectory)
    }
    func getSnapshot(in context: Context, completion: @escaping (PetPalReminderEntry) -> Void) {
        completion(makeEntry())
    }
    func getTimeline(in context: Context,
                     completion: @escaping (Timeline<PetPalReminderEntry>) -> Void) {
        let now = Date()
        let directory = WidgetSnapshotStore.sharedDirectory
        guard let snapshot = WidgetSnapshotStore.read(from: directory) else {
            completion(Timeline(entries: [makeEntry(now: now)], policy: .after(now.addingTimeInterval(3600))))
            return
        }
        let entries = WidgetSnapshotQueries.timelineDates(in: snapshot, now: now).map { date in
            PetPalReminderEntry(date: date, pet: WidgetSnapshotQueries.currentPet(in: snapshot),
                                remaining: WidgetSnapshotQueries.remainingReminders(in: snapshot, now: date), directory: directory)
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private func makeEntry(now: Date = Date()) -> PetPalReminderEntry {
        let directory = WidgetSnapshotStore.sharedDirectory
        guard let snapshot = WidgetSnapshotStore.read(from: directory) else {
            return PetPalReminderEntry(date: now, pet: nil, remaining: [], directory: directory)
        }
        return PetPalReminderEntry(
            date: now,
            pet: WidgetSnapshotQueries.currentPet(in: snapshot),
            remaining: WidgetSnapshotQueries.remainingReminders(in: snapshot, now: now),
            directory: directory)
    }
}

// MARK: - 视图（iOS 16 无 containerBackground，用 ZStack 铺渐变底；语义色自动适配深色模式）
struct PetPalReminderWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PetPalReminderEntry

    /// 主题色淡渐变底：浅色下柔和、深色下自动压暗，提醒内容保持可读
    private var background: some View {
        LinearGradient(colors: [Color.accentColor.opacity(0.16), Color.accentColor.opacity(0.04)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        ZStack {
            background
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
                .accessibilityElement(children: .combine)
                .accessibilityLabel("PetPal，尚未建立宠物档案")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var petURL: URL? {
        entry.pet.map { URL(string: "petpal://pet/\($0.id.uuidString)")! }
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
        VStack(spacing: 8) {
            avatar(pet: pet, size: 56)
            Text(pet.nickname).font(.headline).lineLimit(1)
            if let next = entry.remaining.first {
                reminderPill(next)
            } else {
                doneMark
            }
        }
        .widgetURL(petURL)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(pet.nickname)，\(entry.remaining.first.map { "下一项提醒 \(timeText($0))" } ?? "今日暂无待提醒")")
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
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(isNext ? 0.12 : 0))
        )
    }

    private func mediumBody(pet: WidgetSnapshot.PetEntry) -> some View {
        HStack(spacing: 12) {
            VStack(spacing: 6) {
                avatar(pet: pet, size: 60)
                Text(pet.nickname).font(.headline).lineLimit(1)
            }
            Divider()
            if entry.remaining.isEmpty {
                doneMark
                    .font(.callout)
                    .frame(maxWidth: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(entry.remaining.prefix(3).enumerated()), id: \.element.occurrenceKey) { i, r in
                        Link(destination: petURL!) {
                            reminderRow(r, isNext: i == 0)
                        }
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
        .accessibilityLabel("\(pet.nickname)，今日剩余 \(entry.remaining.count) 项提醒")
    }
}

// MARK: - Widget 声明
struct PetPalReminderWidget: Widget {
    let kind = "PetPalReminderWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PetPalReminderProvider()) { entry in
            PetPalReminderWidgetView(entry: entry)
        }
        .configurationDisplayName("今日提醒")
        .description("查看当前宠物今日的喂食、服药等待办提醒。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct PetPalWidgetBundle: WidgetBundle {
    var body: some Widget { PetPalReminderWidget() }
}
