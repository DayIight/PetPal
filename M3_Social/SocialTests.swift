import XCTest
import Combine
@testable import PetPal

final class MockSocialRepositoryTests: XCTestCase {
    private var repo: MockSocialRepository!
    override func setUp() { repo = MockSocialRepository() }

    private func currentFeed() -> [Post] {   // CurrentValueSubject 同步回放
        var result: [Post] = []
        let c = repo.feedPublisher.sink { result = $0 }
        defer { c.cancel() }
        return result
    }

    func test_firstPage_has20Items() {
        XCTAssertEqual(currentFeed().count, 20)
    }
    func test_loadNextPage_appends20_andStopsAtEnd() async throws {
        try await repo.loadNextPage()
        XCTAssertEqual(currentFeed().count, 40)
        try await repo.loadNextPage()
        XCTAssertEqual(currentFeed().count, 45)   // 最后一页只有5条
        try await repo.loadNextPage()
        XCTAssertEqual(currentFeed().count, 45)   // 到顶不溢出
    }
    func test_toggleLike_isExactAndReversible() async throws {
        let post = currentFeed()[0]
        try await repo.toggleLike(postID: post.id)
        XCTAssertEqual(currentFeed()[0].likeCount, post.likeCount + 1)
        XCTAssertTrue(currentFeed()[0].isLiked)
        try await repo.toggleLike(postID: post.id)
        XCTAssertEqual(currentFeed()[0].likeCount, post.likeCount)
        XCTAssertFalse(currentFeed()[0].isLiked)
    }
    func test_replyToTopLevel_succeeds() async throws {
        let post = currentFeed()[0]
        var comments: [Comment] = []
        let c = repo.commentsPublisher(postID: post.id).sink { comments = $0 }
        let top = comments.first { !$0.isChild }!
        try await repo.addComment(postID: post.id, parentID: top.id, text: "同感")
        XCTAssertEqual(comments.count, 4)
        c.cancel()
    }
    func test_replyToChild_throws() async throws {
        let post = currentFeed()[0]
        var comments: [Comment] = []
        let c = repo.commentsPublisher(postID: post.id).sink { comments = $0 }
        let child = comments.first { $0.isChild }!
        await XCTAssertThrowsErrorAsync(
            try await repo.addComment(postID: post.id, parentID: child.id, text: "再回复"))
        c.cancel()
    }
    func test_commentOver500_throws() async {
        let post = currentFeed()[0]
        await XCTAssertThrowsErrorAsync(
            try await repo.addComment(postID: post.id, parentID: nil,
                                      text: String(repeating: "字", count: 501)))
    }
}

// async 断言辅助
func XCTAssertThrowsErrorAsync(_ expression: @autoclosure () async throws -> Any,
                               file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail("应抛错", file: file, line: line) }
    catch { /* 预期 */ }
}
