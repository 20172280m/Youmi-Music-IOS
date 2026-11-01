import SwiftUI

/// 听视频模式下详情页顶部的封面面板。
///
/// 听视频时画面交给外部播放器，详情页不建播放器画面，这块原本留白。
/// 这里用播放器同一份封面图层占位：尺寸沿用视频区，不改变下面的标题、
/// UP 信息和相关推荐的位置。播放列表入口挂在容器最外层，和返回按钮同一层，
/// 不再塞进播放器框里（框内命中测试拿不到点击）。
struct VideoDetailListenArtworkPanel: View {
    @ObservedObject var viewModel: VideoDetailViewModel

    var body: some View {
        // 队列里刚点的那一首：详情还在路上时先用队列里的标题和封面占位，
        // 不然头部会停在上一条上，等一两秒才换过来。
        VideoListenArtworkLayer(video: viewModel.videoListenPendingDisplay ?? viewModel.detail,
                                isLandscape: false)
            .allowsHitTesting(false)
    }
}

/// 听视频封面面板上的「播放列表」入口。
struct VideoDetailListenQueueButton: View {
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.light()
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 13, weight: .semibold))
                Text("播放列表")
                    .font(.footnote.weight(.medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开听视频播放列表")
        .accessibilityHint("点按查看并切换听视频队列")
        .accessibilityIdentifier("ui.videoDetail.listenQueue")
    }
}
