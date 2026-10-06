import SwiftUI

// MARK: - 消息页（「消息」tab）
// Mock 演示数据，但与信息流种子动态/评论真实关联（同一 MockSocialRepository 实例）：
// 点击消息跳转对应动态的评论区；评论类消息携带 commentID，落位并高亮该评论。

/// 消息类型 → 图标/动作文案（提成内部枚举：R-03 单测覆盖全分支）
enum MessageKindStyle {
    static func iconName(_ kind: InteractionMessage.Kind) -> String {
        switch kind {
        case .likePost, .likeComment: return "heart.fill"
        case .commentPost, .replyComment: return "bubble.right.fill"
        case .reactPost: return "face.smiling.fill"
        }
    }

    static func actionText(_ kind: InteractionMessage.Kind) -> String {
        switch kind {
        case .likePost: return "赞了你的动态"
        case .commentPost: return "评论了你的动态"
        case .reactPost: return "回应了你的动态"
        case .likeComment: return "赞了你的评论"
        case .replyComment: return "回复了你的评论"
        }
    }
}

struct MessageListView: View {
    let repo: SocialRepository
    let messages: [InteractionMessage]

    init(repo: SocialRepository, messages: [InteractionMessage]) {
        self.repo = repo
        self.messages = messages
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Spacing.md) {
                    demoBadge
                    VStack(spacing: DS.Spacing.sm) {
                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            NavigationLink {
                                CommentListView(post: message.post, repo: repo,
                                                highlightCommentID: message.commentID)
                            } label: {
                                messageCard(message)
                            }
                            .buttonStyle(.plain)
                            .a11y("\(message.actor)\(actionText(message.kind))，\(message.excerpt)",
                                  hint: "点击查看对应\(message.commentID == nil ? "动态" : "评论")")
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

    /// 「演示数据」标注：消息为 Mock 种子数据，明示用户
    private var demoBadge: some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: "info.circle").font(.caption)
            Text("演示数据 · 点击可跳转对应动态或评论").font(.caption)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.xs)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("message.demoBadge")
    }

    private func iconName(_ kind: InteractionMessage.Kind) -> String {
        MessageKindStyle.iconName(kind)
    }

    private func actionText(_ kind: InteractionMessage.Kind) -> String {
        MessageKindStyle.actionText(kind)
    }

    /// 互动通知卡片：图标圆标 + actor/action（headline）+ 摘录（body）+ 时间（辅助）+ 未读点
    private func messageCard(_ message: InteractionMessage) -> some View {
        CardContainer {
            HStack(alignment: .top, spacing: DS.Spacing.sm) {
                Image(systemName: iconName(message.kind))
                    .font(.body)
                    .frame(width: 40, height: 40)
                    .background(Color.groupedBackground, in: Circle())
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Text("\(message.actor) \(actionText(message.kind))")
                        .font(.headline)
                    Text(message.excerpt)
                        .font(.body).foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(feedTime(message.createdAt))
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
