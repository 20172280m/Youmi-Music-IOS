import Combine
import Foundation
import CiliCiliKit

enum BeansCacheCategory: String, CaseIterable, Identifiable, Sendable {
    case images, immersive, metadata, lyrics, network, bilibili, logs
    var id: String { rawValue }
    var title: String {
        switch self {
        case .images: return "图片缓存"
        case .immersive: return "沉浸媒体缓存"
        case .metadata: return "页面数据缓存"
        case .lyrics: return "歌词缓存"
        case .network: return "网络缓存"
        case .bilibili: return "哔哩哔哩缓存"
        case .logs: return "诊断日志"
        }
    }
}

struct BeansCacheUsage: Identifiable, Sendable {
    let category: BeansCacheCategory
    /// Logical file lengths / URLCache-reported disk usage. For defaults this is encoded payload only.
    let diskBytes: Int64
    /// nil means unmeasurable, not zero (in particular decoded NSCache images).
    let memoryBytes: Int64?
    var id: String { category.rawValue }
    var isDefaultsPayloadEstimate: Bool { category == .metadata || category == .lyrics }
}

/// UI-facing serialized operation owner. No recursive disk work runs on the main actor.
@MainActor
final class BeansCacheManager: ObservableObject {
    @Published private(set) var usage: [BeansCacheUsage] = []
    @Published private(set) var working = false
    @Published private(set) var message: String?

    struct Operations {
        var measure: (BeansCacheCategory) async throws -> BeansCacheUsage
        /// A returned note describes retained/skipped resources, not an error.
        var clear: (BeansCacheCategory) async throws -> String?
    }
    private let operations: Operations
    var totalDiskBytes: Int64 { usage.reduce(0) { $0 + $1.diskBytes } }

    init(operations: Operations? = nil) {
        self.operations = operations ?? .live
    }

    func refresh() async {
        guard !working else { return }
        working = true
        defer { working = false }
        message = nil
        let failures = await collectUsage()
        if !failures.isEmpty { message = failures.joined(separator: "\n") }
    }

    func clear(_ categories: [BeansCacheCategory]) async {
        guard !working else { return }
        working = true
        defer { working = false }
        BeansDiagnostics.shared.recordTap(categories.count == BeansCacheCategory.allCases.count ? "清理全部缓存" : "清理缓存")
        var notes: [String] = []
        var cleared = 0
        for category in BeansCacheCategory.allCases where categories.contains(category) {
            if Task.isCancelled { notes.append(beansLocalized("清理已取消，部分缓存可能已清除。", "Cancelled; some caches may already have been cleared.")); break }
            do {
                if let note = try await operations.clear(category) { notes.append(note) }
                else { cleared += 1 }
            } catch {
                notes.append("\(localizedTitle(category))：\(beansLocalized("分类缓存清理失败", "Category cache clear failed")) — \(error.localizedDescription)")
            }
        }
        // Refresh directly, not through the public working guard, and never erase clear failures.
        notes += await collectUsage(failureHeadline: beansLocalized("清理后统计失败", "Measurement failed after clearing"))
        if notes.isEmpty, cleared > 0 {
            notes.append(beansLocalized("所选缓存已清理；使用时可能重新生成。", "Selected caches cleared; they may be regenerated during use."))
        }
        message = notes.isEmpty ? nil : notes.joined(separator: "\n")
    }

    private func collectUsage(failureHeadline: String = beansLocalized("缓存统计失败", "Cache measurement failed")) async -> [String] {
        var measured: [BeansCacheUsage] = []
        var failures: [String] = []
        for category in BeansCacheCategory.allCases {
            if Task.isCancelled { break }
            do { measured.append(try await operations.measure(category)) }
            catch { failures.append("\(localizedTitle(category))：\(failureHeadline) — \(error.localizedDescription)") }
        }
        // Failed measurements are absent/unknown, never silently replaced by zero or stale numbers.
        usage = measured
        return failures
    }

    private func localizedTitle(_ category: BeansCacheCategory) -> String {
        NSLocalizedString(category.title, comment: "Cache category")
    }
}

@MainActor
private extension BeansCacheManager.Operations {
    static var live: Self {
        let worker = BeansCacheWorker()
        return Self(measure: { category in
            if category == .bilibili {
                let stats = await CiliCiliRuntime.shared.resourceCacheUsage()
                return BeansCacheUsage(category: category, diskBytes: Int64(max(0, stats.disk)), memoryBytes: Int64(max(0, stats.memory)))
            }
            return try await worker.measure(category)
        }, clear: { category in
            switch category {
            case .bilibili:
                let runtime = CiliCiliRuntime.shared
                guard !runtime.isVideoDetailActive, !runtime.isLiveRoomActive, !CiliCiliRuntime.hasActivePlayback else {
                    return beansLocalized("哔哩哔哩视频或直播使用中，已跳过清理。", "Bilibili video or live playback is active; clearing was skipped.")
                }
                await runtime.clearResourceCaches()
                return beansLocalized("已请求清理哔哩哔哩资源并刷新统计；框架不提供删除结果，无法确认全部清除。", "Bilibili resource clearing requested and usage refreshed; the framework does not report deletion results, so complete removal cannot be confirmed.")
            case .logs:
                // Breadcrumb persistence is serialized by the diagnostics owner's lock.
                BeansDiagnostics.shared.clearCachedState()
                try await worker.clear(category)
                return nil
            default:
                try await worker.clear(category)
                if category == .immersive {
                    return beansLocalized("已清理未使用的沉浸媒体；正在使用的资源会保留。", "Unused immersive media cleared; resources in use are retained.")
                }
                return nil
            }
        })
    }
}

/// Actor keeps defaults encoding and allowlisted file operations off the UI executor.
actor BeansCacheWorker {
    private let cachesRoot: URL
    private let defaults: UserDefaults
    private let networkCache: URLCache
    private let injected: Bool

    init(cachesRoot: URL? = nil, defaults: UserDefaults = .standard, networkCache: URLCache = .shared) {
        self.cachesRoot = cachesRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.defaults = defaults
        self.networkCache = networkCache
        self.injected = cachesRoot != nil
    }

    func measure(_ category: BeansCacheCategory) async throws -> BeansCacheUsage {
        var disk: Int64 = 0
        var memory: Int64?
        switch category {
        case .images:
            if injected {
                disk = try directoryBytes("BeansCoverImageFiles")
            } else {
                disk = try await BeansCoverImageStore.cacheUsage().disk
            }
            disk += try directoryBytes("BeansRankCoverFiles")
        case .immersive:
            guard !injected else { throw CocoaError(.fileReadUnknown) }
            disk = try await BeansLockScreenVideoStore.shared.cacheDiskBytes()
        case .metadata:
            disk = BeansCacheDefaults.payloadBytes(in: defaults, category: category)
            disk += DiscoverCache.diskBytes()
            disk += ArtistHomeCache.diskBytes()
            disk += DetailSongsCache.diskBytes()
            disk += RelatedAlbumsCache.diskBytes()
            disk += SyncedPlaylistCache.diskBytes()
        case .lyrics:
            disk = BeansCacheDefaults.payloadBytes(in: defaults, category: category)
        case .network:
            disk = Int64(networkCache.currentDiskUsage)
            // WebDAV 音乐缓存归「网络」类，不单开一类。
            disk += (try? directoryBytes("BeansWebDAVAudio")) ?? 0
            memory = Int64(networkCache.currentMemoryUsage)
        case .logs:
            guard !injected else { throw CocoaError(.fileReadUnknown) }
            disk = try await BeansLogger.shared.cacheDiskBytes()
            disk += try await BilibiliDetailDiagnostics.cacheDiskBytes()
        case .bilibili: throw CocoaError(.fileReadUnknown)
        }
        return BeansCacheUsage(category: category, diskBytes: disk, memoryBytes: memory)
    }

    func clear(_ category: BeansCacheCategory) async throws {
        switch category {
        case .images:
            if injected { try clearDirectory("BeansCoverImageFiles") }
            else {
                let success = await withCheckedContinuation { continuation in
                    BeansCoverImageStore.clearCache { continuation.resume(returning: $0) }
                }
                guard success else { throw CocoaError(.fileWriteUnknown) }
                BeansImageFileCache.removeAll() // Decoded previews only, never custom media files.
            }
            try clearDirectory("BeansRankCoverFiles")
        case .immersive:
            guard !injected else { throw CocoaError(.fileWriteUnknown) }
            try await BeansLockScreenVideoStore.shared.clearUnused()
        case .metadata:
            if !injected {
                DiscoverCache.shared.clearCache()
                ArtistHomeCache.shared.clearCache()
                DetailSongsCache.shared.clearCache()
                SyncedPlaylistCache.shared.clearCache()
                RelatedAlbumsCache.shared.clearCache()
                PlaylistSquareCache.shared.clearCache()
            }
            BeansCacheDefaults.clear(category, in: defaults)
        case .lyrics:
            if !injected { LyricsCache.shared.clearCache() }
            BeansCacheDefaults.clear(category, in: defaults)
        case .network:
            networkCache.removeAllCachedResponses()
            try? clearDirectory("BeansWebDAVAudio")
        case .logs:
            guard !injected else { throw CocoaError(.fileWriteUnknown) }
            try await BeansLogger.shared.clearCache()
            try await BilibiliDetailDiagnostics.clearCache()
        case .bilibili: throw CocoaError(.fileReadUnknown)
        }
    }

    private func directoryBytes(_ name: String) throws -> Int64 {
        try BeansCacheFiles.bytes(in: cachesRoot.appendingPathComponent(name, isDirectory: true), under: cachesRoot)
    }
    private func clearDirectory(_ name: String) throws {
        try BeansCacheFiles.clearContents(of: cachesRoot.appendingPathComponent(name, isDirectory: true), under: cachesRoot)
    }
}
