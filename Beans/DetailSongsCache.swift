import Foundation

/// 持久化详情页歌曲缓存。
/// 详情页优先展示上次成功加载的内容，过期后在后台静默刷新，避免每次进入都先显示转圈。
final class DetailSongsCache {

    static let shared = DetailSongsCache()

    struct Entry: Codable {
        let songs: [Song]
        let savedAt: Date
    }

    private let defaults: UserDefaults
    private let storageKey = "beans.detailSongsCache.v1"
    private let fileName = "BeansDetailSongsCache.v1.json"
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private let persistenceQueue = DispatchQueue(
        label: "Beans.DetailSongsCache.persistence",
        qos: .utility
    )
    private var entries: [String: Entry]

    /// 详情缓存保留 30 分钟；过期后仍先展示旧内容，再静默请求最新数据。
    let ttl: TimeInterval = 30 * 60

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = BeansCacheFile.load([String: Entry].self, from: fileName) {
            entries = stored
        } else {
            entries = defaults.data(forKey: storageKey)
                .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
            migrateLegacy()
        }
    }

    static func diskBytes() -> Int64 { BeansCacheFile.bytes("BeansDetailSongsCache.v1.json") }

    /// 旧版把这份缓存存偏好里：先写文件、写成功再删旧键；迁移期间读缓存走内存里的旧数据。
    private func migrateLegacy() {
        let snapshot: [String: Entry]
        lock.lock()
        snapshot = entries
        lock.unlock()
        guard !snapshot.isEmpty else { return }
        let name = fileName
        let key = storageKey
        persistenceQueue.async { [defaults] in
            guard BeansCacheFile.write(snapshot, to: name) else { return }
            defaults.removeObject(forKey: key)
        }
    }

    func cachedSongs(for key: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[key]
    }

    /// 返回详情页缓存中的歌曲，供启动预加载复用已经访问过的封面。
    func allCachedSongs() -> [Song] {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.flatMap(\.songs)
    }

    func save(_ songs: [Song], for key: String) {
        guard !songs.isEmpty else { return }
        lock.lock()
        entries[key] = Entry(songs: songs, savedAt: Date())
        let snapshot = entries
        let token = generation
        lock.unlock()
        persistAsync(snapshot, token: token)
    }

    func isFresh(_ entry: Entry, now: Date = Date()) -> Bool {
        now.timeIntervalSince(entry.savedAt) < ttl
    }

    private func persistAsync(_ value: [String: Entry], token: UInt64) {
        let name = fileName
        // 编码和落盘都在锁外：锁只保护内存字典，主线程读缓存才不会排在编码后面。
        persistenceQueue.async { [self] in
            lock.lock()
            let current = generation
            lock.unlock()
            guard current == token else { return }
            BeansCacheFile.write(value, to: name)
        }
    }

    /// Invalidates queued pre-clear snapshots before removing only this cache's payload.
    func clearCache() {
        lock.lock()
        generation &+= 1
        entries.removeAll()
        lock.unlock()
        // 删文件在锁外做；不再碰偏好。
        BeansCacheFile.remove(fileName)
    }

    func waitForPendingWrites() { persistenceQueue.sync {} }

}
