import SwiftUI

struct UploaderHeaderView: View {
    @Environment(\.colorScheme) private var colorScheme
    let owner: VideoOwner
    @ObservedObject var viewModel: UploaderViewModel

    private var card: UploaderCard? {
        viewModel.profile?.card
    }

    /// 壁纸底色不可控，玻璃只透底就会把卡面染成壁纸色，白字随之塌掉。
    /// 先垫一层固定底，再上玻璃：卡面亮度稳定，文字对比度不再随壁纸漂移。
    private var cardBaseColor: Color {
        colorScheme == .dark
            ? Color(red: 0.11, green: 0.11, blue: 0.12).opacity(0.72)
            : Color.white.opacity(0.78)
    }

    private var cardTextColor: Color {
        colorScheme == .dark ? .white : Color(.label)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            UploaderIdentityRow(owner: owner, card: card, viewModel: viewModel)
            UploaderSignatureText(sign: card?.sign)
            UploaderFollowMessage(message: viewModel.followMessage, isFollowing: viewModel.isFollowing)
            UploaderProfileStatusMessage(state: viewModel.profileState)
            UploaderStatsRow(viewModel: viewModel, card: card)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(cardBaseColor)
        )
        .biliGlassEffect(
            interactive: false,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(cardTextColor.opacity(0.14), lineWidth: 0.8)
        }
        .foregroundStyle(cardTextColor)
        .padding(.horizontal, 12)
    }
}
