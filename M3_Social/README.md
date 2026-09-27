# M3 社交互动模块（协议 + Mock + 信息流 UI）

`SocialRepository` 协议即边界，`MockSocialRepository` 驱动信息流/点赞/两级评论的演示与单测；
UI 已接入（`FeedView` / `PublishFormView` / `CommentListView`），图片经 Kingfisher 加载。
发布动态支持添加照片（≤9 张，拍照或相册多选）：所选图片经 `AvatarStore` 压缩落盘（≤1080px、JPEG 0.8）后以 file URL 传给信息流加载。
延后增强：转发、三方分享原生 SDK（协议已预留接口，Mock 提供最小实现）。
收藏已闭环：动态卡片书签切换收藏态，信息流左上角「我的收藏」经 `favoritesPublisher` 展示全部已收藏动态（不受分页影响）。

## 架构说明（本轮输出形式：架构说明）
边界划分：健康与档案数据（M1/M2）在 Core Data 本地；云备份走 CloudKit 私有库；
社交数据属远程后端域——后端未提供，`SocialRepository` 协议即客户端与后端的契约，
未来以 `RemoteSocialRepository`（REST/GraphQL + 分页游标）替换 Mock，ViewModel 与 View 零改动。
Mock 数据规模：45 条动态（3 页 × 20），前 6 条带 picsum 图片供 Kingfisher 真实加载，前 3 条各带 2 条一级评论 + 1 条二级回复，
足以演示信息流分页、点赞切换、两级评论树。
规则落点：可见性三选一默认"仅粉丝"在 `publish` 入参强制；评论 ≤500 字、
二级评论不可再回复在 Repository 层抛错（UI 层仅隐藏二级评论的回复按钮，双保险）。
图片/视频 URL 由 View 层经 Kingfisher 加载（内存默认 + 磁盘缓存上限 200MB，配置在 AppDelegate 启动处）；
分享降级已落地：动态卡片 ShareLink 分享文本+链接占位，目标 App 未安装时由系统分享面板兜底（复制链接）。

## 数据模型（纯值类型，不建 Core Data 表，输出形式：架构说明）
- `Post`：id、petID（发布必须关联宠物档案）、作者、文本、imageURLs、
  visibility（公开/仅粉丝/私密）、likeCount/isLiked、myReaction、commentCount、isFavorited
- `Comment`：id、postID、parentID（nil=一级；指向一级评论=二级）、文本（≤500 字）
- `Reaction`：6 种预设（赞/爱心/笑/哭/惊/怒），每用户每动态仅一种、可更换

## 关键交互逻辑（输出形式：代码骨架，见 SocialSkeleton.swift）
1. 信息流：`refreshFeed` 重置到第 1 页；`loadNextPage` 每次 +20 条，到顶即止。
2. 点赞：`toggleLike` 本地即时改 isLiked/likeCount 并重发 publisher（UI 实时反馈）。
3. 评论：`addComment` 校验字数与层级；二级评论再回复抛 `SocialError.replyToChild`。

## 测试要点（输出形式：代码骨架，见 SocialTests.swift）
- 首屏 20 条、翻页至 40 条、翻页到顶不溢出
- 点赞/取消点赞计数精确往返
- 回复一级评论成功；回复二级评论抛错；501 字评论抛错

## 独立验收清单（M3）
- [ ] `SocialRepository` 协议覆盖发布/分页/点赞/评论/表情/收藏全部接口
- [ ] 发布接口强制 visibility 三选一，默认值为"仅粉丝"
- [ ] Mock 数据 ≥3 页，前 3 条动态含两级评论树
- [ ] `loadNextPage` 每页 20 条，到顶后重复调用不产生重复数据
- [ ] 点赞切换后 likeCount 精确 ±1，publisher 即时推送
- [ ] 二级评论再回复在 Repository 层被拒绝
- [ ] 评论超过 500 字被拒绝
- [ ] Mock 单测全部通过（本模块无 Core Data 依赖，可脱离 App 运行）
