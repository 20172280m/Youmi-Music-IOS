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
            contentPanelColor: Color.beansGlassFill.opacity(theme.backgroundSyncAll ? 0.86 : 0.6)
        )
    }
}
