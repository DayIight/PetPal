import SwiftUI
import Combine

// MARK: - 评论页 ViewModel（一级列表 + 二级缩进；两级树，二级不可再回复）
@MainActor final class CommentListViewModel: ObservableObject {
    @Published private(set) var tops: [Comment] = []
    @Published private(set) var children: [UUID: [Comment]] = [:]
    @Published var draft = ""
    @Published var replyTarget: Comment?      // 仅一级评论可成为回复目标
    @Published var lengthWarning = false
    @Published var errorMessage: String?
    private let postID: UUID
    private let repo: SocialRepository
    private var bag = Set<AnyCancellable>()

    init(post: Post, repo: SocialRepository) {
        self.postID = post.id
        self.repo = repo
        repo.commentsPublisher(postID: post.id).receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.apply($0) }
            .store(in: &bag)
    }

    private func apply(_ all: [Comment]) {
        tops = all.filter { !$0.isChild }
        children = Dictionary(grouping: all.filter(\.isChild)) { $0.parentID ?? UUID() }
    }

    /// ≤500 字拦截由 UI onChange 截断 + 提示；此处为提交前最终防线
    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 500 else { return }
        let parent = replyTarget
        Task {
            do {
                try await repo.addComment(postID: postID, parentID: parent?.id, text: text)
                draft = ""
                replyTarget = nil
            } catch {
                errorMessage = "评论失败，请重试"
            }
        }
    }
}

// MARK: - 评论页：一级评论列表，二级回复缩进显示在一级之下
struct CommentListView: View {
    @StateObject private var vm: CommentListViewModel

    init(post: Post, repo: SocialRepository) {
        _vm = StateObject(wrappedValue: CommentListViewModel(post: post, repo: repo))
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(Array(vm.tops.enumerated()), id: \.element.id) { index, top in
                    commentRow(top, index: index, isChild: false)
                    ForEach(Array((vm.children[top.id] ?? []).enumerated()),
                            id: \.element.id) { childIndex, child in
                        commentRow(child, index: childIndex, isChild: true)
                    }
                }
            }
            .listStyle(.plain)
            .background(Color.pageBackground)
            // 注意：List/行容器不设 accessibilityIdentifier——iOS 27 下容器 identifier
            // 会覆盖全部子元素（实测），行级锚点由各叶子控件（comment.reply 等）承担
            inputBar
        }
        .navigationTitle("评论")
        // 信息流在 tab 内后，推送态隐藏 tabBar：底部输入栏需要完整落在安全区之上
        // （此前信息流以 sheet 呈现无 tabBar，迁 tab 后输入框被遮挡无法聚焦）
        .toolbar(.hidden, for: .tabBar)
        .alert("操作失败", isPresented: .init(get: { vm.errorMessage != nil },
                                              set: { if !$0 { vm.errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(vm.errorMessage ?? "") }
    }

    // MARK: 单条评论（二级缩进；仅一级有「回复」按钮）
    private func commentRow(_ comment: Comment, index: Int, isChild: Bool) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack {
                Text(comment.authorName).font(.callout.weight(.semibold))
                Spacer()
                Text(feedTime(comment.createdAt)).font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(comment.text).font(.callout)
            if !isChild {
                Button("回复") { vm.replyTarget = comment }
                    .font(.caption)
                    .accessibilityIdentifier("comment.reply.\(index)")
            }
        }
        .padding(.leading, isChild ? DS.Spacing.xl : 0)
        .padding(DS.Spacing.sm)
        .background(Color.cardBackground,
                    in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 2, leading: DS.Spacing.md,
                                  bottom: 2, trailing: DS.Spacing.md))
    }

    // MARK: 输入区：回复目标条 + 字数拦截提示 + 输入框 + 发送
    private var inputBar: some View {
        VStack(spacing: DS.Spacing.xs) {
            if let target = vm.replyTarget {
                HStack {
                    Text("回复 @\(target.authorName)").font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("取消回复") { vm.replyTarget = nil }
                        .font(.caption)
                        .accessibilityIdentifier("comment.cancelReply")
                }
            }
            HStack(alignment: .bottom, spacing: DS.Spacing.sm) {
                TextEditor(text: $vm.draft)
                    .frame(minHeight: 36, maxHeight: 120)
                    .padding(DS.Spacing.xs)
                    .background(Color.cardBackground,
                                in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                    .accessibilityIdentifier("comment.input")
                    // ≤500 字拦截：超长直接截断并提示（Repository 层还有最终校验）
                    // 截断本身会再触发一次 onChange，提示需闩锁到离开页面，不能在此复位
                    .onChange(of: vm.draft) { newValue in
                        if newValue.count > 500 {
                            vm.draft = String(newValue.prefix(500))
                            vm.lengthWarning = true
                        }
                    }
                Text("\(vm.draft.count)/500")
                    .font(.caption2).foregroundStyle(.secondary)
                    .accessibilityIdentifier("comment.length")
                Button("发送") { vm.send() }
                    .disabled(vm.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("comment.send")
            }
            if vm.lengthWarning {
                Text("评论最多500字，已自动截断")
                    .font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("comment.lengthHint")
            }
        }
        .padding(DS.Spacing.md)
        .background(Color.pageBackground)
    }
}
