import SwiftUI

// 入口快照只带当前已加载的一段列表；续页能力必须显式声明，
// 否则听视频队列到队尾后就无从知道该向谁要下一页。
nonisolated enum VideoEntryContinuation: Hashable, Sendable {
    case uploader(mid: Int, order: UploaderVideoOrder)
    case related
}

// A navigation value owns the list snapshot; another tab cannot overwrite it.
nonisolated struct VideoEntryContext: Hashable, Sendable {
    let title: String
    let videos: [VideoItem]
    let continuation: VideoEntryContinuation?

    init(title: String, videos: [VideoItem], continuation: VideoEntryContinuation? = nil) {
        self.title = title
        self.videos = videos
        self.continuation = continuation
    }
}

nonisolated struct VideoEntryRoute: Hashable, Sendable {
    let video: VideoItem
    let context: VideoEntryContext
}

private struct VideoEntryContextKey: EnvironmentKey {
    static let defaultValue: VideoEntryContext? = nil
}
private struct OpenVideoEntryActionKey: EnvironmentKey {
    static let defaultValue: ((VideoEntryRoute) -> Void)? = nil
}
extension EnvironmentValues {
    var videoEntryContext: VideoEntryContext? {
        get { self[VideoEntryContextKey.self] }
        set { self[VideoEntryContextKey.self] = newValue }
    }
    var openVideoEntryAction: ((VideoEntryRoute) -> Void)? {
        get { self[OpenVideoEntryActionKey.self] }
        set { self[OpenVideoEntryActionKey.self] = newValue }
    }
}
