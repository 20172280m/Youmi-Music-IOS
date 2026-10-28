import Foundation

/// 持久化缓存云端歌单列表和歌单歌曲。
/// 网络请求失败或切回音乐库时，先展示上次成功结果，再在后台刷新。
final class SyncedPlaylistCache {

    static let shared = SyncedPlaylistCache()

    struct PlaylistEntry: Codable {
        let playlists: [Playlist]
        let savedAt: Date
    }

    struct SongEntry: Codable {
        let songs: [Song]
        let savedAt: Date
    }

    private let defaults: UserDefaults
    private let playlistsKey = "beans.syncedPlaylistCache.playlists.v1"
    private let songsKey = "beans.syncedPlaylistCache.songs.v1"
    private let playlistsFile = "BeansSyncedPlaylists.v1.json"
    private let songsFile = "BeansSyncedSongs.v1.json"
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private let persistenceQueue = DispatchQueue(label: "Beans.SyncedPlaylistCache.persistence", qos: .utility)
    private var playlistEntries: [String: PlaylistEntry]
    private var songEntries: [String: SongEntry]

    /// 歌单列表缓存 15 分钟，歌曲详情缓存 30 分钟。
    let playlistTTL: TimeInterval = 15 * 60
    let songTTL: TimeInterval = 30 * 60

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = BeansCacheFile.load([String: PlaylistEntry].self, from: playlistsFile) {
            playlistEntries = stored
        } else {
            playlistEntries = defaults.data(forKey: playlistsKey)
                .flatMap { try? JSONDecoder().decode([String: PlaylistEntry].self, from: $0) } ?? [:]
        }
        if let stored = BeansCacheFile.load([String: SongEntry].self, from: songsFile) {
            songEntries = stored
        } else {
            songEntries = defaults.data(forKey: songsKey)
                .flatMap { try? JSONDecoder().decode([String: SongEntry].self, from: $0) } ?? [:]
        }
        migrateLegacy()
    }

    static func diskBytes() -> Int64 {
        BeansCacheFile.bytes("BeansSyncedPlaylists.v1.json") + BeansCacheFile.bytes("BeansSyncedSongs.v1.json")
    }

    /// 旧版把这两份缓存存偏好里：先写文件、写成功再删旧键；迁移期间读缓存走内存里的旧数据。
    private func migrateLegacy() {
        lock.lock()
        let playlists = playlistEntries
        let songs = songEntries
        lock.unlock()
        guard !playlists.isEmpty || !songs.isEmpty else { return }
        let playlistName = playlistsFile
        let songName = songsFile
        let playlistKey = playlistsKey
        let songKey = songsKey
        persistenceQueue.async { [defaults] in
            if !playlists.isEmpty, BeansCacheFile.write(playlists, to: playlistName) {
                defaults.removeObject(forKey: playlistKey)
            }
            if !songs.isEmpty, BeansCacheFile.write(songs, to: songName) {
                defaults.removeObject(forKey: songKey)
            }
        }
    }

    func cachedPlaylists(source: SongSource, accountID: String) -> PlaylistEntry? {
        lock.lock()
        defer { lock.unlock() }
        return playlistEntries[cacheKey(source: source, accountID: accountID)]
    }

    func savePlaylists(_ playlists: [Playlist], source: SongSource, accountID: String) {
        guard !playlists.isEmpty else { return }
        lock.lock()
        playlistEntries[cacheKey(source: source, accountID: accountID)] = PlaylistEntry(
            playlists: playlists,
            savedAt: Date()
        )
        let snapshot = playlistEntries
        let token = generation
        lock.unlock()
        persistAsync(snapshot, file: playlistsFile, token: token)
    }

    func cachedSongs(playlist: Playlist, accountID: String) -> SongEntry? {
        lock.lock()
        defer { lock.unlock() }
        return songEntries[cacheKey(source: playlist.source, accountID: "\(accountID)|\(playlist.id)")]
    }

    /// 返回磁盘缓存中的歌单与歌曲，启动预加载只读取快照，不触发网络请求。
    func allCachedPlaylists() -> [Playlist] {
        lock.lock()
        defer { lock.unlock() }
        return playlistEntries.values.flatMap(\.playlists)
    }

    func allCachedSongs() -> [Song] {
        lock.lock()
        defer { lock.unlock() }
        return songEntries.values.flatMap(\.songs)
    }

    func saveSongs(_ songs: [Song], playlist: Playlist, accountID: String) {
        guard !songs.isEmpty else { return }
        lock.lock()
        songEntries[cacheKey(source: playlist.source, accountID: "\(accountID)|\(playlist.id)")] = SongEntry(
            songs: songs,
            savedAt: Date()
        )
        let snapshot = songEntries
        let token = generation
        lock.unlock()
        persistAsync(snapshot, file: songsFile, token: token)
    }

    func isFresh(_ entry: PlaylistEntry, now: Date = Date()) -> Bool {
        now.timeIntervalSince(entry.savedAt) < playlistTTL
    }

    func isFresh(_ entry: SongEntry, now: Date = Date()) -> Bool {
        now.timeIntervalSince(entry.savedAt) < songTTL
    }

    func clear(source: SongSource, accountID: String) {
        lock.lock()
        let playlistKey = cacheKey(source: source, accountID: accountID)
        playlistEntries.removeValue(forKey: playlistKey)
        let songPrefix = cacheKey(source: source, accountID: "\(accountID)|")
        songEntries = songEntries.filter { !$0.key.hasPrefix(songPrefix) }
        let playlistSnapshot = playlistEntries
        let songSnapshot = songEntries
        let token = generation
        lock.unlock()
        persistAsync(playlistSnapshot, file: playlistsFile, token: token)
        persistAsync(songSnapshot, file: songsFile, token: token)
    }

    private func cacheKey(source: SongSource, accountID: String) -> String {
        let normalizedAccount = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceKey = source == .qishui ? "qishui-cover-v2" : source.rawValue
        return "\(sourceKey)|\(normalizedAccount.isEmpty ? "default" : normalizedAccount)"
    }

    private func persistAsync<T: Encodable>(_ value: T, file: String, token: UInt64) {
        // 编码和落盘都在锁外：锁只保护内存字典。
        persistenceQueue.async { [self] in
            lock.lock()
            let current = generation
            lock.unlock()
            guard current == token else { return }
            BeansCacheFile.write(value, to: file)
        }
    }

    /// Invalidates queued pre-clear snapshots before removing only this cache's payload.
    func clearCache() {
        lock.lock()
        generation &+= 1
        playlistEntries.removeAll()
        songEntries.removeAll()
        lock.unlock()
        // 删文件在锁外做；不再碰偏好。
        BeansCacheFile.remove(playlistsFile)
        BeansCacheFile.remove(songsFile)
    }

    func waitForPendingWrites() { persistenceQueue.sync {} }

}
