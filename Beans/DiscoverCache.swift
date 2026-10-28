import Foundation

/// 主页数据内存缓存：避免每次切回主页 Tab 都重新请求接口。
/// 排行榜 / 歌单广场缓存 1 小时，每日推荐缓存 6 小时；
/// 点右上角刷新会强制重新加载。
final class DiscoverCache {

    static let shared = DiscoverCache()

    /// 单个平台的主页完整数据快照
    struct Snapshot: Codable {
        var dailySongs: [Song] = []
        var newAlbums: [Album] = []
        var topArtists: [Artist] = []
        var topLists: [TopList] = []
        var personalized: [Playlist] = []
        var qqTopLists: [QQTopInfo] = []
        var kugouTopLists: [KugouTopInfo] = []
        var savedAt: Date = .distantPast

        var isEmpty: Bool {
            dailySongs.isEmpty && newAlbums.isEmpty && topArtists.isEmpty
                && topLists.isEmpty && personalized.isEmpty
                && qqTopLists.isEmpty && kugouTopLists.isEmpty
        }
    }

    /// 排行榜 / 歌单广场缓存时长（秒）
    let listTTL: TimeInterval = 3600
    /// 每日推荐缓存时长（秒，推荐内容按天更新）
    let dailyTTL: TimeInterval = 6 * 3600
    /// QQ 个性化推荐会随账号听歌行为变化，使用较短缓存避免首页长期展示旧结果。
    let qqRecommendationTTL: TimeInterval = 15 * 60

    private let storageKey = "beans.discover.cache.v2"
    private let qishuiSnapshotVersionKey = "beans.discover.cache.qishui.version"
    private let qishuiSnapshotVersion = 2
    private let defaults: UserDefaults
    private let lock = NSLock()
    private let persistenceQueue = DispatchQueue(label: "Beans.DiscoverCache.persistence", qos: .utility)
    private var generation: UInt64 = 0
    private var store: [String: Snapshot] = [:]
    /// 主页快照是几 MB 级别的数据，放在 UserDefaults 里写一次就要整份偏好文件重写，
    /// 清理时 removeObject 会被写盘队列拖住（一键清理卡死的根因）。改存到 Caches 下的文件。
    private let cachesRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    private var storageURL: URL { cachesRoot.appendingPathComponent("BeansDiscoverCache.v2.json") }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let legacyData = defaults.data(forKey: storageKey)
        let storedVersion = defaults.integer(forKey: qishuiSnapshotVersionKey)
        defaults.set(qishuiSnapshotVersion, forKey: qishuiSnapshotVersionKey)
        if let data = Self.fileData(at: storageURL), let snapshots = try? JSONDecoder().decode([String: Snapshot].self, from: data) {
            store = snapshots
        } else if let legacyData, let snapshots = try? JSONDecoder().decode([String: Snapshot].self, from: legacyData) {
            store = snapshots
            migrate(legacySnapshot: snapshots)
        }
        if storedVersion != qishuiSnapshotVersion {
            store.removeValue(forKey: SearchProvider.qishui.rawValue)
            defaults.set(qishuiSnapshotVersion, forKey: qishuiSnapshotVersionKey)
            persist(store, token: 0)
        }
    }

    static func diskBytes() -> Int64 {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = root.appendingPathComponent("BeansDiscoverCache.v2.json")
        return (try? BeansCacheFiles.fileBytes(url, under: root)) ?? 0
    }

    private static func fileData(at url: URL) -> Data? {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        guard (try? BeansCacheFiles.isRegularFile(url, under: root)) == true else { return nil }
        return try? Data(contentsOf: url)
    }

    /// 迁移幂等：先写新文件，写成功才删旧键；迁移期间读缓存用内存里已解出的旧数据。
    /// 写盘和后台刷新共用同一个串行队列，不会两条路同时写同一个路径。
    private func migrate(legacySnapshot: [String: Snapshot]) {
        let url = storageURL
        persistenceQueue.async { [self] in
            guard let data = try? JSONEncoder().encode(legacySnapshot) else { return }
            do { try data.write(to: url, options: .atomic) } catch { return }
            defaults.removeObject(forKey: storageKey)
        }
    }

    func cached(for source: SearchProvider) -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        return store[source.rawValue]
    }

    func save(_ snapshot: Snapshot, for source: SearchProvider) {
        lock.lock()
        store[source.rawValue] = snapshot
        let copy = store
        let token = generation
        lock.unlock()
        persist(copy, token: token)
    }

    /// 登录账号发生变化时清除该平台的主页快照，避免匿名或旧账号的每日推荐被继续复用。
    func invalidate(_ source: SearchProvider) {
        lock.lock()
        store.removeValue(forKey: source.rawValue)
        let copy = store
        let token = generation
        lock.unlock()
        persist(copy, token: token)
    }

    /// 编码和落盘都在锁外、串行排队：主线程读缓存不会被整份 JSON 编码挡住。
    private func persist(_ snapshot: [String: Snapshot], token: UInt64) {
        let url = storageURL
        persistenceQueue.async { [self] in
            // 清理之后排队中的旧快照不许再写回去。
            lock.lock()
            let current = generation
            lock.unlock()
            guard current == token else { return }
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 返回当前进程中已经加载过的主页快照，供启动预加载复用已有封面地址。
    func allSnapshots() -> [Snapshot] {
        lock.lock()
        defer { lock.unlock() }
        return Array(store.values)
    }

    /// 缓存是否仍然新鲜：每日推荐单独放宽到 6 小时，其余按 1 小时
    func isFresh(_ snapshot: Snapshot, source: SearchProvider? = nil) -> Bool {
        let age = Date().timeIntervalSince(snapshot.savedAt)
        if source == .qq { return age < qqRecommendationTTL }
        let ttl = snapshot.dailySongs.isEmpty ? listTTL : dailyTTL
        return age < ttl
    }

    func clearCache() {
        lock.lock()
        generation &+= 1
        store.removeAll()
        lock.unlock()
        // 文件删除在锁外做，主线程读缓存不会被 IO 挡住。
        try? BeansCacheFiles.removeFile(storageURL, under: cachesRoot)
        // qishuiSnapshotVersionKey is a migration marker, not cached content.
    }

}
