import SwiftUI

/// 全屏歌手页的唯一呈现入口。
///
/// 从根视图铺满整屏：它在标签栏之上，也不新建导航栈。各 tab 只负责“点了谁”，
/// 不自己弹 cover——从页面内部弹这一页会冻住主线程（画面出得来、点击和滚动全没反应）。
@MainActor
final class ArtistPresentation: ObservableObject {
    static let shared = ArtistPresentation()

    /// 只知道名字的一路请求（从播放器点歌手名进来时只有名字，没有歌手对象）。
    struct NameRequest: Identifiable, Equatable {
        let id: UUID = UUID()
        let name: String
        let source: SongSource
    }

    @Published var artist: Artist?
    @Published var nameRequest: NameRequest?

    private init() {}

    func present(_ artist: Artist) {
        BeansHaptics.tap()
        nameRequest = nil
        self.artist = artist
    }

    /// 播放器那边只发请求，不自己铺页面：这一页一律由根视图在播放器上面铺出来，
    /// 播放器留在下面不动（页面挂在播放器自己的视图里会带着一段滚动偏移打开）。
    func present(name: String, source: SongSource) {
        BeansHaptics.tap()
        artist = nil
        nameRequest = NameRequest(name: name, source: source)
    }

    func close() {
        artist = nil
        nameRequest = nil
    }
}
