import Foundation

/// 歌手主页缓存：先显示上次成功内容，再在缓存过期后静默刷新。
final class ArtistHomeCache {

    static let shared = ArtistHomeCache()

    struct Entry: Codable {
        let artist: Artist?
        let songs: [Song]
        let albums: [Album]
        let savedAt: Date
    }

    private let defaults: UserDefaults
    private let storageKey = "beans.artistHomeCache.v1"
    private let fileName = "BeansArtistHomeCache.v1.json"
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private let persistenceQueue = DispatchQueue(label: "Beans.ArtistHomeCache.persistence", qos: .utility)
    private var entries: [String: Entry]

    /// 歌手主页缓存 30 分钟有效；过期内容仍可立即展示。
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

    static func diskBytes() -> Int64 { BeansCacheFile.bytes("BeansArtistHomeCache.v1.json") }

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

    func cached(for key: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[key]
    }

    func isFresh(_ entry: Entry, now: Date = Date()) -> Bool {
        now.timeIntervalSince(entry.savedAt) < ttl
    }

    func save(artist: Artist?, songs: [Song], albums: [Album], for key: String) {
        guard !songs.isEmpty || !albums.isEmpty else { return }
        lock.lock()
        entries[key] = Entry(artist: artist, songs: songs, albums: albums, savedAt: Date())
        let token = generation
        lock.unlock()

        // 编码和落盘都不许在锁里做：主线程读缓存要过这把锁，
        // 以前整段 JSON 编码 + UserDefaults 写入都压在锁内，主线程一等就是几秒到卡死。
        let name = fileName
        persistenceQueue.async { [self] in
            lock.lock()
            let snapshot = entries
            let current = generation
            lock.unlock()
            guard current == token else { return }
            BeansCacheFile.write(snapshot, to: name)
        }
    }

    /// Invalidates queued pre-clear snapshots before removing only this cache's payload.
    func clearCache() {
        lock.lock()
        generation &+= 1
        entries.removeAll()
        lock.unlock()
        // 删文件在锁外做；不再碰偏好，清理不会被偏好进程拖住。
        BeansCacheFile.remove(fileName)
    }

    func waitForPendingWrites() { persistenceQueue.sync {} }

}
