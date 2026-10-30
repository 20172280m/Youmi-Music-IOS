import SwiftUI

struct UploaderFollowButton: View {
    @Environment(\.appThemeTintColor) private var appTintColor
    @Environment(\.colorScheme) private var colorScheme
    let owner: VideoOwner
    @ObservedObject var viewModel: UploaderViewModel

    /// 两档都按 AppThemeContrastTokens 派生，跟着用户选的主题色走：
    /// 实底胶囊配白字、已关注描边胶囊的字压在胶囊底上，都要 ≥4.6:1。
    /// 之前那版吃过教训：外层 .tint 会盖住内层，所以 tint 只挂在按钮本身上。
    private var followedTint: Color {
        AppThemeContrastTokens.legibleText(
            from: appTintColor,
            on: AppThemeContrastTokens.borderedCapsuleBackground(from: appTintColor, isDark: colorScheme == .dark),
            isDark: colorScheme == .dark
        )
    }

    private var followFill: Color {
        AppThemeContrastTokens.filledBackground(from: appTintColor)
    }

    var body: some View {
        Group {
            if viewModel.isFollowing {
                Button(action: toggleFollow) {
                    label
                }
                .buttonStyle(.bordered)
                .tint(followedTint)
            } else {
                Button(action: toggleFollow) {
                    label
                }
                .buttonStyle(.borderedProminent)
                .tint(followFill)
            }
        }
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .disabled(viewModel.isMutatingFollow || owner.mid <= 0)
    }

    private var label: some View {
        HStack(spacing: 6) {
            if viewModel.isMutatingFollow {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: viewModel.isFollowing ? "checkmark" : "plus")
                    .font(.caption.weight(.bold))
            }

            Text(viewModel.isFollowing ? "已关注" : "关注")
                .font(.caption.weight(.semibold))
        }
        .frame(minWidth: 62)
    }

    private func toggleFollow() {
        Task {
            let didSucceed = await viewModel.toggleFollow()
            if didSucceed {
                Haptics.success()
            } else {
                Haptics.light()
            }
        }
    }
}
