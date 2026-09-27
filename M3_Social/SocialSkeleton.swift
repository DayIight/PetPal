import Foundation
import Combine

// MARK: - 模型（纯值类型；社交数据不入 Core Data）
enum Visibility: String, CaseIterable, Identifiable {
    case `public` = "公开", followersOnly = "仅粉丝", `private` = "私密"
    var id: String { rawValue }
    static let `default`: Visibility = .followersOnly
}

enum Reaction: String, CaseIterable {   // 每用户每动态仅一种，可更换
    case thumbsUp = "赞", love = "爱心", laugh = "笑", cry = "哭", wow = "惊", angry = "怒"
}

struct Post: Identifiable, Equatable {
    var id: UUID
    var petID: UUID                     // 发布必须关联宠物档案
    var authorName: String
    var text: String
    var imageURLs: [URL]                // View 层经 Kingfisher 加载
    var visibility: Visibility
    var likeCount: Int
    var isLiked: Bool
    var myReaction: Reaction?
    var commentCount: Int
    var isFavorited: Bool
    var createdAt: Date
}

struct Comment: Identifiable, Equatable {
    var id: UUID
    var postID: UUID
    var parentID: UUID?                 // nil=一级；指向一级=二级，二级不可再回复
    var authorName: String
    var text: String                    // ≤500 字
    var createdAt: Date
    var isChild: Bool { parentID != nil }
}

enum SocialError: Error { case replyToChild, commentTooLong }

// MARK: - 互动消息（消息 tab；与种子动态/评论真实关联，点击可跳转到动态/具体评论）
struct InteractionMessage: Identifiable, Equatable {
    enum Kind { case likePost, commentPost, reactPost, likeComment, replyComment }
    let id: UUID
    let kind: Kind
    let actor: String
    let excerpt: String          // 动态摘录或「评论摘录」
    let post: Post               // 跳转落点：目标动态快照
    let commentID: UUID?         // 评论类消息定位到具体评论；动态类为 nil
    let createdAt: Date
    var unread: Bool
}

// MARK: - Repository 边界（未来 RemoteSocialRepository 替换 Mock，上层零改动）
protocol SocialRepository: AnyObject {
    var feedPublisher: AnyPublisher<[Post], Never> { get }
    /// 已收藏动态全集（不受信息流分页影响；Mock 为内存过滤，未来由远端/本地库实现）
    var favoritesPublisher: AnyPublisher<[Post], Never> { get }
    func refreshFeed() async throws     // 下拉刷新，重置到第1页
    func loadNextPage() async throws    // 每页20条
    func publish(text: String, petID: UUID, imageURLs: [URL], visibility: Visibility) async throws
    func toggleLike(postID: UUID) async throws
    func commentsPublisher(postID: UUID) -> AnyPublisher<[Comment], Never>
    func addComment(postID: UUID, parentID: UUID?, text: String) async throws
    func setReaction(postID: UUID, reaction: Reaction?) async throws   // 延后增强
    func toggleFavorite(postID: UUID) async throws                     // 延后增强
}

// MARK: - Mock 实现（45条=3页；前3条各含 2条一级 + 1条二级评论）
final class MockSocialRepository: SocialRepository {
    static let pageSize = 20
    private var posts: [Post] = []
    private var comments: [UUID: [Comment]] = [:]
    private var messages: [InteractionMessage] = []
    private var loadedPages = 1
    private let feedSubject = CurrentValueSubject<[Post], Never>([])
    private let favoritesSubject = CurrentValueSubject<[Post], Never>([])
    private var commentSubjects: [UUID: CurrentValueSubject<[Comment], Never>] = [:]
    var feedPublisher: AnyPublisher<[Post], Never> { feedSubject.eraseToAnyPublisher() }
    var favoritesPublisher: AnyPublisher<[Post], Never> { favoritesSubject.eraseToAnyPublisher() }
    init() { seed() }

    private func seed() {
        posts = (1...45).map { i in
            // 前 6 条带 picsum 图片，供信息流 Kingfisher 真实加载演示
            let images: [URL] = i <= 6
                ? [URL(string: "https://picsum.photos/seed/pet\(i)/600/400")!] : []
            return Post(id: UUID(), petID: UUID(), authorName: "宠友\(i)", text: "第 \(i) 条动态",
                 imageURLs: images, visibility: .default, likeCount: i, isLiked: false,
                 myReaction: nil, commentCount: 0, isFavorited: false,
                 createdAt: Date().addingTimeInterval(Double(-i) * 3600))
        }
        for i in posts.indices.prefix(3) {
            let top1 = Comment(id: UUID(), postID: posts[i].id, parentID: nil,
                               authorName: "小明", text: "好可爱！", createdAt: Date())
            let child = Comment(id: UUID(), postID: posts[i].id, parentID: top1.id,
                                authorName: "楼主", text: "谢谢喜欢～", createdAt: Date())
            let top2 = Comment(id: UUID(), postID: posts[i].id, parentID: nil,
                               authorName: "阿花", text: "求同款粮", createdAt: Date())
            comments[posts[i].id] = [top1, child, top2]
            posts[i].commentCount = 3
        }
        seedMessages()
        emit()
    }

    /// 演示消息与种子动态/评论真实关联：post/commentID 均可跳转落位
    private func seedMessages() {
        func ago(minutes m: Double) -> Date { Date().addingTimeInterval(-m * 60) }
        let p0 = posts[0], p1 = posts[1]
        let top1 = comments[p0.id]![0]   // 小明「好可爱！」
        let top2 = comments[p0.id]![2]   // 阿花「求同款粮」
        messages = [
            InteractionMessage(id: UUID(), kind: .likePost, actor: "宠友12", excerpt: p0.text,
                               post: p0, commentID: nil, createdAt: ago(minutes: 5), unread: true),
            InteractionMessage(id: UUID(), kind: .commentPost, actor: "小明", excerpt: p0.text,
                               post: p0, commentID: top1.id, createdAt: ago(minutes: 60), unread: true),
            InteractionMessage(id: UUID(), kind: .reactPost, actor: "阿花", excerpt: p1.text,
                               post: p1, commentID: nil, createdAt: ago(minutes: 180), unread: false),
            InteractionMessage(id: UUID(), kind: .likeComment, actor: "楼主", excerpt: "「\(top1.text)」",
                               post: p0, commentID: top1.id, createdAt: ago(minutes: 60 * 24), unread: false),
            InteractionMessage(id: UUID(), kind: .replyComment, actor: "宠友7", excerpt: "「\(top2.text)」",
                               post: p0, commentID: top2.id, createdAt: ago(minutes: 60 * 48), unread: false),
        ]
    }

    /// 消息 tab 数据源（演示数据一次性快照；接真实后端时换 publisher）
    func interactionMessages() -> [InteractionMessage] { messages }
    private func emit() {
        feedSubject.send(Array(posts.prefix(loadedPages * Self.pageSize)))
        favoritesSubject.send(posts.filter(\.isFavorited))
    }
    private func latency() async throws { try await Task.sleep(nanoseconds: 150_000_000) }

    func refreshFeed() async throws { try await latency(); loadedPages = 1; emit() }
    func loadNextPage() async throws {
        try await latency()
        guard loadedPages * Self.pageSize < posts.count else { return }   // 到顶
        loadedPages += 1; emit()
    }
    func publish(text: String, petID: UUID, imageURLs: [URL], visibility: Visibility) async throws {
        try await latency()
        posts.insert(Post(id: UUID(), petID: petID, authorName: "我", text: text,
                          imageURLs: imageURLs, visibility: visibility, likeCount: 0,
                          isLiked: false, myReaction: nil, commentCount: 0,
                          isFavorited: false, createdAt: Date()), at: 0)
        emit()
    }
    func toggleLike(postID: UUID) async throws {
        guard let i = posts.firstIndex(where: { $0.id == postID }) else { return }
        posts[i].isLiked.toggle()
        posts[i].likeCount += posts[i].isLiked ? 1 : -1
        emit()
    }
    func commentsPublisher(postID: UUID) -> AnyPublisher<[Comment], Never> {
        if commentSubjects[postID] == nil { commentSubjects[postID] = .init(comments[postID] ?? []) }
        return commentSubjects[postID]!.eraseToAnyPublisher()
    }
    func addComment(postID: UUID, parentID: UUID?, text: String) async throws {
        guard text.count <= 500 else { throw SocialError.commentTooLong }
        if let pid = parentID,
           let parent = comments[postID]?.first(where: { $0.id == pid }),
           parent.isChild { throw SocialError.replyToChild }
        comments[postID, default: []].append(
            Comment(id: UUID(), postID: postID, parentID: parentID,
                    authorName: "我", text: text, createdAt: Date()))
        commentSubjects[postID]?.send(comments[postID] ?? [])
        if let i = posts.firstIndex(where: { $0.id == postID }) { posts[i].commentCount += 1; emit() }
    }
    func setReaction(postID: UUID, reaction: Reaction?) async throws {   // 更换即覆盖
        guard let i = posts.firstIndex(where: { $0.id == postID }) else { return }
        posts[i].myReaction = reaction; emit()
    }
    func toggleFavorite(postID: UUID) async throws {
        guard let i = posts.firstIndex(where: { $0.id == postID }) else { return }
        posts[i].isFavorited.toggle(); emit()
    }
}
