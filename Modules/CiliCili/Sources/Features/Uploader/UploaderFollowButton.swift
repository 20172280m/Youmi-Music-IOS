import SwiftUI

struct UploaderFollowButton: View {
    @Environment(\.appThemeTintColor) private var appTintColor
    let owner: VideoOwner
    @ObservedObject var viewModel: UploaderViewModel

    var body: some View {
        Group {
            if viewModel.isFollowing {
                Button(action: toggleFollow) {
                    label
                }
                .buttonStyle(.bordered)
                // 「已关注」不再跟主题色走：浅粉底上的粉字只有 1.28:1（深色 1.99:1）。
                // 用正文色做胶囊，浅色=近黑字浅灰底、深色=白字深灰底，两档都稳。
                .tint(Color(.label))
            } else {
                Button(action: toggleFollow) {
                    label
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(appTintColor)
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
