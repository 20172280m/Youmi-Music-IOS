import Combine
import SwiftUI
import CiliCiliKit

@MainActor
final class BilibiliCiliCiliBridge {
    static let shared = BilibiliCiliCiliBridge()
    private var subscriptions = Set<AnyCancellable>()
    private weak var player: PlayerManager?
    private var listenQueueTask: Task<Void, Never>?
    private var listenQueueRevision = 0
    private var listenSongKey: String?
    private var listenPlaybackRevision: Int?
    private var expectedQueueKeys: [String] = []
    // 听视频队列续页：只在 UP 主列表接口上可用，相关推荐没有页码。
    private var listenOwnerID: Int?
    private var listenNextPage = 1
    private var listenPageExhausted = false
    private var listenPrefetchTask: Task<Void, Never>?
    private var listenPrefetchRevision = 0

    func configure(player: PlayerManager) {
        self.player = player
        guard subscriptions.isEmpty else { return }
        player.$currentIndex
            .receive(on: RunLoop.main)
            .sink { [weak self] index in
                guard let self else { return }
                let total = self.player?.queue.count ?? 0
                guard total > 0, index >= total - 3 else { return }
                self.prefetchListenQueuePage()
            }
            .store(in: &subscriptions)

        let runtime = CiliCiliRuntime.shared
        runtime.onPlaybackActivation = { [weak self] in
            self?.invalidateListenQueue()
            self?.player?.pauseForBilibiliVideo()
        }
        runtime.onVideoListenModeChange = { [weak self] request, enabled, resumeAt, shouldResume in
            self?.handleVideoListenModeChange(
                request: request,
                enabled: enabled,
                resumeAt: resumeAt,
                shouldResume: shouldResume
            )
        }
        runtime.onVideoListenPlaybackSnapshot = { [weak self] request in
            guard let player = self?.player,
                  player.currentSong?.identityKey == BilibiliListenQueue.song(request).identityKey else { return nil }
            return CiliCiliListenPlaybackSnapshot(time: player.currentPlaybackTime(), isPlaying: player.isPlaying)
        }
        runtime.onVideoListenQueueChange = { [weak self] request in self?.updateListenQueue(request) }
        runtime.onSessionChange = { cookie, name, id, avatar in
            try BilibiliAuth.shared.acceptCiliCiliSession(cookie: cookie, name: name, id: id, avatar: avatar)
        }
        synchronizeAccount()
        runtime.$isVideoDetailActive.removeDuplicates().sink { active in
            if active { BilibiliPresentationState.shared.enterVideo("cilicili-module") }
            else { BilibiliPresentationState.shared.leaveVideo("cilicili-module") }
        }.store(in: &subscriptions)
        runtime.$isLiveRoomActive.removeDuplicates().sink { active in
            if active { BilibiliPresentationState.shared.enterLive("cilicili-live") }
            else { BilibiliPresentationState.shared.leaveLive("cilicili-live") }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .beansBilibiliLoginDidUpdate).sink { [weak self] _ in
            self?.synchronizeAccount()
        }.store(in: &subscriptions)
        player.$isPlaying.removeDuplicates().filter { $0 }.sink { _ in
            runtime.stopPlaybackForMusic()
        }.store(in: &subscriptions)
    }

    private func handleVideoListenModeChange(
        request: CiliCiliVideoListenRequest,
        enabled: Bool,
        resumeAt: TimeInterval,
        shouldResume: Bool
    ) {
        invalidateListenQueue()
        guard let player else { return }
        guard enabled else {
            player.pauseForBilibiliVideo()
            return
        }

        let song = BilibiliListenQueue.song(request)
        let queue = BilibiliListenQueue.songs(for: request)
        player.playBilibiliAudio(song, context: queue, resumeAt: resumeAt, shouldResume: shouldResume)
        listenSongKey = song.identityKey
        listenPlaybackRevision = player.queueContextRevision
        listenOwnerID = request.ownerID
        listenNextPage = 2
        listenPageExhausted = false
        expectedQueueKeys = player.queue.map(\.identityKey)
        // A supplied entry list is authoritative. Do not replace its order with author page 1.
        guard shouldResume, !request.preservesQueueOrder, request.queue.count <= 1 else { return }
        let revision = listenQueueRevision
        let playbackRevision = player.queueContextRevision

        // Beans 的播放器按钮不经过 CiliCili 的详情页控件。把当前上下文的
        // 下一批视频补进同一个 Beans 队列，才能让“下一首”继续按 UP 主/相关推荐
        // 前进，而不是因为外部播放器队列只有一首而停住。
        let api = BilibiliAPI.shared
        listenQueueTask = Task { @MainActor [weak self, weak player] in
            do {
                let candidates: [BilibiliFeedVideo]
                if let ownerID = request.ownerID, ownerID > 0 {
                    let owner = Artist(id: String(ownerID), name: request.artist, coverURL: nil, source: .bilibili)
                    candidates = try await api.upVideos(owner, page: 1).items
                } else {
                    candidates = try await api.relatedVideos(aid: String(request.aid ?? 0))
                }
                let additions = candidates.compactMap { item -> Song? in
                    let bvid = item.song.bilibiliID?.split(separator: ":").first.map(String.init)
                    guard bvid != request.bvid else { return nil }
                    return item.song
                }
                // A late author response must not contaminate a newer music/video queue.
                guard !Task.isCancelled, let self, let player,
                      revision == self.listenQueueRevision,
                      playbackRevision == player.queueContextRevision,
                      player.currentSong?.identityKey == song.identityKey,
                      player.queue.map(\.identityKey) == [song.identityKey] else { return }
                player.append(songs: additions)
                self.expectedQueueKeys = player.queue.map(\.identityKey)
                if candidates.count < 20 { self.listenPageExhausted = true }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self?.listenQueueRevision == revision else { return }
                BeansLogger.shared.log("听视频队列预加载失败：\(error.localizedDescription)", level: .debug)
            }
        }
    }

    /// 播到队列倒数第三条时补下一页 UP 主视频：去重、保持顺序、失败不丢游标。
    private func prefetchListenQueuePage() {
        guard let player, let ownerID = listenOwnerID, !listenPageExhausted,
              listenPrefetchTask == nil,
              listenSongKey != nil,
              listenPlaybackRevision == player.queueContextRevision else { return }
        let revision = listenPrefetchRevision
        let page = listenNextPage
        let currentKey = listenSongKey
        listenPrefetchTask = Task { @MainActor [weak self, weak player] in
            defer { self?.listenPrefetchTask = nil }
            do {
                let owner = Artist(id: String(ownerID), name: "", coverURL: nil, source: .bilibili)
                let result = try await BilibiliAPI.shared.upVideos(owner, page: page)
                guard !Task.isCancelled, let self, let player,
                      revision == self.listenPrefetchRevision,
                      self.listenPlaybackRevision == player.queueContextRevision,
                      player.currentSong?.identityKey == currentKey else { return }
                var seen = Set(player.queue.map(\.identityKey))
                var additions: [Song] = []
                for item in result.items {
                    let song = item.song
                    if seen.insert(song.identityKey).inserted { additions.append(song) }
                }
                if !additions.isEmpty {
                    player.append(songs: additions)
                    self.expectedQueueKeys = player.queue.map(\.identityKey)
                    self.listenNextPage = page + 1
                }
                if additions.isEmpty || !result.more {
                    self.listenPageExhausted = true
                }
                BeansLogger.shared.log("听视频续页：第 \(page) 页，新增 \(additions.count) 条，队列 \(player.queue.count) 条", level: .debug)
            } catch is CancellationError {
                return
            } catch {
                // 失败不推进游标：下次还从这一页取，已加载的部分继续播放。
                guard !Task.isCancelled, self?.listenPrefetchRevision == revision else { return }
                BeansLogger.shared.log("听视频续页失败（停在已加载部分）：\(error.localizedDescription)", level: .debug)
                ToastCenter.shared.show("网络不可用，先播放已加载的内容")
            }
        }
    }

    private func invalidateListenQueue() {
        listenQueueRevision += 1
        listenQueueTask?.cancel()
        listenQueueTask = nil
        listenPrefetchTask?.cancel()
        listenPrefetchTask = nil
        listenPrefetchRevision += 1
        listenOwnerID = nil
        listenNextPage = 1
        listenPageExhausted = false
        listenSongKey = nil
        listenPlaybackRevision = nil
        expectedQueueKeys = []
    }

    private func updateListenQueue(_ request: CiliCiliVideoListenRequest) {
        let song = BilibiliListenQueue.song(request)
        guard let player, listenSongKey == song.identityKey,
              listenPlaybackRevision == player.queueContextRevision,
              player.currentSong?.identityKey == song.identityKey,
              player.queue.map(\.identityKey) == expectedQueueKeys else { return }
        let queue = BilibiliListenQueue.songs(for: request)
        guard queue.count > 1 else { return }
        player.updateBilibiliAudioContext(queue, currentSongKey: song.identityKey)
        expectedQueueKeys = player.queue.map(\.identityKey)
        listenQueueTask?.cancel()
        listenQueueTask = nil
    }

    private func synchronizeAccount() {
        let auth = BilibiliAuth.shared
        CiliCiliRuntime.shared.synchronizeLegacySession(
            cookie: auth.cookieHeader, name: auth.nickname, userID: auth.accountID,
            avatar: auth.avatarURL?.absoluteString
        )
    }
}

extension BilibiliNativeRoute {
    var ciliCiliRoute: CiliCiliRoute? {
        switch self {
        case .video(let song):
            let parts = (song.bilibiliID ?? "").split(separator: ":", maxSplits: 1)
            return .video(bvid: parts.first.map(String.init) ?? "", title: song.name,
                          cover: song.coverURL?.absoluteString, cid: parts.count > 1 ? Int(parts[1]) : nil)
        case .up(let artist):
            return .uploader(mid: Int(artist.id) ?? 0, name: artist.name, avatar: artist.coverURL?.absoluteString)
        case .live(let room): return .live(roomID: Int(room.id) ?? 0)
        case .collection(let item):
            return .collection(id: Int(item.number) ?? 0, isSeries: item.kind == .series,
                               ownerID: Int(item.ownerID) ?? 0, ownerName: item.ownerName, title: item.title)
        case .account: return .account
        case .playlist: return nil
        }
    }
}
