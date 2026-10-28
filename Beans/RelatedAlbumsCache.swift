import Foundation

/// 专辑详情页的“该歌手的其他专辑”缓存。
/// 进入页面时先展示上次成功结果，再在网络可用时静默更新，避免重复打开反复空白刷新。
final class RelatedAlbumsCache {

    static let shared = RelatedAlbumsCache()

    struct Entry: Codable {
        let albums: [Album]
        let savedAt: Date
    }

    private let defaults: UserDefaults
    private let storageKey = "beans.relatedAlbumsCache.v1"
    private let fileName = "BeansRelatedAlbumsCache.v1.json"
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private let persistenceQueue = DispatchQueue(
        label: "Beans.RelatedAlbumsCache.persistence",
        qos: .utility
    )
    private var entries: [String: Entry]

    /// 缓存 30 分钟有效；过期内容仍可先展示，随后静默刷新。
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

    static func diskBytes() -> Int64 { BeansCacheFile.bytes("BeansRelatedAlbumsCache.v1.json") }

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

    func cachedAlbums(for key: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[key]
    }

    func save(_ albums: [Album], for key: String) {
        guard !albums.isEmpty else { return }
        lock.lock()
        entries[key] = Entry(albums: albums, savedAt: Date())
        let snapshot = entries
        let token = generation
        lock.unlock()

        // 编码和落盘都在锁外：锁只保护内存字典。
        let name = fileName
        persistenceQueue.async { [self] in
            lock.lock()
            let current = generation
            lock.unlock()
            guard current == token else { return }
            BeansCacheFile.write(snapshot, to: name)
        }
    }

    func isFresh(_ entry: Entry, now: Date = Date()) -> Bool {
        now.timeIntervalSince(entry.savedAt) < ttl
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
