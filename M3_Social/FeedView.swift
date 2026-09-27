import SwiftUI
import Combine
import Kingfisher

// MARK: - 信息流 ViewModel（订阅 repo.feedPublisher；未来 RemoteSocialRepository 替换 Mock 时零改动）
@MainActor final class FeedViewModel: ObservableObject {
    @Published private(set) var posts: [Post] = []
    @Published private(set) var favorites: [Post] = []   // 收藏列表页数据源
    @Published private(set) var isLoadingMore = false
    @Published var errorMessage: String?
    let repo: SocialRepository
    private var bag = Set<AnyCancellable>()

    init(repo: SocialRepository) {
        self.repo = repo
        repo.feedPublisher.receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.posts = $0 }
            .store(in: &bag)
        repo.favoritesPublisher.receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.favorites = $0 }
            .store(in: &bag)
    }

    /// 下拉刷新：重置到第 1 页
    func refresh() async {
        do { try await repo.refreshFeed() }
        catch { errorMessage = "刷新失败，请重试" }
    }

    /// 滚动到底翻页；Repository 到顶即止，此处仅做并发去重
    func loadNextPage() async {
        guard !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do { try await repo.loadNextPage() }
        catch { errorMessage = "加载失败，请重试" }
    }

    func toggleLike(_ postID: UUID) {
        Task { try? await repo.toggleLike(postID: postID) }
    }
    /// 更换即覆盖；传 nil 取消
    func setReaction(_ postID: UUID, _ reaction: Reaction?) {
        Task { try? await repo.setReaction(postID: postID, reaction: reaction) }
    }
    func toggleFavorite(_ postID: UUID) {
        Task { try? await repo.toggleFavorite(postID: postID) }
    }
    func publish(text: String, petID: UUID, imageURLs: [URL], visibility: Visibility) async throws {
        try await repo.publish(text: text, petID: petID, imageURLs: imageURLs, visibility: visibility)
    }
}

// MARK: - Reaction 展示（emoji + 文案）
extension Reaction {
    var emoji: String {
        switch self {
        case .thumbsUp: return "👍"
        case .love: return "❤️"
        case .laugh: return "😄"
        case .cry: return "😢"
        case .wow: return "😮"
        case .angry: return "😠"
        }
    }
}

/// 动态时间相对化展示
func feedTime(_ date: Date) -> String {
    let interval = Date().timeIntervalSince(date)
    if interval < 60 { return "刚刚" }
    if interval < 3600 { return "\(Int(interval / 60))分钟前" }
    if interval < 86400 { return "\(Int(interval / 3600))小时前" }
    return "\(Int(interval / 86400))天前"
}

// MARK: - 信息流主视图
struct FeedView: View {
    @StateObject private var vm: FeedViewModel

    /// 默认参数仅为兼容测试/预览；生产由 RootTabView 注入全 App 共享实例，
    /// 保证消息页跳转与发布后的动态都落在同一份数据上
    init(repo: SocialRepository = MockSocialRepository()) {
        _vm = StateObject(wrappedValue: FeedViewModel(repo: repo))
    }

    var body: some View {
        NavigationStack {
            List(Array(vm.posts.enumerated()), id: \.element.id) { index, post in
                PostCardView(index: index, post: post, vm: vm)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: DS.Spacing.xs, leading: DS.Spacing.md,
                                              bottom: DS.Spacing.xs, trailing: DS.Spacing.md))
            }
            .listStyle(.plain)
            .background(Color.pageBackground)
            .navigationTitle("宠友信息流")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    NavigationLink {
                        FavoritesView(vm: vm)
                    } label: {
                        Image(systemName: "bookmark")
                    }
                    .a11y("我的收藏", hint: "查看全部已收藏的动态")
                    .accessibilityIdentifier("feed.favorites")
                }
                ToolbarItem(placement: .confirmationAction) {
                    NavigationLink {
                        PublishFormView(vm: vm)
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .a11y("发布动态", hint: "撰写并发布一条新动态")
                    .accessibilityIdentifier("feed.publish")
                }
            }
            .refreshable { await vm.refresh() }
            .alert("操作失败", isPresented: .init(get: { vm.errorMessage != nil },
                                                  set: { if !$0 { vm.errorMessage = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(vm.errorMessage ?? "") }
        }
    }
}

// MARK: - 我的收藏（收藏动态的落点；卡片与信息流一致，可直接取消收藏/进评论）
struct FavoritesView: View {
    @ObservedObject var vm: FeedViewModel

    var body: some View {
        Group {
            if vm.favorites.isEmpty {
                VStack(spacing: DS.Spacing.md) {
                    Image(systemName: "bookmark")
                        .font(.system(size: 48)).foregroundStyle(.secondary)
                    Text("还没有收藏的动态").font(.headline)
                    Text("在信息流点动态右下角的书签即可收藏")
                        .font(.body).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("favorites.empty")
            } else {
                List(Array(vm.favorites.enumerated()), id: \.element.id) { index, post in
                    PostCardView(index: index, post: post, vm: vm)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: DS.Spacing.xs, leading: DS.Spacing.md,
                                                  bottom: DS.Spacing.xs, trailing: DS.Spacing.md))
                }
                .listStyle(.plain)
            }
        }
        .background(Color.pageBackground)
        .navigationTitle("我的收藏")
        .accessibilityIdentifier("favorites")
    }
}

// MARK: - 动态卡片（信息流与收藏页共用；行级锚点由各子控件承担）
struct PostCardView: View {
    let index: Int
    let post: Post
    @ObservedObject var vm: FeedViewModel

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(post.authorName).font(.headline)
                            .accessibilityIdentifier("feed.author.\(index)")
                        Text(feedTime(post.createdAt)).font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(post.visibility.rawValue).font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, DS.Spacing.sm)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                }
                Text(post.text).font(.body)
                if !post.imageURLs.isEmpty { imageStrip(post.imageURLs) }
                actionBar(index: index, post: post)
            }
        }
        // 注意：卡片容器不设 accessibilityIdentifier——它会成为最近无障碍元素并覆盖
        // 子控件自己的 identifier（实测按钮全变成卡片 id），行级锚点由各子控件承担
        .onAppear {
            // 最后一条出现时翻下一页；Repository 到顶即止，isLoadingMore 防抖动
            if post.id == vm.posts.last?.id {
                Task { await vm.loadNextPage() }
            }
        }
    }

    // MARK: 图片横滑（Kingfisher 异步加载：加载占位 + 失败占位）
    private func imageStrip(_ urls: [URL]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.sm) {
                ForEach(Array(urls.enumerated()), id: \.offset) { _, url in
                    KFImage(url)
                        .placeholder {
                            Rectangle().fill(Color.secondary.opacity(0.15))
                                .overlay { ProgressView() }
                        }
                        .onFailureView {
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        }
                        .fade(duration: 0.2)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 220, height: 160)
                        .clipped()
                        .cornerRadius(DS.Radius.control)
                        .accessibilityLabel("动态图片")
                }
            }
        }
    }

    // MARK: 行动区：点赞 / 评论 / 表情 / 收藏 / 分享
    private func actionBar(index: Int, post: Post) -> some View {
        HStack(spacing: DS.Spacing.md) {
            // 点赞：心形，已赞填充主题色，计数精确（计数经 a11y label 暴露，
            // 不放行内 StaticText identifier——iOS 27 下父 Button 的 identifier 会覆盖子元素）
            Button { vm.toggleLike(post.id) } label: {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: post.isLiked ? "heart.fill" : "heart")
                    Text("\(post.likeCount)")
                        .font(.caption)
                }
                .font(.body)
                .foregroundStyle(post.isLiked ? Color.accentColor : Color.secondary)
                .contentShape(Rectangle())   // 保证整帧可点，避免触摸落到行级链接
            }
            .a11y(post.isLiked ? "取消点赞，当前\(post.likeCount)次赞"
                               : "点赞，当前\(post.likeCount)次赞")
            .accessibilityIdentifier("feed.like.\(index)")
            // List 行内嵌 NavigationLink 时，默认按钮样式会被行级链接手势吃掉触摸——
            // borderless 使按钮自身响应（SwiftUI List 经典坑）
            .buttonStyle(.borderless)

            // 评论：进评论页
            NavigationLink {
                CommentListView(post: post, repo: vm.repo)
            } label: {
                Label("\(post.commentCount)", systemImage: "bubble.right")
                    .font(.body)
            }
            .buttonStyle(.plain)   // 不抢占整行触摸区域
            .a11y("查看评论，共\(post.commentCount)条")
            .accessibilityIdentifier("feed.comment.\(index)")

            // 表情回应：6 选一弹出，已选高亮；再点已选=取消，点其他=更换
            Menu {
                ForEach(Reaction.allCases, id: \.self) { r in
                    let selected = post.myReaction == r
                    Button {
                        vm.setReaction(post.id, selected ? nil : r)
                    } label: {
                        Label("\(r.emoji) \(r.rawValue)",
                              systemImage: selected ? "checkmark.circle.fill" : "circle")
                    }
                    .accessibilityIdentifier("feed.reactionOption.\(r.rawValue)")
                }
            } label: {
                Group {
                    if let mine = post.myReaction {
                        Text(mine.emoji).font(.title3)
                    } else {
                        Image(systemName: "face.smiling").font(.body)
                    }
                }
                .foregroundStyle(post.myReaction == nil ? Color.secondary : Color.accentColor)
            }
            .a11y(post.myReaction.map { "已回应\($0.rawValue)，点击更换或取消" } ?? "添加表情回应")
            .accessibilityIdentifier("feed.reaction.\(index)")

            Spacer()

            // 收藏
            Button { vm.toggleFavorite(post.id) } label: {
                Image(systemName: post.isFavorited ? "bookmark.fill" : "bookmark")
                    .font(.body)
                    .foregroundStyle(post.isFavorited ? Color.accentColor : Color.secondary)
            }
            .a11y(post.isFavorited ? "取消收藏" : "收藏")
            .accessibilityIdentifier("feed.favorite.\(index)")
            .buttonStyle(.borderless)

            // 分享降级：微信/微博/Instagram 原生 SDK 集成超出原型范围；
            // ShareLink 走系统分享面板，目标 App 未安装时由系统兜底（复制链接等）
            ShareLink(item: URL(string: "https://petpal.example.com/post/\(post.id.uuidString)")!,
                      subject: Text(post.authorName), message: Text(post.text)) {
                Image(systemName: "square.and.arrow.up").font(.body)
            }
            .a11y("分享动态")
            .accessibilityIdentifier("feed.share.\(index)")
        }
    }
}
