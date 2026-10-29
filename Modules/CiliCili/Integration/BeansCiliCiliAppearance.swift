import Combine
import SwiftUI

/// Bridges Beans' shared wallpaper and accent preferences into the recovered
/// CiliCili screens. The module's existing glass and scrolling modifiers remain active.
@MainActor
public final class CiliCiliHostAppearance: ObservableObject {
    public static let shared = CiliCiliHostAppearance()
    @Published public private(set) var backdrop: AnyView?
    @Published public private(set) var accent: Color?
    @Published public private(set) var usesLiquidGlass = true
    /// 列表区底板色（Beans 的 beansGlassFill × 0.92）。壁纸只留在头部，进列表后由这层接住，保证文字对比度。
    @Published public private(set) var contentPanelColor: Color?

    public func update(backdrop: AnyView?, accent: Color?, usesLiquidGlass: Bool, contentPanelColor: Color? = nil) {
        self.backdrop = backdrop
        self.accent = accent
        self.usesLiquidGlass = usesLiquidGlass
        self.contentPanelColor = contentPanelColor
    }
}

struct CiliCiliHostBackdrop: View {
    @ObservedObject private var appearance = CiliCiliHostAppearance.shared
    var body: some View {
        Group {
            if let backdrop = appearance.backdrop { backdrop }
            else { Color(.systemGroupedBackground) }
        }.ignoresSafeArea().allowsHitTesting(false)
    }
}

/// 列表区底板：从头卡下沿起接住内容，只留上两个圆角，上下各 24pt 渐隐避免硬边。
struct CiliCiliContentPanel: View {
    @ObservedObject private var appearance = CiliCiliHostAppearance.shared
    var cornerRadius: CGFloat = 24
    var edgeFade: CGFloat = 24

    var body: some View {
        GeometryReader { proxy in
            let shape = UnevenRoundedRectangle(
                topLeadingRadius: cornerRadius, topTrailingRadius: cornerRadius, style: .continuous
            )
            shape
                .fill(appearance.contentPanelColor ?? Color(.secondarySystemBackground))
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: min(edgeFade, proxy.size.height / 3))
                        Rectangle().fill(.black)
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: min(edgeFade, proxy.size.height / 3))
                    }
                }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 头部区域的页面遮罩：壁纸在头部照常透出来，但压暗一档，免得头卡上的白字糊在亮照片上。
struct CiliCiliHeaderScrim: View {
    @Environment(\.colorScheme) private var colorScheme
    var height: CGFloat = 260

    var body: some View {
        // 顶部 0 → 头卡下沿最深 → 到底板起点前淡到 0：壁纸在头部露出，标题压上去还能读。
        let peak = colorScheme == .dark ? 0.55 : 0.35
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0), location: 0),
                .init(color: .black.opacity(peak * 0.45), location: 0.55),
                .init(color: .black.opacity(peak), location: 0.86),
                .init(color: .black.opacity(0), location: 1)
            ],
            startPoint: .top, endPoint: .bottom
        )
        .frame(height: height)
        .frame(maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
