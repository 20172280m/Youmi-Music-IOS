import SwiftUI

struct InitialVideoDetailDetailContentPage: View {
    let seedVideo: VideoItem
    let layoutWidth: CGFloat
    let mountsSecondaryContent: Bool

    private var contentWidth: CGFloat {
        PlaybackDetailContentMetrics.contentWidth(for: layoutWidth)
    }

    private var shouldShowInitialPageMenuPlaceholder: Bool {
        !seedVideo.isPGCEpisode && (seedVideo.pages?.count ?? 1) > 1
    }

    var body: some View {
        InitialVideoDetailControls(
            titleText: seedVideo.title,
            contentWidth: contentWidth
        )
        .padding(.horizontal, PlaybackDetailContentMetrics.horizontalPadding)

        if shouldShowInitialPageMenuPlaceholder {
            InitialPageMenuPlaceholder(pageCount: seedVideo.pages?.count)
                .padding(.horizontal, PlaybackDetailContentMetrics.horizontalPadding)
        }

        // 首屏也铺上相关推荐的骨架：之前只有次要内容挂载后才有，
        // 冷启进详情时下半屏是一片空的，看上去像白了一下。
        if !seedVideo.isPGCEpisode {
            InitialRelatedSection(layoutWidth: layoutWidth)
        }
    }
}
