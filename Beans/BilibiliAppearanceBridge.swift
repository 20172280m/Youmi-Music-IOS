import Combine
import CiliCiliKit
import SwiftUI

@MainActor
final class BilibiliAppearanceBridge {
    static let shared = BilibiliAppearanceBridge()
    private var subscriptions = Set<AnyCancellable>()

    func start() {
        guard subscriptions.isEmpty else { return }
        ThemeStore.shared.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                await Task.yield()
                self?.update()
            }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).sink { [weak self] _ in
            Task { @MainActor in self?.update() }
        }.store(in: &subscriptions)
        update()
    }

    private func update() {
        let theme = ThemeStore.shared
        let usesGlass = !UserDefaults.standard.bool(forKey: "beans.disableLiquidGlass")
        CiliCiliHostAppearance.shared.update(
            backdrop: theme.backgroundSyncAll ? AnyView(GlassBackdrop().environmentObject(theme)) : nil,
            accent: Color.beansAmber, usesLiquidGlass: usesGlass,
            // 壁纸只透在头部，列表区靠这层底板接住；同步关掉时下面只有氛围渐变，底板减淡到 0.6 就够。
            // 底板按「不透明度」算，不再乘 beansGlassFill 自带的 0.55：
            // 叠两层半透明会被乘成 0.47，压在亮壁纸上等于没画（Ato 量到标题 1.6:1 的那次）。
            contentPanelColor: Color(uiColor: .systemBackground).opacity(theme.backgroundSyncAll ? 0.86 : 0.6)
        )
    }
}
