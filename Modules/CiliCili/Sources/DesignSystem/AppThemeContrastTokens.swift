import SwiftUI
import UIKit

/// 品牌色当「实底 + 白字」或「文字压在表面上」时的对比度派生规则（Colo 定，2026-10-30）。
///
/// 规则：品牌色做按钮实底时，底部压到与白字 ≥4.6:1 的那一档（保持色相，只压亮度）；
/// 品牌色做文字时，浅色模式往黑压、深色模式往白提，直到对所在表面 ≥4.6:1。
/// 任何自定义主题色都自动按这条走，调用方不再手写十六进制。
///
/// 为什么不是固定色值：主题色是用户可选的（默认 #FB7299，还有八档），
/// 写死一档红只能救一种主题色。
enum AppThemeContrastTokens {
    /// 目标对比度 4.65：比 4.5 的门槛留 0.15 余量，屏幕取整和色偏都吃不掉它。
    static let minimumRatio: CGFloat = 4.65

    /// 品牌色当实底、上面配白字时的填充色。
    static func filledBackground(from accent: Color) -> Color {
        let base = components(of: accent)
        let adjusted = adjust(base, toward: .black, reaching: minimumRatio, against: .white)
        return color(of: adjusted)
    }

    /// 「已关注」这类描边胶囊：字色要压在胶囊底色上，浅色压深、深色提亮。
    static func legibleText(from accent: Color, on surface: Color, isDark: Bool) -> Color {
        let base = components(of: accent)
        let surfaceComponents = components(of: surface)
        let adjusted = adjust(
            base,
            toward: isDark ? .white : .black,
            reaching: minimumRatio,
            against: surfaceComponents
        )
        return color(of: adjusted)
    }

    /// 描边胶囊的底色预估：主题色按 12% 混到底色上。
    static func borderedCapsuleBackground(from accent: Color, isDark: Bool) -> Color {
        let accentComponents = components(of: accent)
        let baseComponents: RGB = isDark
            ? RGB(red: 0x20 / 255, green: 0x20 / 255, blue: 0x20 / 255)
            : .white
        let mixed = mix(baseComponents, accentComponents, 0.12)
        return color(of: mixed)
    }

    // MARK: - 色彩计算

    private struct RGB {
        var red: CGFloat
        var green: CGFloat
        var blue: CGFloat

        static let white = RGB(red: 1, green: 1, blue: 1)
        static let black = RGB(red: 0, green: 0, blue: 0)
    }

    private static func components(of color: Color) -> RGB {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return RGB(red: red, green: green, blue: blue)
    }

    private static func color(of rgb: RGB) -> Color {
        Color(.sRGB, red: Double(rgb.red), green: Double(rgb.green), blue: Double(rgb.blue), opacity: 1)
    }

    /// 量化到 8 位通道，和屏幕上真正显示的颜色对齐。
    /// 二分时比的是量化后的颜色，所以取整不会再把对比度挤到目标线下。
    private static func quantised(_ rgb: RGB) -> RGB {
        RGB(
            red: (rgb.red * 255).rounded(.down) / 255,
            green: (rgb.green * 255).rounded(.down) / 255,
            blue: (rgb.blue * 255).rounded(.down) / 255
        )
    }

    private static func mix(_ from: RGB, _ to: RGB, _ amount: CGFloat) -> RGB {
        RGB(
            red: from.red + (to.red - from.red) * amount,
            green: from.green + (to.green - from.green) * amount,
            blue: from.blue + (to.blue - from.blue) * amount
        )
    }

    /// 从 base 向 target 混，二分出刚好达到目标对比度的最小混合比例。
    private static func adjust(_ base: RGB, toward target: RGB, reaching targetRatio: CGFloat, against other: RGB) -> RGB {
        let quantisedBase = quantised(base)
        if contrast(quantisedBase, other) >= targetRatio { return quantisedBase }
        var low: CGFloat = 0
        var high: CGFloat = 1
        for _ in 0..<18 {
            let mid = (low + high) / 2
            if contrast(quantised(mix(base, target, mid)), other) >= targetRatio {
                high = mid
            } else {
                low = mid
            }
        }
        return quantised(mix(base, target, high))
    }

    private static func contrast(_ first: RGB, _ second: RGB) -> CGFloat {
        let a = relativeLuminance(first)
        let b = relativeLuminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private static func relativeLuminance(_ rgb: RGB) -> CGFloat {
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.red) + 0.7152 * linear(rgb.green) + 0.0722 * linear(rgb.blue)
    }
}
