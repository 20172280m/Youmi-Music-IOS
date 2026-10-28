import CoreImage
import SwiftUI
import UIKit

/// Rebuilt from the 2.0.3 reflected header fields. Exact timing and layout require device comparison.
struct BeansImmersiveDetailHeader: View {
    static let enabledKey = "beans.immersiveDetail.enabled"
    let coverURL: URL?
    let title: String
    var subtitle = ""
    var metadata = ""
    var descriptionText: String?
    var portrait = false
    var coverSize: CGFloat = 240
    var titleSize: CGFloat = 28
    /// 0 = 完全展开，1 = 头部完全收起。封面缩放、文字淡出都用它，连续无分段。
    var collapseProgress: CGFloat = 0
    /// 页面自己算好的封面取色；给了就用它，保证整页和头部是同一个颜色。
    var paletteOverride: Color?
    /// 把实测头部高度回传给页面，收起距离按它算。
    var onHeightChange: ((CGFloat) -> Void)?
    var onSubtitle: (() -> Void)?
    var onPlayAll: (() -> Void)?
    /// 播放全部一律用主题色；封面取色只给渐变底和阴影，不进按钮。
    var playAllTint: Color?
    /// 封面取色回传：顶部底材要和头部顶沿同一个颜色，不能一白一棕硬接。
    var onPalette: ((Color) -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var expanded = false
    @State private var palette = Color.beansAmber

    var body: some View {
        VStack(spacing: 16) {
            GeometryReader { proxy in
                // 尺寸直接跟着进度缩，不再用 scaleEffect 缩放：槽位高 = 封面缩放后的高，
                // 缩放过的图如果在固定尺寸的槽位里，多出来的那截会溢出槽位（实测滚到一半，
                // 一小截封面落到头部带子外面、穿过半透明的搜索框）。
                CoverImage(url: coverURL, size: min(proxy.size.width, coverSize * (1 - 0.64 * collapseProgress)),
                           cornerRadius: portrait ? 120 : 22)
                    // p 0.7→1 封面淡出，到终点已经看不见，不会压到导航栏或列表上。
                    .opacity(Double(collapseProgress < 0.7 ? 1 : max(0, 1 - (collapseProgress - 0.7) / 0.3)))
                    .frame(maxWidth: .infinity)
                    // 阴影要没有清晰边界：半径小、透明度低的扩散，只在封面外缘透出一点；
                    // 之前 24 半径、0.32 会在圆封面外圈出一个比它大一圈的浅色圆盘。
                    .shadow(color: palette.opacity(0.08), radius: 20, y: 6)
            }.frame(height: coverSize * (1 - 0.64 * collapseProgress))
            Text(title).font(BeansFont.appFont(titleSize, .semibold)).multilineTextAlignment(.center)
                // p 到 0.65 名字已经看不见，导航栏标题正好从这一刻开始淡入，一屏只有一个标题。
                // 头部在收起时会被自己的裁剪带上沿切过，文字必须在切口扫到之前就完全透明，
                // 否则会出现被横切一半的字行。p 0.3 淡完，切口到名字上沿时（p≈0.4）早已看不见。
                .opacity(Double(max(0, 1 - collapseProgress / 0.3)))
                .accessibilityIdentifier("beans.immersive.title")
            if !subtitle.isEmpty {
                Button { onSubtitle?() } label: {
                    Text(subtitle).font(BeansFont.appFont(15, .medium)).foregroundStyle(palette)
                }.buttonStyle(.plain).disabled(onSubtitle == nil)
                    .opacity(Double(max(0, 1 - collapseProgress / 0.3)))
                    .accessibilityIdentifier("beans.immersive.subtitle")
            }
            if !metadata.isEmpty {
                Text(metadata).font(BeansFont.appFont(12)).foregroundStyle(Color.beansComment)
                    .opacity(Double(max(0, 1 - collapseProgress / 0.3)))
                    // 名字和副信息是一组：这里用 6 点，别的段位保持组件的 16。
                    .padding(.top, -10)
                    .accessibilityIdentifier("beans.immersive.metadata")
            }
            if let onPlayAll {
                Button(action: onPlayAll) {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        Text("播放全部").font(BeansFont.appFont(16, .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background((playAllTint ?? palette).opacity(0.9), in: Capsule())
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                // 按钮比文字更早退场：它的下沿比副信息低，切口扫到它时必须是透明的。
                .opacity(Double(max(0, 1 - collapseProgress / 0.22)))
                .allowsHitTesting(collapseProgress < 0.22)
                .accessibilityIdentifier("beans.immersive.playAll")
            }
            if let descriptionText, !descriptionText.isEmpty {
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85)) { expanded.toggle() }
                } label: {
                    VStack(spacing: 6) {
                        Text(descriptionText).lineLimit(expanded ? nil : 3).multilineTextAlignment(.leading)
                        Text(expanded ? "收起简介" : "展开简介").font(.caption.weight(.semibold))
                    }.foregroundStyle(Color.beansComment)
                }.buttonStyle(.plain).accessibilityIdentifier("beans.immersive.description-more")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        // 背景由页面统一铺一层（整页只有那一层渐变），头部自己不再画，避免两个视图两套时机。
        .background {
            GeometryReader { geo in
                // 只量一次：高度回传后又会改变自身 frame，随高度反复回传会形成重排循环。
                Color.clear
                    .onAppear { onHeightChange?(geo.size.height) }
            }
        }
        .accessibilityIdentifier("beans.immersive.header")
        .task(id: coverURL) { await loadPalette() }
        .onChange(of: paletteOverride) { _, newValue in
            if let newValue { palette = newValue }
        }
    }

    /// 浅色封面在深色模式下把底色压暗一档，保证白字对比度；深色封面维持原来的 0.25。
    static func topOpacity(for color: Color, colorScheme: ColorScheme) -> Double {
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
        guard colorScheme == .dark else { return luminance > 0.7 ? 0.38 : 0.30 }
        return luminance > 0.7 ? 0.30 : 0.26
    }

    private var gradientTopOpacity: Double {
        let ui = UIColor(palette)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
        // 浅色封面的主色本身很淡，压 0.14 出来几乎就是白；要能看出是“这个封面的颜色”，
        // 浅色封面给 0.38、深色封面给 0.30（深色自己就够重，压太浓会盖住文字）。
        guard colorScheme == .dark else { return luminance > 0.7 ? 0.38 : 0.30 }
        return luminance > 0.7 ? 0.30 : 0.26
    }

    /// 取色结果按封面地址缓存，重进页面不重复拉图、不重复渲染。
    static let paletteCache = PaletteCache()

    /// 一次取色的结果：颜色本身，外加“有彩度的像素占了多少”。
    /// 占比太低说明封面本来就没颜色（黑白、纯白底人物照），拿它当头部色只会得到一块土色，
    /// 调用方应当退回品牌色。
    struct PaletteSample {
        let color: Color
        /// 有彩度像素占边框采样的比例。
        let coverage: Double
        /// 取出来的颜色本身离灰有多远（0 = 纯灰）。
        let chroma: Double
    }

    /// 彩度像素占比低于这个数，就认为封面没有可用的颜色。
    static let liveColorCoverage = 0.22

    /// 取色的完整结果：缓存里有的直接拼出来。
    static func paletteSample(for url: URL?) async -> PaletteSample? {
        guard let url else { return nil }
        if let cached = paletteCache.color(for: url) {
            return PaletteSample(color: cached,
                                 coverage: coverageCache.object(forKey: url as NSURL)?.doubleValue ?? 1,
                                 chroma: chromaCache.object(forKey: url as NSURL)?.doubleValue ?? 1)
        }
        await paletteColor(for: url)
        guard let cached = paletteCache.color(for: url) else { return nil }
        return PaletteSample(color: cached,
                             coverage: coverageCache.object(forKey: url as NSURL)?.doubleValue ?? 1,
                             chroma: chromaCache.object(forKey: url as NSURL)?.doubleValue ?? 1)
    }

    private static let coverageCache = NSCache<NSURL, NSNumber>()
    private static let chromaCache = NSCache<NSURL, NSNumber>()

    /// 取封面主色：先看缓存，没有就解码算一次并存进缓存。页面和头部都调它，拿到的是同一个值。
    static func paletteColor(for url: URL?) async -> Color? {
        guard let url else { return nil }
        if let cached = paletteCache.color(for: url) { return cached }
        let rgb = await Task.detached(priority: .utility) { () -> (Double, Double, Double, Double, Double)? in
            let image: UIImage?
            if url.isFileURL { image = CustomCoverMedia.previewImage(at: url) }
            else if let data = try? Data(contentsOf: url), !Task.isCancelled { image = UIImage(data: data) }
            else { image = nil }
            guard let image, let input = CIImage(image: image) else { return nil }
            // 缩到 24×24 再挑：只平均“有彩度”的那一半像素，整张平均会被白背景拉成近白，
            // 看上去就是“封面颜色没上来”。
            let side = 24
            let scaled = input.transformed(by: CGAffineTransform(scaleX: CGFloat(side) / input.extent.width,
                                                                y: CGFloat(side) / input.extent.height))
            var pixels = [UInt8](repeating: 0, count: side * side * 4)
            CIContext(options: [.workingColorSpace: NSNull()]).render(scaled, toBitmap: &pixels, rowBytes: side * 4,
                    bounds: CGRect(x: 0, y: 0, width: side, height: side), format: .RGBA8, colorSpace: nil)
            // 只从四条边各取一成宽采样，中间那块不参与：人像的脸在正中，
            // 整张采样会把“肤色”当成封面主色，黑白人像就永远落不到兜底。
            let edge = max(2, side / 10)
            var vivid = (r: 0.0, g: 0.0, b: 0.0, n: 0.0)
            var all = (r: 0.0, g: 0.0, b: 0.0, n: 0.0)
            var borderCount = 0
            for y in 0..<side {
                for x in 0..<side {
                    let onBorder = x < edge || x >= side - edge || y < edge || y >= side - edge
                    guard onBorder else { continue }
                    borderCount += 1
                    let i = (y * side + x) * 4
                    let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
                    all = (all.r + r, all.g + g, all.b + b, all.n + 1)
                    let maxC = max(r, g, b), minC = min(r, g, b)
                    let sat = maxC > 0 ? (maxC - minC) / maxC : 0
                    if sat > 0.18, maxC > 0.15 { vivid = (vivid.r + r, vivid.g + g, vivid.b + b, vivid.n + 1) }
                }
            }
            let pick = vivid.n >= 8 ? vivid : all
            guard pick.n > 0 else { return nil }
            let coverage = borderCount > 0 ? vivid.n / Double(borderCount) : 0
            let pr = pick.r / pick.n, pg = pick.g / pick.n, pb = pick.b / pick.n
            // 取出来的颜色本身离灰有多远：离灰太近也当成“封面没有可用颜色”。
            let chroma = max(pr, pg, pb) - min(pr, pg, pb)
            return (pr, pg, pb, coverage, chroma)
        }.value
        guard let rgb else { return nil }
        let color = Color(red: rgb.0, green: rgb.1, blue: rgb.2)
        paletteCache.store(color, for: url)
        coverageCache.setObject(NSNumber(value: rgb.3), forKey: url as NSURL)
        chromaCache.setObject(NSNumber(value: rgb.4), forKey: url as NSURL)
        return color
    }

    /// 把“某层半透明色压在本页底色上”的结果算成一个不透明实色。
    /// 头部实底和顶部带子都用它，两者才会是同一块颜色、上下没有接缝。
    static func flatBase(palette: Color, opacity: Double) -> Color {
        let base = UIColor(Color.beansBackground)
        let over = UIColor(palette)
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        var or_: CGFloat = 0, og: CGFloat = 0, ob: CGFloat = 0, oa: CGFloat = 0
        base.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        over.getRed(&or_, green: &og, blue: &ob, alpha: &oa)
        let a = CGFloat(opacity) * oa
        return Color(uiColor: UIColor(red: br + (or_ - br) * a,
                                      green: bg + (og - bg) * a,
                                      blue: bb + (ob - bb) * a,
                                      alpha: 1))
    }

    /// 供顶部带子直接取同一个色：带子和头部渐变顶必须同色才没有接缝。
    static func cachedPalette(for url: URL?) -> Color? {
        guard let url else { return nil }
        return paletteCache.color(for: url)
    }

    private func loadPalette() async {
        guard let coverURL else { return }
        if let cached = Self.paletteCache.color(for: coverURL) {
            palette = cached
            onPalette?(cached)
            return
        }
        let url = coverURL
        let rgb = await Task.detached(priority: .utility) { () -> (Double, Double, Double)? in
            let image: UIImage?
            if url.isFileURL { image = CustomCoverMedia.previewImage(at: url) }
            else if let data = try? Data(contentsOf: url), !Task.isCancelled { image = UIImage(data: data) }
            else { image = nil }
            guard let image, let input = CIImage(image: image),
                  let filter = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: input, kCIInputExtentKey: CIVector(cgRect: input.extent)]),
                  let output = filter.outputImage else { return nil }
            var pixel = [UInt8](repeating: 0, count: 4)
            CIContext(options: [.workingColorSpace: NSNull()]).render(output, toBitmap: &pixel, rowBytes: 4,
                    bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
            return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
        }.value
        guard let rgb, !Task.isCancelled else { return }
        let color = Color(red: rgb.0, green: rgb.1, blue: rgb.2)
        Self.paletteCache.store(color, for: coverURL)
        onPalette?(color)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { palette = color }
    }
}

/// 封面取色的小缓存，键是封面地址。
final class PaletteCache: @unchecked Sendable {
    private let cache = NSCache<NSURL, RGBColorBox>()
    func color(for url: URL) -> Color? {
        cache.object(forKey: url as NSURL)?.color
    }
    func store(_ color: Color, for url: URL) {
        cache.setObject(RGBColorBox(color: color), forKey: url as NSURL)
    }
}

final class RGBColorBox: NSObject, @unchecked Sendable {
    let color: Color
    init(color: Color) { self.color = color }
}
