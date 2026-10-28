import SwiftUI

/// 详情页在没有播放器画面时用的返回按钮。
///
/// 返回按钮平时由播放器外壳自己画，但它只在播放器真正出画之后才存在。
/// 「视频信息到了、播放地址失败」和「播放器还没建好」这两个状态页面上什么都没有，
/// 系统返回按钮又被关掉了，于是只剩左缘右滑能出去。
/// 这个按钮只在没有播放器的那一支里出现，用系统主色描边、材质打底，
/// 白底和黑底都看得见；播放器一出来它就不在，不会和播放器自己的返回叠在一起。
struct VideoDetailFallbackBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: {
            Haptics.light()
            action()
        }) {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("返回")
        .accessibilityIdentifier("ui.videoDetail.fallbackBack")
    }
}