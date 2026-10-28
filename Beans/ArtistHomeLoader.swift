import Foundation

/// 歌手主页加载链（重写版）
///
/// 规则：
/// - 所有网络和磁盘工作都在后台执行，主线程只负责把结果写进 @State。
/// - 每个请求都有硬超时，任何一处卡住都不会拖住整条链。
/// - 由页面持有的任务取消时，正在跑的请求一起取消。
/// - 不再从页面里跨队列等待任何东西。
final class ArtistHomeSnapshot: @unchecked Sendable {
    let artist: Artist?
    let songs: [Song]
    let albums: [Album]
    let errorMessage: String?
    /// 总预算到点、只拿到一部分内容：页面据此显示“部分内容加载失败”提示带。
    let timedOut: Bool

    init(artist: Artist?, songs: [Song], albums: [Album], errorMessage: String?, timedOut: Bool = false) {
        self.artist = artist
        self.songs = songs
        self.albums = albums
        self.errorMessage = errorMessage
        self.timedOut = timedOut
    }
}

struct ArtistHomeRequest: @unchecked Sendable {
    let artistName: String
    let source: SongSource
    let artistID: String?
    let seedArtist: Artist?
    let seedSongs: [Song]
    let seedAlbums: [Album]
    let cacheKey: String
}

enum ArtistHomeLoader {

    /// 入口：把整条链放到后台，页面 await 结果即可；页面任务取消时后台任务同步取消。
    /// 总预算：12 秒到点就返回已拿到的内容，不再无限等。
    static let totalBudgetSeconds: Double = 12

    static func load(_ request: ArtistHomeRequest) async -> ArtistHomeSnapshot {
        let task = Task.detached(priority: .userInitiated) { await perform(request) }
        return await withTaskCancellationHandler {
            let first = await withTaskGroup(of: ArtistHomeSnapshot?.self) { group -> ArtistHomeSnapshot? in
                group.addTask { await task.value }
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(totalBudgetSeconds * 1_000_000_000))
                    return nil
                }
                let result = await group.next() ?? nil
                group.cancelAll()
                return result
            }
            if let first {
                return first
            }
            task.cancel()
            // 到点没齐：把入口带进来的内容原样交回，页面留着已渲染的部分并显示提示带。
            return ArtistHomeSnapshot(artist: request.seedArtist,
                                      songs: request.seedSongs,
                                      albums: request.seedAlbums,
                                      errorMessage: nil,
                                      timedOut: true)
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - 一个真的会到点返回的调用

    /// 竞速盒：谁先完成谁把结果交出去，另一边即使永远不返回也不会拖住调用方。
    private final class RaceBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private var pendingValue: T?
        private var hasPending = false
        private var continuation: CheckedContinuation<T?, Never>?

        func finish(_ value: T?) {
            lock.lock()
            if finished { lock.unlock(); return }
            finished = true
            let waiting = continuation
            continuation = nil
            if waiting == nil { pendingValue = value; hasPending = true }
            lock.unlock()
            waiting?.resume(returning: value)
        }

        func wait() async -> T? {
            await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
                lock.lock()
                if finished {
                    let value = hasPending ? pendingValue : nil
                    lock.unlock()
                    c.resume(returning: value)
                } else {
                    continuation = c
                    lock.unlock()
                }
            }
        }
    }

    private static func call<T>(_ seconds: Double, _ operation: @escaping () async -> T, fallback: T) async -> T {
        let box = RaceBox<T>()
        let work = Task { let value = await operation(); box.finish(value) }
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            box.finish(nil)
        }
        let result = await box.wait()
        work.cancel()
        timer.cancel()
        return result ?? fallback
    }

    private static func perform(_ request: ArtistHomeRequest) async -> ArtistHomeSnapshot {
        let started = Date()
        var artist = request.seedArtist
        var songs = request.seedSongs
        var albums = request.seedAlbums
        var error: String?

        switch request.source {
        case .qq:
            let outcome = await qqArtist(request, artist: &artist)
            songs = outcome.songs; albums = outcome.albums; error = outcome.error
        case .kugou:
            let outcome = await kugouArtist(request, artist: &artist)
            songs = outcome.songs; albums = outcome.albums; error = outcome.error
        case .kuwo, .migu, .qishui, .bilibili:
            let outcome = await catalogArtist(request, artist: &artist)
            songs = outcome.songs; albums = outcome.albums; error = outcome.error
        default:
            let outcome = await netEaseArtist(request, artist: &artist)
            songs = outcome.songs; albums = outcome.albums; error = outcome.error
        }

        if Task.isCancelled {
            return ArtistHomeSnapshot(artist: artist, songs: [], albums: [], errorMessage: nil)
        }

        songs = creditedSongs(songs, name: request.artistName, artist: artist)
        if !songs.isEmpty || !albums.isEmpty {
            ArtistHomeCache.shared.save(artist: artist, songs: songs, albums: albums, for: request.cacheKey)
        }
        return ArtistHomeSnapshot(artist: artist, songs: songs, albums: albums, errorMessage: error)
    }

    private struct Outcome {
        var songs: [Song] = []
        var albums: [Album] = []
        var error: String?
    }

    // MARK: - 网易云

    private static func netEaseArtist(_ request: ArtistHomeRequest, artist: inout Artist?) async -> Outcome {
        var outcome = Outcome()
        let id: Int
        if let raw = request.artistID,
           let parsed = Int(raw.replacingOccurrences(of: "netease-", with: "")), parsed > 0 {
            id = parsed
        } else {
            let found = await call(8, {
                (try? await NetEaseAPI.shared.searchArtists(keyword: request.artistName, limit: 5)) ?? []
            }, fallback: [])
            guard let first = found.first else {
                outcome.error = "未找到歌手「\(request.artistName)」"
                return outcome
            }
            artist = first
            id = Int(first.id.replacingOccurrences(of: "netease-", with: "")) ?? 0
        }

        async let hot = call(12, {
            (try? await NetEaseAPI.shared.artistHotSongs(artistID: id, limit: 300)) ?? []
        }, fallback: [Song]())
        async let disc = call(12, {
            (try? await NetEaseAPI.shared.artistAlbums(artistID: id)) ?? []
        }, fallback: [Album]())

        var fetched = await hot
        if fetched.isEmpty {
            var fallbackSongs: [Song] = []
            for offset in stride(from: 0, to: 60, by: 30) {
                let page = await call(6, {
                    (try? await NetEaseAPI.shared.search(keyword: request.artistName, limit: 30, offset: offset)) ?? []
                }, fallback: [])
                if page.isEmpty { break }
                fallbackSongs.append(contentsOf: page)
                if page.count < 30 { break }
            }
            fetched = fallbackSongs
        }
        outcome.songs = fetched

        var fetchedAlbums = await disc
        if fetchedAlbums.isEmpty {
            fetchedAlbums = await searchAlbums(request, limit: 60)
        }
        outcome.albums = fetchedAlbums
        if outcome.songs.isEmpty { outcome.error = "未找到歌手「\(request.artistName)」" }
        return outcome
    }

    // MARK: - QQ

    private static func qqArtist(_ request: ArtistHomeRequest, artist: inout Artist?) async -> Outcome {
        var outcome = Outcome()
        async let disc = searchAlbums(request, limit: 60)

        var mid: String?
        if let raw = request.artistID, !raw.hasPrefix("qq-"), !raw.isEmpty {
            mid = raw
        } else if let first = await call(8, {
            (try? await QQMusicAPI.shared.searchArtists(keyword: request.artistName, limit: 5))?.first
        }, fallback: nil) {
            artist = first
            mid = first.id
        }

        var songs = await call(12, {
            (try? await QQMusicAPI.shared.artistHotSongs(mid: mid, name: request.artistName, limit: 300)) ?? []
        }, fallback: [Song]())

        if songs.isEmpty {
            var fallbackSongs: [Song] = []
            for offset in stride(from: 0, to: 60, by: 30) {
                let page = await call(6, {
                    (try? await QQMusicAPI.shared.searchSongs(keyword: request.artistName, limit: 30, offset: offset)) ?? []
                }, fallback: [])
                if page.isEmpty { break }
                fallbackSongs.append(contentsOf: page)
                if page.count < 30 { break }
            }
            var seen = Set<String>()
            songs = fallbackSongs.filter { seen.insert($0.identityKey).inserted }
        }
        outcome.songs = songs

        var fetchedAlbums = await disc
        if fetchedAlbums.isEmpty { fetchedAlbums = await searchAlbums(request, limit: 60) }
        outcome.albums = fetchedAlbums
        if outcome.songs.isEmpty { outcome.error = "未找到歌手「\(request.artistName)」" }
        return outcome
    }

    // MARK: - 酷狗

    private static func kugouArtist(_ request: ArtistHomeRequest, artist: inout Artist?) async -> Outcome {
        var outcome = Outcome()
        async let disc = searchAlbums(request, limit: 60)

        var resolved = artist
        if let raw = request.artistID, !raw.isEmpty, !raw.hasPrefix("qq-") {
            if resolved == nil {
                resolved = Artist(id: raw.replacingOccurrences(of: "kugou-", with: ""),
                                  name: request.artistName, coverURL: nil, source: .kugou)
            }
        } else if let first = await call(8, {
            (try? await KugouMusicAPI.shared.searchArtists(keyword: request.artistName, limit: 10))?.first
        }, fallback: nil) {
            resolved = first
        }
        artist = resolved

        var songs: [Song] = []
        if let resolved, !resolved.id.isEmpty, !resolved.id.hasPrefix("qq-") {
            var seen = Set<String>()
            for page in 1...10 {
                let batch = await call(8, {
                    (try? await KugouMusicAPI.shared.artistSongs(authorID: resolved.id, page: page, limit: 100)) ?? []
                }, fallback: [])
                if batch.isEmpty { break }
                let before = songs.count
                for song in batch where seen.insert(song.identityKey).inserted {
                    songs.append(song)
                    if songs.count >= 1_000 { break }
                }
                if songs.count >= 1_000 || songs.count == before { break }
            }
        }

        if songs.count < 100 {
            let exact = await call(10, {
                (try? await KugouMusicAPI.shared.searchSongs(keyword: request.artistName, limit: 300)) ?? []
            }, fallback: [])
            let works = await call(10, {
                (try? await KugouMusicAPI.shared.searchSongs(keyword: "\(request.artistName) 歌曲", limit: 300)) ?? []
            }, fallback: [])
            var seen = Set(songs.map(\.identityKey))
            for song in (exact + works) where seen.insert(song.identityKey).inserted {
                songs.append(song)
            }
        }

        if songs.isEmpty {
            let exact = await call(10, {
                (try? await KugouMusicAPI.shared.searchSongs(keyword: request.artistName, limit: 300)) ?? []
            }, fallback: [])
            let hot = await call(10, {
                (try? await KugouMusicAPI.shared.searchSongs(keyword: "\(request.artistName) 热门", limit: 200)) ?? []
            }, fallback: [])
            var seen = Set<String>()
            songs = (exact + hot).filter { seen.insert($0.identityKey).inserted }
        }

        outcome.songs = Array(songs.prefix(1_000))
        var fetchedAlbums = await disc
        if fetchedAlbums.isEmpty { fetchedAlbums = await searchAlbums(request, limit: 60) }
        outcome.albums = fetchedAlbums
        if outcome.songs.isEmpty { outcome.error = "未找到歌手「\(request.artistName)」" }
        return outcome
    }

    // MARK: - 其它目录（酷我 / 咪咕 / 汽水 / B 站）

    private static func catalogArtist(_ request: ArtistHomeRequest, artist: inout Artist?) async -> Outcome {
        var outcome = Outcome()
        async let disc = searchAlbums(request, limit: 60)

        if artist?.coverURL == nil {
            let candidates: [Artist]
            switch request.source {
            case .kuwo:
                candidates = await call(8, {
                    (try? await AdditionalCatalogSearchAPI.searchKuwoArtists(keyword: request.artistName, limit: 20)) ?? []
                }, fallback: [])
            case .migu:
                candidates = await call(8, {
                    (try? await AdditionalCatalogSearchAPI.searchMiguArtists(keyword: request.artistName, limit: 20)) ?? []
                }, fallback: [])
            case .bilibili:
                candidates = await call(8, {
                    (try? await BilibiliAPI.shared.searchArtists(keyword: request.artistName, limit: 20)) ?? []
                }, fallback: [])
            default:
                candidates = []
            }
            let normalized = normalizedName(request.artistName)
            if let resolved = candidates.first(where: { normalizedName($0.name) == normalized }) ?? candidates.first {
                artist = resolved
            }
        }

        var songs: [Song]
        switch request.source {
        case .kuwo:
            songs = await call(10, { (try? await AdditionalCatalogSearchAPI.searchKuwo(keyword: request.artistName, limit: 100)) ?? [] }, fallback: [])
        case .migu:
            songs = await call(10, { (try? await AdditionalCatalogSearchAPI.searchMigu(keyword: request.artistName, limit: 100)) ?? [] }, fallback: [])
        case .qishui:
            songs = await call(10, { (try? await QishuiAPI.shared.artistSongs(name: request.artistName, limit: 100)) ?? [] }, fallback: [])
        case .bilibili:
            songs = await call(10, { (try? await BilibiliAPI.shared.artistSongs(name: request.artistName, id: request.artistID, limit: 100)) ?? [] }, fallback: [])
        default:
            songs = []
        }
        outcome.songs = creditedSongs(songs, name: request.artistName, artist: artist)

        var fetchedAlbums = await disc
        if fetchedAlbums.isEmpty { fetchedAlbums = await searchAlbums(request, limit: 60) }
        outcome.albums = fetchedAlbums

        if artist == nil {
            artist = Artist(id: request.artistID ?? "\(request.source.rawValue)-\(request.artistName)",
                            name: request.artistName,
                            coverURL: outcome.songs.first?.coverURL,
                            source: request.source)
        }
        if outcome.songs.isEmpty { outcome.error = "未找到歌手「\(request.artistName)」" }
        return outcome
    }

    // MARK: - 专辑兜底

    private static func searchAlbums(_ request: ArtistHomeRequest, limit: Int) async -> [Album] {
        let candidates: [Album]
        switch request.source {
        case .qq:
            candidates = await call(8, { (try? await QQMusicAPI.shared.searchAlbums(keyword: request.artistName, limit: limit)) ?? [] }, fallback: [])
        case .kugou:
            candidates = await call(8, { (try? await KugouMusicAPI.shared.searchAlbums(keyword: request.artistName, limit: limit)) ?? [] }, fallback: [])
        case .kuwo:
            candidates = await call(8, { (try? await AdditionalCatalogSearchAPI.searchKuwoAlbums(keyword: request.artistName, limit: limit)) ?? [] }, fallback: [])
        case .migu:
            candidates = await call(8, { (try? await AdditionalCatalogSearchAPI.searchMiguAlbums(keyword: request.artistName, limit: limit)) ?? [] }, fallback: [])
        case .netease:
            candidates = await call(8, { (try? await NetEaseAPI.shared.searchAlbums(keyword: request.artistName, limit: limit)) ?? [] }, fallback: [])
        case .qishui:
            candidates = await call(8, { (try? await QishuiAPI.shared.artistAlbums(name: request.artistName, limit: limit)) ?? [] }, fallback: [])
        case .bilibili:
            candidates = await call(8, { (try? await BilibiliAPI.shared.searchAlbums(keyword: request.artistName, limit: limit)) ?? [] }, fallback: [])
        case .webdav:
            candidates = []
        }
        let expected = normalizedName(request.artistName)
        guard !expected.isEmpty else { return Array(candidates.prefix(limit)) }
        let matched = candidates.filter { album in
            let albumArtist = normalizedName(album.artistName)
            return !albumArtist.isEmpty && (albumArtist.contains(expected) || expected.contains(albumArtist))
        }
        return Array((matched.isEmpty ? candidates : matched).prefix(limit))
    }

    // MARK: - 名称归一

    static func creditedSongs(_ songs: [Song], name: String, artist: Artist?) -> [Song] {
        let expected = Set([name, artist?.name].compactMap { $0 }.flatMap(tokens))
        guard !expected.isEmpty else { return songs }
        let matched = songs.filter { song in
            !expected.isDisjoint(with: Set(tokens(song.artists)))
        }
        return matched.isEmpty ? songs : matched
    }

    private static func tokens(_ value: String) -> [String] {
        let separators = CharacterSet(charactersIn: "/／,，、&＆+＋|｜;；")
        return value.components(separatedBy: separators).map(normalizedName).filter { !$0.isEmpty }
    }

    static func normalizedName(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
            .replacingOccurrences(of: #"[(].*?[)]"#, with: "", options: .regularExpression)
            .filter { !$0.isWhitespace && !$0.isPunctuation }
    }
}
