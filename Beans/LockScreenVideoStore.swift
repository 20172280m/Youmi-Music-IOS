import AVFoundation
import CryptoKit
import Foundation

/// Produces silent square and portrait movies; files remain valid after the source cover is replaced.
actor BeansLockScreenVideoStore {
    static let shared = BeansLockScreenVideoStore()
    private var pending: [String: Task<URL, Error>] = [:]
    private var retained: [String: Int] = [:]
    private var files: [String: Set<URL>] = [:]
    private var pendingRetains = 0
    private let directory: URL

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BeansLockScreenArtwork", isDirectory: true)) {
        self.directory = directory
    }

    func cacheDiskBytes() throws -> Int64 {
        try BeansCacheFiles.bytes(in: directory, under: directory.deletingLastPathComponent())
    }

    func retain(source: URL, identifier: String) async throws -> URL {
        pendingRetains += 1
        defer { pendingRetains -= 1 }
        _ = try BeansCacheFiles.validateDirectory(directory, under: directory.deletingLastPathComponent())
        let key = SHA256.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined()
        let target = directory.appendingPathComponent("source-" + key).appendingPathExtension(source.pathExtension.isEmpty ? "jpg" : source.pathExtension)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: target.path) {
            if source.isFileURL { try FileManager.default.copyItem(at: source, to: target) }
            else {
                let (data, response) = try await URLSession.shared.data(from: source)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      data.count <= 12 * 1024 * 1024 else { throw CustomSongCoverError.invalidMedia }
                try data.write(to: target, options: .atomic)
            }
        }
        retained[identifier, default: 0] += 1
        files[identifier, default: []].insert(target)
        return target
    }

    func release(identifier: String) {
        retained[identifier] = max(0, (retained[identifier] ?? 1) - 1)
    }

    /// Only generated assets with no artwork lease may be removed.
    func clearUnused() throws {
        // A retain may be suspended downloading a source; leave its files alone as well.
        guard pending.isEmpty, pendingRetains == 0 else { return }
        let protected = Set(files.filter { (retained[$0.key] ?? 0) > 0 }.flatMap { $0.value })
        try BeansCacheFiles.clearContents(of: directory, under: directory.deletingLastPathComponent(), retaining: protected)
        BeansLogger.shared.log("锁屏素材清理：保留 \(protected.count) 个文件", level: .debug)

    }

    func video(source: URL, identifier: String, size: CGSize) async throws -> URL {
        let key = SHA256.hash(data: Data((identifier + "|\(size.width)x\(size.height)").utf8))
            .map { String(format: "%02x", $0) }.joined()
        let target = directory.appendingPathComponent(key).appendingPathExtension("mp4")
        files[identifier, default: []].insert(target)
        if FileManager.default.fileExists(atPath: target.path) { return target }
        if let task = pending[key] { return try await task.value }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let task = Task<URL, Error> {
            if CustomCoverMedia.kind(for: source) != .video {
                try await BeansLockScreenImageMovie.write(source: source, target: target, size: size)
                return target
            }
            let asset = AVURLAsset(url: source)
            guard let original = try await asset.loadTracks(withMediaType: .video).first else { throw CustomSongCoverError.invalidMedia }
            let duration = try await asset.load(.duration)
            guard duration.seconds.isFinite, duration.seconds > 0 else { throw CustomSongCoverError.invalidMedia }
            let naturalSize = try await original.load(.naturalSize)
            let preferred = try await original.load(.preferredTransform)
            let bounds = CGRect(origin: .zero, size: naturalSize).applying(preferred)
            let scale = max(size.width / max(1, bounds.width), size.height / max(1, bounds.height))
            var transform = preferred.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
            transform = transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
            transform = transform.concatenating(CGAffineTransform(translationX: (size.width - bounds.width * scale) / 2,
                                                                   y: (size.height - bounds.height * scale) / 2))
            let composition = AVMutableComposition()
            guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw CustomSongCoverError.invalidMedia }
            let clipDuration = min(duration.seconds, 29)
            let range = CMTimeRange(start: .zero, duration: CMTime(seconds: clipDuration, preferredTimescale: 600))
            try track.insertTimeRange(range, of: original, at: .zero)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            layer.setTransform(transform, at: .zero)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = range; instruction.layerInstructions = [layer]
            let videoComposition = AVMutableVideoComposition()
            videoComposition.instructions = [instruction]
            videoComposition.renderSize = size
            videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
            guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { throw CustomSongCoverError.invalidMedia }
            exporter.videoComposition = videoComposition
            let temporary = target.deletingLastPathComponent().appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try await exporter.export(to: temporary, as: .mp4)
            try FileManager.default.moveItem(at: temporary, to: target)
            return target
        }
        pending[key] = task
        defer { pending.removeValue(forKey: key) }
        return try await task.value
    }
}
