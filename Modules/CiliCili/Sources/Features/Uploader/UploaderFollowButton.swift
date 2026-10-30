import SwiftUI

struct UploaderFollowButton: View {
    let owner: VideoOwner
    @ObservedObject var viewModel: UploaderViewModel

    /// 两档品牌红，按 WCAG 反算过：
    /// 实底胶囊配白字要 4.5:1，填充色压到 #D9302E 是 4.76:1（原来的 #EC4847 只有 3.76）；
    /// 已关注是描边胶囊，字色浅色 #C72926（近白底 5.5:1）、深色 #F2555A（#202020 底 4.83:1）。
    /// 不再吃全局 tint：外层 tint 会盖掉内层，之前的「改正文色」其实没生效。
    private var followedTint: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0xF2 / 255, green: 0x55 / 255, blue: 0x5A / 255, alpha: 1)
                : UIColor(red: 0xC7 / 255, green: 0x29 / 255, blue: 0x26 / 255, alpha: 1)
        })
    }

    private var followFill: Color {
        Color(red: 0xD9 / 255, green: 0x30 / 255, blue: 0x2E / 255)
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
