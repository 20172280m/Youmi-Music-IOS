import SwiftUI

/// 听视频模式下详情页顶部的封面面板。
///
/// 听视频时画面交给外部播放器，详情页不建播放器画面，这块原本留白。
/// 这里用播放器同一份封面图层占位：尺寸沿用视频区，不改变下面的标题、
/// UP 信息和相关推荐的位置；右下角给一个播放列表入口。
struct VideoDetailListenArtworkPanel: View {
    @ObservedObject var viewModel: VideoDetailViewModel
    let size: CGSize
    @Binding var isListenQueuePresented: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VideoListenArtworkLayer(video: viewModel.detail, isLandscape: false)
                .allowsHitTesting(false)

            queueButton
                .padding(.trailing, 12)
                .padding(.bottom, 12)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .accessibilityElement(children: .contain)
    }

    private var queueButton: some View {
        Button {
            Haptics.light()
            isListenQueuePresented = true
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
