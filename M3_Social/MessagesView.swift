import SwiftUI

// MARK: - 消息占位页（「消息」tab）
// 用 Mock 数据做互动消息列表（点赞/评论通知样式）；不接真实逻辑，仅演示视觉与层级。

struct InteractionMessage: Identifiable {
    let id = UUID()
    let icon: String
    let actor: String
    let action: String
    let postExcerpt: String
    let time: String
    let unread: Bool
}

struct MessageListView: View {
    /// Mock 演示数据：点赞/评论/回应三类互动通知
    private let messages: [InteractionMessage] = [
        .init(icon: "heart.fill", actor: "宠友12", action: "赞了你的动态",
              postExcerpt: "今天带小白去跑了五公里，累趴了…",
              time: "5分钟前", unread: true),
        .init(icon: "bubble.right.fill", actor: "小明", action: "评论了你的动态",
              postExcerpt: "第 1 条动态",
              time: "1小时前", unread: true),
        .init(icon: "face.smiling.fill", actor: "阿花", action: "回应了你的动态",
              postExcerpt: "第 2 条动态",
              time: "3小时前", unread: false),
        .init(icon: "heart.fill", actor: "楼主", action: "赞了你的评论",
              postExcerpt: "「好可爱！」",
              time: "昨天", unread: false),
        .init(icon: "bubble.right.fill", actor: "宠友7", action: "回复了你的评论",
              postExcerpt: "「求同款粮」",
              time: "2天前", unread: false)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Spacing.md) {
                    demoBadge
                    VStack(spacing: DS.Spacing.sm) {
                        ForEach(Array(messages.enumerated()), id: \.offset) { index, message in
                            messageCard(message)
                                .accessibilityIdentifier("message.row.\(index)")
                        }
                    }
                }
                .padding(DS.Spacing.md)
                .frame(maxWidth: .infinity)
            }
            .background(Color.pageBackground)
            .navigationTitle("消息")
        }
    }

    /// 「演示数据」标注：占位页无真实后端，明示用户
    private var demoBadge: some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: "info.circle").font(.caption)
            Text("演示数据 · 互动通知功能开发中").font(.caption)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.xs)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("message.demoBadge")
    }

    /// 互动通知卡片：图标圆标 + actor/action（headline）+ 动态摘录（body）+ 时间（辅助）+ 未读点
    private func messageCard(_ message: InteractionMessage) -> some View {
        CardContainer {
            HStack(alignment: .top, spacing: DS.Spacing.sm) {
                Image(systemName: message.icon)
                    .font(.body)
                    .frame(width: 40, height: 40)
                    .background(Color.groupedBackground, in: Circle())
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Text("\(message.actor) \(message.action)")
                        .font(.headline)
                    Text(message.postExcerpt)
                        .font(.body).foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(message.time)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: DS.Spacing.sm)
                if message.unread {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 8, height: 8)
                        .padding(.top, DS.Spacing.xs)
                        .accessibilityLabel("未读")
                }
            }
        }
        // 行级元素不折叠，未读点/时间各自可聚焦
        .accessibilityElement(children: .contain)
    }
}
