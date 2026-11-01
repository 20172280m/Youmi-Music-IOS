import Foundation

extension VideoDetailViewModel {
    var externalListenPlaybackSnapshot: CiliCiliListenPlaybackSnapshot? {
        // 只有真正把播放交给宿主之后才读宿主的快照；否则 Beans 里残留的
        // B 站音频会把内部播放器的续播时间/播放意图带偏。
        guard playbackContentMode == .audioOnly,
              externalListenIdentity != nil,
              CiliCiliRuntime.shared.usesExternalVideoListenPlayer
        else { return nil }
        return CiliCiliRuntime.shared.onVideoListenPlaybackSnapshot?(listenRequest(video: detail, cid: selectedCID ?? detail.cid))
    }

    func publishExternalVideoListenQueueIfNeeded() {
        guard !isPlaybackInvalidatedForNavigation, playbackContentMode == .audioOnly, externalListenIdentity != nil,
              !videoListenQueueSession.isLoadingInitial,
              !videoListenQueueSession.isLoadingMore,
              videoListenQueueSession.errorMessage == nil else { return }
        CiliCiliRuntime.shared.onVideoListenQueueChange?(externalVideoListenRequest)
    }

    @discardableResult
    func startExternalVideoListenIfNeeded(resumeTimeOverride: TimeInterval?, shouldResumePlayback: Bool?) -> Bool {
        guard playbackContentMode == .audioOnly,
              CiliCiliRuntime.shared.usesExternalVideoListenPlayer,
              let handler = CiliCiliRuntime.shared.onVideoListenModeChange,
              let audio = resolvedVideoListenAudioVariant else { return false }
        let request = externalVideoListenRequest
        let identity = request.bvid + ":" + String(request.cid ?? 0) + "|" + audio.id
        // Initial listen-mode navigation and later content switches use this same handoff.
        // Incidental render-store updates must not reload the Beans player.
        if externalListenIdentity == identity, resumeTimeOverride == nil, shouldResumePlayback == nil {
            finishPlaybackStartupWaiters(with: .externalAudioHandoff)
            return true
        }
        let resume = resumeTimeOverride ?? currentPlaybackResumeTime()
        let autoplay = shouldResumePlayback ?? currentPlaybackIntent()
        externalListenIdentity = identity
        stablePlayerViewModel?.stop()
        stablePlayerViewModel = nil
        // 交接后详情页没有播放器，身份必须失效；否则切回视频时
        // applyStableIdentityResumeIfNeeded 会认为「同一个播放器」直接返回，
        // 不会重建视频源，页面永久停在 --:--。
        stablePlayerIdentity = nil
        isSwitchingVideoListenMode = false
        handler(request, true, resume, autoplay)
        // Metadata tasks must not wait forever for a video frame from a player
        // that has been handed to Beans. This is not a video first-frame event.
        finishPlaybackStartupWaiters(with: .externalAudioHandoff)
        scheduleVideoListenQueuePreparation()
        return true
    }

    var externalVideoListenRequest: CiliCiliVideoListenRequest {
        let cid = selectedCID ?? detail.cid
        let page = detail.pages?.first { $0.cid == cid }
        let current = listenRequest(video: detail, cid: cid, title: page?.part, duration: page?.duration)
        let queue = videoListenQueueEntries.map { entry -> CiliCiliVideoListenRequest in
            switch entry.target {
            case .page(let page):
                return listenRequest(video: detail, cid: page.cid, title: page.part, duration: page.duration)
            case .video(let video), .episode(let video):
                return listenRequest(video: video, cid: video.cid)
            }
        }
        return CiliCiliVideoListenRequest(bvid: current.bvid, aid: current.aid, cid: current.cid,
                                         title: current.title, coverURL: current.coverURL, duration: current.duration,
                                         artist: current.artist, ownerID: current.ownerID, queue: queue,
                                         preservesQueueOrder: preservesExternalQueueOrder)
    }

    private var preservesExternalQueueOrder: Bool {
        if case .entryList = videoListenQueueSession.source { return true }
        return (detail.pages?.count ?? 0) > 1 || detail.isPGCEpisode
    }

    private func listenRequest(video: VideoItem, cid: Int?, title: String? = nil, duration: Int? = nil) -> CiliCiliVideoListenRequest {
        CiliCiliVideoListenRequest(bvid: video.bvid, aid: video.aid, cid: cid,
                                  title: title?.isEmpty == false ? title! : video.title, coverURL: video.pic,
                                  duration: TimeInterval(duration ?? video.duration ?? 0),
                                  artist: video.owner?.name ?? "", ownerID: video.owner?.mid)
    }
}
