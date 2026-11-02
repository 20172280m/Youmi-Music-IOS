import Foundation
import UIKit

/// 系统正在播放（锁屏 / 控制中心 / 灵动岛）最后一次交给系统的内容。
/// 模拟器不画锁屏播放器，只能靠这份读数证明「信息确实写进去了」，
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
    /// 卡片上会出现的封面：真封面拿不到时就是那张中性占位图。
    let artworkImage: UIImage?
    let artworkSize: CGSize
    let animatedArtwork: Int

    var artworkText: String {
        let size = "\(Int(artworkSize.width))×\(Int(artworkSize.height))"
        return animatedArtwork > 0 ? "\(size) · 动态 \(animatedArtwork) 项" : size
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
