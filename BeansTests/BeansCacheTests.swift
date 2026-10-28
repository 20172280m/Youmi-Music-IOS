import XCTest
@testable import Beans

final class BeansCacheStorageTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("BeansCacheTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "BeansCacheTests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }
    private func write(_ path: String, count: Int = 7) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: count).write(to: url)
        return url
    }
    private var song: Song { Song(id: 1, name: "Cached", artists: "Artist", album: "Album", coverURL: nil, duration: 1) }

    func testImageCategoryPreservesUserContentAndOtherCategories() async throws {
        let cover = try write("BeansCoverImageFiles/a")
        let rank = try write("BeansRankCoverFiles/a")
        let protected = try ["Fonts/a.ttf", "LocalMusic/song.mp3", "Downloads/song.mp3", "CustomCovers/a.jpg",
                             "Wallpaper/a.jpg", "BeansLockScreenArtwork/a.mp4", "BeansLogs/a.log"].map { try write($0) }
        defaults.set("account", forKey: "beans.user")
        defaults.set(Data([1]), forKey: "beans.lyrics.cache.v1.a")
        let worker = BeansCacheWorker(cachesRoot: root, defaults: defaults, networkCache: URLCache(memoryCapacity: 0, diskCapacity: 0, diskPath: nil))
        let measured = try await worker.measure(.images)
        XCTAssertEqual(measured.diskBytes, 14)
        XCTAssertNil(measured.memoryBytes)
        try await worker.clear(.images)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cover.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rank.path))
        for file in protected { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), file.path) }
        XCTAssertEqual(defaults.string(forKey: "beans.user"), "account")
        XCTAssertNotNil(defaults.data(forKey: "beans.lyrics.cache.v1.a"))
    }

    func testMissingDirectoryIsIdempotentAndMeasurementCreatesNothing() throws {
        let missing = root.appendingPathComponent("BeansCoverImageFiles")
        XCTAssertEqual(try BeansCacheFiles.bytes(in: missing, under: root), 0)
        try BeansCacheFiles.clearContents(of: missing, under: root)
        try BeansCacheFiles.clearContents(of: missing, under: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testSymlinkChildrenAreNotCountedOrFollowedAndRootLinkIsRejected() throws {
        let outside = try write("UserData/keep", count: 101)
        let cache = root.appendingPathComponent("BeansCoverImageFiles")
        _ = try write("BeansCoverImageFiles/real", count: 3)
        let link = cache.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.deletingLastPathComponent())
        XCTAssertEqual(try BeansCacheFiles.bytes(in: cache, under: root), 3)
        try BeansCacheFiles.clearContents(of: cache, under: root)
        XCTAssertEqual(try Data(contentsOf: outside).count, 101)
        try FileManager.default.removeItem(at: cache)
        try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: outside.deletingLastPathComponent())
        XCTAssertThrowsError(try BeansCacheFiles.bytes(in: cache, under: root))
        XCTAssertThrowsError(try BeansCacheFiles.clearContents(of: cache, under: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testUnexpectedFileAtDirectoryReportsFailure() throws {
        let file = try write("BeansCoverImageFiles")
        XCTAssertThrowsError(try BeansCacheFiles.bytes(in: file, under: root))
        XCTAssertThrowsError(try BeansCacheFiles.clearContents(of: file, under: root))
    }

    func testDefaultsAllowlistCategoryIsolationAndEncodedPayloadSize() throws {
        let preserved = ["beans.user", "beans.localLibrary.playlists", "beans.favorites", "beans.history",
                         "beans.profile.customAvatarPath", "beans.discover.cache.qishui.version", "beans.font",
                         "beans.playlistSquare.cache.v99.netease.guest.all", "beans.lyrics.setting"]
        preserved.forEach { defaults.set("keep", forKey: $0) }
        BeansCacheDefaults.metadataKeys.forEach { defaults.set(Data([1, 2, 3]), forKey: $0) }
        let square = "beans.playlistSquare.cache.v5.netease.guest.all"
        XCTAssertTrue(BeansCacheDefaults.isPlaylistSquareKey(square))
        defaults.set(Data([4, 5]), forKey: square)
        defaults.set(Data([6, 7, 8, 9]), forKey: "beans.lyrics.cache.v1.song")
        XCTAssertEqual(BeansCacheDefaults.payloadBytes(in: defaults, category: .metadata), Int64(BeansCacheDefaults.metadataKeys.count * 3 + 2))
        XCTAssertEqual(BeansCacheDefaults.payloadBytes(in: defaults, category: .lyrics), 4)
        BeansCacheDefaults.clear(.metadata, in: defaults)
        XCTAssertEqual(BeansCacheDefaults.payloadBytes(in: defaults, category: .metadata), 0)
        XCTAssertNotNil(defaults.data(forKey: "beans.lyrics.cache.v1.song"))
        BeansCacheDefaults.clear(.lyrics, in: defaults)
        for key in preserved { XCTAssertEqual(defaults.string(forKey: key), "keep", key) }
    }

    func testMetadataClearDropsInMemoryAndQueuedPreClearSnapshots() throws {
        let detail = DetailSongsCache(defaults: defaults)
        let artist = ArtistHomeCache(defaults: defaults)
        let related = RelatedAlbumsCache(defaults: defaults)
        let synced = SyncedPlaylistCache(defaults: defaults)
        let discover = DiscoverCache(defaults: defaults)
        let playlist = Playlist(id: 1, name: "Cached", coverURL: nil)
        let album = Album(id: "a", name: "Album", artistName: "Artist", coverURL: nil, source: .netease, trackCount: 1)
        for i in 0..<50 {
            detail.save([song], for: "\(i)")
            artist.save(artist: nil, songs: [song], albums: [], for: "\(i)")
            related.save([album], for: "\(i)")
            synced.savePlaylists([playlist], source: .netease, accountID: "a")
            synced.saveSongs([song], playlist: playlist, accountID: "a")
        }
        discover.save(DiscoverCache.Snapshot(), for: .netease)
        detail.clearCache(); artist.clearCache(); related.clearCache(); synced.clearCache(); discover.clearCache()
        detail.waitForPendingWrites(); artist.waitForPendingWrites(); related.waitForPendingWrites(); synced.waitForPendingWrites()
        XCTAssertNil(detail.cachedSongs(for: "0"))
        XCTAssertNil(artist.cached(for: "0"))
        XCTAssertNil(related.cachedAlbums(for: "0"))
        XCTAssertTrue(synced.allCachedPlaylists().isEmpty)
        XCTAssertTrue(synced.allCachedSongs().isEmpty)
        XCTAssertTrue(discover.allSnapshots().isEmpty)
        for key in BeansCacheDefaults.metadataKeys { XCTAssertNil(defaults.object(forKey: key), key) }
        XCTAssertEqual(defaults.integer(forKey: "beans.discover.cache.qishui.version"), 2)
        // New, intentional post-clear saves still work.
        detail.save([song], for: "new")
        detail.waitForPendingWrites()
        XCTAssertNotNil(DetailSongsCache(defaults: defaults).cachedSongs(for: "new"))
    }

    func testRetainedArtworkSurvivesUntilLeaseRelease() async throws {
        let source = try write("CustomCovers/source.jpg")
        let directory = root.appendingPathComponent("BeansLockScreenArtwork")
        let store = BeansLockScreenVideoStore(directory: directory)
        let retained = try await store.retain(source: source, identifier: "playing")
        let unused = try write("BeansLockScreenArtwork/unused.mp4")
        try await store.clearUnused()
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unused.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        await store.release(identifier: "playing")
        try await store.clearUnused()
        XCTAssertFalse(FileManager.default.fileExists(atPath: retained.path))
    }

    func testLoggerClearSerializesOldWritesAndFailureThrows() async throws {
        let directory = root.appendingPathComponent("BeansLogs")
        let logger = BeansLogger(directory: directory, logStartup: false)
        for i in 0..<50 { logger.log("old \(i)") }
        try await logger.clearCache()
        let bytes = try await logger.cacheDiskBytes()
        XCTAssertEqual(bytes, 0)
        XCTAssertTrue(logger.fullText.isEmpty)
        logger.log("new")
        let newBytes = try await logger.cacheDiskBytes()
        XCTAssertGreaterThan(newBytes, 0)
        let invalid = try write("NotADirectory")
        let failing = BeansLogger(directory: invalid, logStartup: false)
        do { try await failing.clearCache(); XCTFail("Must throw, not report success") }
        catch { /* expected */ }
    }
}

@MainActor
final class BeansCacheManagerTests: XCTestCase {
    func testFailureAndSkipRemainVisibleAfterRefreshAndUnknownMemoryStaysNil() async {
        let manager = BeansCacheManager(operations: .init(measure: { category in
            if category == .logs { throw CocoaError(.fileReadNoPermission) }
            return BeansCacheUsage(category: category, diskBytes: 10, memoryBytes: nil)
        }, clear: { category in
            if category == .images { throw CocoaError(.fileWriteNoPermission) }
            if category == .bilibili { return "Bilibili retained during playback" }
            return nil
        }))
        await manager.clear([.images, .bilibili])
        XCTAssertFalse(manager.working)
        XCTAssertTrue(manager.message?.contains("Bilibili retained") == true)
        XCTAssertGreaterThanOrEqual(manager.message?.components(separatedBy: "\n").count ?? 0, 3)
        XCTAssertNil(manager.usage.first { $0.category == .logs })
        XCTAssertEqual(manager.usage.count, 6)
        XCTAssertTrue(manager.usage.allSatisfy { $0.memoryBytes == nil })
    }

    func testSevenStableCategoriesAndPayloadEstimates() {
        XCTAssertEqual(BeansCacheCategory.allCases.map(\.rawValue), ["images", "immersive", "metadata", "lyrics", "network", "bilibili", "logs"])
        XCTAssertTrue(BeansCacheUsage(category: .metadata, diskBytes: 1, memoryBytes: nil).isDefaultsPayloadEstimate)
        XCTAssertFalse(BeansCacheUsage(category: .images, diskBytes: 1, memoryBytes: nil).isDefaultsPayloadEstimate)
    }
}
