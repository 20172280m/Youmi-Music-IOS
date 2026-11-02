import Foundation

/// 系统正在播放（锁屏 / 控制中心 / 灵动岛）最后一次交给系统的内容。
/// 模拟器不显示锁屏播放器，只能靠这份读数证明「信息确实写进去了」，
/// 因此它同时是诊断页「系统正在播放」那一块的数据源。
struct NowPlayingSnapshot {
    let date: Date
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let elapsed: Double
    let rate: Double
    let state: String
    let artwork: String
    let animatedArtwork: Int

    var artworkText: String {
        animatedArtwork > 0 ? "\(artwork) + 动态 \(animatedArtwork) 项" : artwork
    }
}

enum NowPlayingDiagnostics {
    private(set) static var last: NowPlayingSnapshot?
    private(set) static var lastClearedAt: Date?

    static func record(_ snapshot: NowPlayingSnapshot) {
        last = snapshot
        lastClearedAt = nil
    }

    static func recordCleared() {
        last = nil
        lastClearedAt = Date()
    }
}
