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
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1,
                                             to: Calendar.current.startOfDay(for: now)) ?? now
        completion(Timeline(entries: [makeEntry(now: now)], policy: .after(tomorrow)))
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

// MARK: - 视图（iOS 16 无 containerBackground，保持系统默认底色；颜色用语义色自动适配深色模式）
struct PetPalReminderWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PetPalReminderEntry

    var body: some View {
        if let pet = entry.pet {
            switch family {
            case .systemMedium: mediumBody(pet: pet)
            default: smallBody(pet: pet)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "pawprint.fill")
                    .font(.title2).foregroundStyle(.secondary)
                Text("打开 PetPal 建立宠物档案")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("PetPal，尚未建立宠物档案")
        }
    }

    private var petURL: URL? {
        entry.pet.map { URL(string: "petpal://pet/\($0.id.uuidString)")! }
    }

    private func avatar(pet: WidgetSnapshot.PetEntry, size: CGFloat) -> some View {
        let image = pet.avatarFileName
            .flatMap { UIImage(contentsOfFile: WidgetSnapshotStore.avatarURL(fileName: $0, in: entry.directory).path) }
        return Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "pawprint.fill")
                    .resizable().scaledToFit().padding(size * 0.22)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .background(Circle().fill(Color(.secondarySystemBackground)))
        .accessibilityHidden(true)
    }

    private func timeText(_ r: WidgetSnapshot.ReminderEntry) -> String {
        String(format: "%02d:%02d %@", r.hour, r.minute, r.type)
    }

    private func smallBody(pet: WidgetSnapshot.PetEntry) -> some View {
        VStack(spacing: 6) {
            avatar(pet: pet, size: 52)
            Text(pet.nickname).font(.headline).lineLimit(1)
            if let next = entry.remaining.first {
                Text(timeText(next)).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("今日提醒已完成").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetURL(petURL)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(pet.nickname)，\(entry.remaining.first.map { "下一项提醒 \(timeText($0))" } ?? "今日提醒已完成")")
    }

    private func mediumBody(pet: WidgetSnapshot.PetEntry) -> some View {
        HStack(spacing: 12) {
            VStack(spacing: 6) {
                avatar(pet: pet, size: 56)
                Text(pet.nickname).font(.headline).lineLimit(1)
            }
            Divider()
            if entry.remaining.isEmpty {
                Text("今日提醒已完成").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(entry.remaining.prefix(3)) { r in
                        Link(destination: petURL!) {
                            Text(timeText(r))
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if entry.remaining.count > 3 {
                        Text("还有 \(entry.remaining.count - 3) 项")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
