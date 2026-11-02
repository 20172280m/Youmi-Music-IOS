import MediaPlayer
import UIKit

/// 锁屏 / 控制中心拿不到封面时的中性占位图。
/// Colo 2026-11-02 定：beansCard 底色、正中一枚 music.note、符号高度约边长的三分之一、
/// 图上不带圆角和描边（系统自己会裁），图本身 1024×1024，放大到整宽也不糊。
enum NowPlayingFallbackArtwork {
    static let side: CGFloat = 1024

    private static var cache: [String: UIImage] = [:]
    private static let cacheLock = NSLock()

    static func mediaItemArtwork(for style: UIUserInterfaceStyle) -> MPMediaItemArtwork {
        let image = self.image(for: style)
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    static func image(for style: UIUserInterfaceStyle) -> UIImage {
        let key = style == .dark ? "dark" : "light"
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cache[key] { return cached }
        let rendered = render(style: style)
        cache[key] = rendered
        return rendered
    }

    private static func render(style: UIUserInterfaceStyle) -> UIImage {
        let traits = UITraitCollection(userInterfaceStyle: style)
        let background = UIColor.beansCard.resolvedColor(with: traits)
        let foreground = glyphColor().resolvedColor(with: traits)
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: bounds.size, format: format)
        return renderer.image { context in
            background.setFill()
            context.fill(bounds)
            let configuration = UIImage.SymbolConfiguration(pointSize: side / 3, weight: .regular)
            guard let glyph = UIImage(systemName: "music.note", withConfiguration: configuration)?
                .withTintColor(foreground, renderingMode: .alwaysOriginal) else { return }
            glyph.draw(at: CGPoint(x: (side - glyph.size.width) / 2, y: (side - glyph.size.height) / 2))
        }
    }

    /// 说明文字色可以在「我的 → 外观」里改，占位图跟着走，避免和界面两套灰。
    private static func glyphColor() -> UIColor {
        if let raw = UserDefaults.standard.string(forKey: "beans.commentColorHex"),
           let custom = UIColor(hex: raw) {
            return custom
        }
        return .beansSecondary
    }
}
