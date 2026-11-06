import SwiftUI

struct VideoDetailInitialContent: View {
    let seedVideo: VideoItem
    @Binding var selectedContentTab: VideoDetailContentTab
    let runtimeSettings: VideoDetailRuntimeSettingsSnapshot
    let onNavigateBack: () -> Void

    @State private var firstFrameProbe = FirstFrameProbe()

    var body: some View {
        VideoDetailInitialPlaybackPage(
            seedVideo: seedVideo,
            selectedContentTab: $selectedContentTab,
            runtimeSettings: runtimeSettings,
            onNavigateBack: onNavigateBack
        )
        .onAppear {
            // 只读打点：轻量首屏（播放器占位 + 标签）什么时候真正出来。
            VideoDetailTransitionTiming.mark("INIT onAppear")
            firstFrameProbe.fire(after: "initial")
        }
    }
}
