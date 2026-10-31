import SwiftUI
import UIKit

// MARK: - 歌手主页（点击播放器顶部歌手名跳转：热门歌曲 + 专辑）

@MainActor
struct ArtistHomeSheet: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.dismiss) private var dismiss
    /// 以 overlay 形式而不是弹层呈现时，用它来关闭。
    var onClose: (() -> Void)?
    let artistName: String
    var artistSource: SongSource = .netease
    var artistID: String?
    /// 从已有导航栈推入时不再创建嵌套 NavigationStack，也不应用 sheet 专用修饰器。
    var embeddedInNavigation = false

    private static func cachedEntry(
        artistName: String,
        source: SongSource,
        artistID: String?
    ) -> ArtistHomeCache.Entry? {
        let identity = artistID?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? artistName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ArtistHomeCache.shared.cached(for: "\(source.rawValue):\(identity)")
    }

    init(artist: Artist, embeddedInNavigation: Bool = false, onClose: (() -> Void)? = nil) {
        self.onClose = onClose
        self.artistName = artist.name
        self.artistSource = artist.source
        self.artistID = artist.id
        self.embeddedInNavigation = embeddedInNavigation
        let cached = Self.cachedEntry(artistName: artist.name, source: artist.source, artistID: artist.id)
        _artist = State(initialValue: cached?.artist ?? artist)
        _hotSongs = State(initialValue: cached?.songs ?? [])
        _albums = State(initialValue: cached?.albums ?? [])
        _loading = State(initialValue: cached == nil || (cached?.songs.isEmpty == true && cached?.albums.isEmpty == true))
    }

    init(artistName: String, artistSource: SongSource = .netease, embeddedInNavigation: Bool = false,
         onClose: (() -> Void)? = nil) {
        self.artistName = artistName
        self.onClose = onClose
        self.artistSource = artistSource
        self.artistID = nil
        self.embeddedInNavigation = embeddedInNavigation
        let cached = Self.cachedEntry(artistName: artistName, source: artistSource, artistID: nil)
        _artist = State(initialValue: cached?.artist)
        _hotSongs = State(initialValue: cached?.songs ?? [])
        _albums = State(initialValue: cached?.albums ?? [])
        _loading = State(initialValue: cached == nil || (cached?.songs.isEmpty == true && cached?.albums.isEmpty == true))
    }

    @State private var artist: Artist?
    @State private var hotSongs: [Song] = []
    @State private var albums: [Album] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var watchdogTask: Task<Void, Never>?
    @AppStorage(BeansImmersiveDetailHeader.enabledKey) private var immersiveDetail = true
    @State private var showBatchDownload = false
    @State private var selectedAlbum: Album?
    @State private var loadTask: Task<Void, Never>?
    @StateObject private var progress = ArtistScrollProgress()
    /// 顶部带子的纯色：底色和封面取色按 0.25 混好一次性存下来。
    @State private var bandColor: Color = Color.beansBackground

    /// 顶部带子跟头部渐变最顶那一层用同一个颜色、同一个不透明度，
    /// 叠在同一块背景上颜色就一样，上下没有边界。
    private var bandSurface: Color {
        let tint = pagePalette ?? theme.accent.highlight
        let ui = UIColor(tint)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
        let light = luminance > 0.7
        let opacity: Double = colorScheme == .dark ? (light ? 0.10 : 0.22) : (light ? 0.14 : 0.25)
        // 跟头部一样的实底：视觉上与渐变顶同色，但完全不透明，内容是干净地消失在它后面。
        return BeansImmersiveDetailHeader.flatBase(palette: tint, opacity: opacity)
    }
    /// 头部自然高度：只量一次。头部自己的尺寸不依赖这个值（只有叠层裁剪带和空白块用它），
    /// 所以量→写回→再量不会成环。
    @Environment(\.colorScheme) private var colorScheme

    /// 歌手页顶部整块是用户壁纸，文字后面没有渐变兜底：副信息垫一层固定底。
    /// 0.9 不透明仍然透出一点壁纸，但底板亮度不再随壁纸摆。
    private var headerTextBackdrop: Color {
        colorScheme == .dark
            ? Color(red: 0.11, green: 0.11, blue: 0.12).opacity(0.9)
            : Color.white.opacity(0.9)
    }
    @State private var bandTint: Color?
    /// 本页自己算的封面取色：页面底渐变和头部共用这一个值，不靠头部异步回传。
    @State private var pagePalette: Color?
    /// 顶部渐变只在“展开/收起”两个高度间切换。跟着滚动逐帧改高度会让整页冻住（实测）。
    @State private var stripCollapsed = false
    /// 每次打开这一页都给滚动容器一个新的身份：SwiftUI 会按身份记住上一次的滚动偏移，
    /// 从播放器点歌手名进来时就会顶着上一次的偏移打开（文字已淡出、列表从中间开始）。
    /// 换身份让它每次都从零开始，比事后滚回去稳，也不需要发滚动命令。
    @State private var scrollIdentity = UUID()
    @State private var measuredHeaderHeight: CGFloat?
    @State private var partialTimedOut = false
    @State private var bannerRetrying = false
    /// 收起进度归一化：0 = 完全展开，1 = 头部完全收起。
    /// 距离取“头部展开高度 284 − 导航栏高度 44”，对应设计规范里的这一段滚动行程。
    /// 展开高度只在首次出现时量一次，之后当常量用；p 由固定锚算，所以高度不参与 p 的计算，不成环。
    /// 展开高度按字体度量和头部自身的间距算出来，装配阶段不测视图。
    /// 一旦“测量→写回布局→再测量”，第一帧就出不来（症状是启动即骨架、主线程卡死）。
    private var headerHeight: CGFloat {
        if let measuredHeaderHeight { return measuredHeaderHeight }
        return formulaHeaderHeight
    }

    /// 收起时的头部高度：内边距 + 封面当前高度（132×缩放）+ 每段内容的高度乘它自己的可见度。
    /// 跟淡出共用同一条进度，所以不会出现“字不见了、位子还留着”的空白。
    private var collapsedHeaderHeight: CGFloat {
        let cover = 132 * (1 - 0.64 * collapseProgress)
        let textVisible = max(0, 1 - collapseProgress / 0.3)
        let buttonVisible = max(0, 1 - collapseProgress / 0.22)
        // 52 里含了文字段的间距；文字都淡没了之后只剩 24 的呼吸，让搜索框紧贴在封面下面。
        let padding: CGFloat = (textVisible > 0 || buttonVisible > 0) ? 52 : 24
        let title: CGFloat = 39 * textVisible
        let meta: CGFloat = 34 * textVisible
        let button: CGFloat = 60 * buttonVisible
        var total: CGFloat = padding + cover
        total += title + meta + button
        return total
    }

    /// 算式只给顶部空白块一个初始值，真实高度以头部自然撑开量到的为准。
    private var formulaHeaderHeight: CGFloat {
        guard immersiveDetail else { return 0 }
        let width = UIScreen.main.bounds.width - 48   // 头部左右各 24
        let titleFont = BeansFont.appUIFont(22, .semibold)
        let titleLine = ceil(titleFont.lineHeight)
        let text = (artist?.name ?? artistName) as NSString
        let rect = text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                                    attributes: [.font: titleFont], context: nil)
        let lines = max(1, min(2, Int(ceil(rect.height / titleLine - 0.02))))
        let metaLine = ceil(BeansFont.appUIFont(12).lineHeight)
        // 组件自身的固定部分：上下内边距 24×2、封面 132、各处 16 的间距（名字到副信息 6）、
        // 播放全部 44。单行 317、两行 344，是设计在真机上量到的展开高度。
        let fixed: CGFloat = 275
        return fixed + titleLine * CGFloat(lines) + metaLine
    }


    /// 把封面色按固定比例压到页面底色上，得到一个不透明的纯色。
    /// 只做一次 RGB 混合，不涉及任何绘制或采样。
    private static func blendIntoBackground(_ tint: Color, amount: CGFloat) -> Color {
        let base = UIColor(Color.beansBackground)
        let over = UIColor(tint)
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        var or_: CGFloat = 0, og: CGFloat = 0, ob: CGFloat = 0, oa: CGFloat = 0
        base.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        over.getRed(&or_, green: &og, blue: &ob, alpha: &oa)
        let a = amount * oa
        return Color(uiColor: UIColor(red: br + (or_ - br) * a,
                                      green: bg + (og - bg) * a,
                                      blue: bb + (ob - bb) * a,
                                      alpha: 1))
    }

    private var collapseProgress: CGFloat {
        // 进度由节流器算好（分母用算式高度，不用量到的值：量到的值一旦偏大，
        // 收起进度就永远走不到 1，叉不上去、标题不淡入都是这一个原因）。
        progress.progress
    }
    /// 导航栏标题从 p=0.65 开始淡入、p=1 完全不透明，避免展开态一屏两个标题。
    private var navTitleOpacity: Double {
        Double(min(1, max(0, (collapseProgress - 0.65) / 0.35)))
    }

    @AppStorage(BeansBackendSettings.downloadUnlockKey) private var downloadFeatureUnlocked = false
    @AppStorage("beans.showSongVIPBadge") private var showSongVIPBadge = true

    private var cacheKey: String {
        let identity = artistID?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? artistName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(artistSource.rawValue):\(identity)"
    }

    var body: some View {
        Group {
            if embeddedInNavigation {
                artistPage
            } else {
                // 这一页现在由播放页用全屏覆盖打开，不再需要 sheet 卡片外观；
                // 卡片那层会把顶部（标题栏、搜索框）包进不可点的区域。
                BeansNavigationStack { artistPage }
            }
        }
        // 下拉关闭已经撤掉：这页头部本身就跟着滚动变，下拉手势和收起进度会一起动。
        // 出口只有自绘的那个叉。
        .onAppear {
            loadTask?.cancel()
            loadTask = Task { await load() }
            startWatchdog()
        }
        .onDisappear {
            progress.close()
            loadTask?.cancel()
        }
        .sheet(isPresented: $showBatchDownload) {
            BatchDownloadSheet(songs: displayedHotSongs, title: "下载歌手歌曲")
                .environmentObject(theme)
        }
        .sheet(item: $selectedAlbum) { album in
            AlbumDetailView(album: album)
                .environmentObject(player)
                .environmentObject(theme)
        }
    }

    @ViewBuilder
    private var artistPage: some View {
        ZStack {
            // 坐标系挂在这个静止容器上，不挂在 ScrollView 上：
            // 挂在 ScrollView 上量到的是内容坐标系，滚动时锚的位移恒为 0，p 永远不变。
            // 歌手页沿用主页壁纸，不受“同步到全部页面”开关影响。
            GlassBackdrop(customColor: theme.customBackground, homeMode: true)
                .ignoresSafeArea()
            // 壁纸留给头部当主角，正文区不再直接压在照片上：
            // 从头部下沿起垫一层实底，卡片标题、歌手名、搜索框才有一条稳定的底。
            // 上沿跟着头部收起往上升，全程贴着头部下沿，中间不留一条透壁纸的缝。
            if immersiveDetail {
                contentBase
            }
            Group {
                if loading {
                    ZStack(alignment: .bottom) {
                        artistLoadingState
                        BeansSlowLoadHint().padding(.bottom, 24)
                    }
                } else if let errorMessage {
                    ErrorStateView(message: errorMessage) {
                        loadTask?.cancel()
                        startWatchdog()
                        loadTask = Task { await load() }
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            // 静态空白块：固定＝头部展开高度（设计已确认的 317/344），不随 p 变。
                            // 头部叠在上面收，内容总高从头到尾不变，偏移、p、头部尺寸之间没有回写的环。
                            if immersiveDetail {
                                Color.clear.frame(height: formulaHeaderHeight)
                            } else {
                                artistHeader
                            }
                            if partialTimedOut, !hotSongs.isEmpty || !albums.isEmpty {
                                partialTimeoutBanner
                            }
                            artistSearchField
                                .padding(.horizontal, 16)
                            hotSongsHeaderBlock
                            hotSongsRows
                            albumsSection
                        }
                        // 头部播放全部的下沿到搜索框留 16 点，别让列表第一项贴着脸。
                        .padding(.top, 16)
                        .padding(.bottom, 16)
                    }
                    .beansScrollIndicatorsHidden()
                    // 滚动只读：几何值交给节流器，隔一层再写状态，写回也不逐帧改布局。
                    // 之前是把几何值在每次回调里直接写进 @State，列表第一屏的布局就被反复打断，
                    // 主线程彻底停在那一帧（日志实证 main=BLOCKED，读树只剩系统节点）。
                    .onScrollGeometryChange(for: ArtistScrollSnapshot.self) { geo in
                        ArtistScrollSnapshot(
                            offset: max(0, geo.contentOffset.y + geo.contentInsets.top),
                            // 内容高度已经超过容器，说明第一屏真的排完了，不是还在长。
                            laidOut: geo.contentSize.height > geo.containerSize.height - 1
                        )
                    } action: { _, snapshot in
                        if snapshot.laidOut { progress.open(span: max(44, formulaHeaderHeight - 44)) }
                        progress.submit(snapshot.offset)
                    }
                    .task {
                        // 首屏排完由上面的信号开闸；这里的 0.7 秒只是兜底，
                        // 免得某些机型第一帧不发几何回调时页面永远收不起来。
                        try? await Task.sleep(nanoseconds: 700_000_000)
                        progress.open(span: max(44, formulaHeaderHeight - 44))
                    }
                    // 带子只切两档，用进度而不是逐点偏移：0.8 往下收、0.7 以里放长，
                    // 中间那段回差是为了跨线时不来回抖。
                    .onChange(of: progress.progress) { _, value in
                        if !stripCollapsed, value > 0.8 { stripCollapsed = true }
                        else if stripCollapsed, value < 0.7 { stripCollapsed = false }
                    }
                    // 从播放器点歌手名进来时，这一页会带着上一次的偏移打开：文字按进度淡成 0，
                    // 搜索框滑进顶部那条不透明带子后面，看上去就是「四块凭空消失」。
                    // 只在初始布局上声明「顶在上沿」，不发滚动命令、不写状态——命令式回顶实测会冻。
                    .defaultScrollAnchor(.top)
                }
            }
        }
        // 整页唯一的顶部渐变：从屏幕最上沿一路淡到页面底色，高度＝头部当前高度。
        // 它盖在滚动内容上面，所以列表滚上来是从这层后面过去，不会和状态栏、导航栏打架。
        .overlay(alignment: .top) {
            if immersiveDetail, !loading, errorMessage == nil {
                topGradient
            }
        }
        // 头部叠在滚动容器上面，只活在自己的裁剪带里：带高＝当前头部高度，收到 0 时整条消失。
        .overlay(alignment: .top) {
            if immersiveDetail, !loading, errorMessage == nil {
                artistHeader
                    .padding(.top, 57)

            }
        }
        // 顶部那一行：叉在左、标题居中，同一个 HStack 同一行。收起时标题淡入，展开时只有叉。
        // 全部长在页面自己这一层，不碰导航栏、不问屏幕要坐标。
        .overlay(alignment: .top) {
            if immersiveDetail, !loading, errorMessage == nil {
                HStack {
                    Button {
                        BeansHaptics.tap()
                        close()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.beansLabel)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭歌手主页")
                    .accessibilityIdentifier("beans.artist.close")
                    Spacer(minLength: 0)
                }
                .overlay {
                    Text(artist?.name ?? artistName)
                        .font(BeansFont.appFont(17, .semibold))
                        .foregroundStyle(Color.beansLabel)
                        .opacity(navTitleOpacity)
                        .accessibilityHidden(navTitleOpacity < 0.2)
                }
                .frame(height: 44)
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }
        }
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
        }
        .navigationBarTitleDisplayMode(.inline)
        // 不用 .searchable 的导航抽屉：它会另起一个窗口抢焦点，整页收不到点击。
        // 改成工具栏按钮展开的常驻输入框。
        // 整屏页里不出现宿主那个头像入口：只在普通歌手页挂右上角。
        .overlay(alignment: .topTrailing) {
            if !immersiveDetail {
                BeansDetailProfileShortcut()
                    .padding(.trailing, 16)
                    .padding(.top, 6)
            }
        }
        // 导航栏自己的材质会把顶部带子压亮一层，形成一条看得见的边；沉浸态整条透明。
        .toolbarBackground(immersiveDetail ? .hidden : .automatic, for: .navigationBar)
    }

    /// 正文区的底：上沿＝头部当前下沿。实底而不是玻璃：卡片标题是 12 点灰字，
    /// 只有实底能保证它不随壁纸亮度漂（壁纸是用户照片，什么颜色都可能有）。
    private var contentBase: some View {
        VStack(spacing: 0) {
            // 空出头部那一截，壁纸在那一段还是主角。
            Color.clear.frame(height: contentBaseTop)
            baseShape
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
    }

    /// 面板上沿：跟着内容一起走——内容上移多少，上沿就上移多少。
    /// 用过「贴着头部下沿」，但头部在下沿是按各段内容高度缩的，缩得比文字淡出快，
    /// 那条边会从还在淡出的名字中间扫过去（实测 p≈0.13 就扫到了）。
    /// 下限是收起后那条带子的下沿 132，再往上会把带子盖住。
    private var contentBaseTop: CGFloat {
        let span = max(44, formulaHeaderHeight - 44)   // 与收起进度 p 的分母同一个数
        let resting = 57 + headerHeight
        return max(132, resting - collapseProgress * span)
    }

    private var baseShape: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: 24,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: 24,
            style: .continuous
        )
        .fill(Color.beansBackground)
        .overlay {
            UnevenRoundedRectangle(
                topLeadingRadius: 24,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 24,
                style: .continuous
            )
            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        }
    }

    /// 顶部那一道渐变，整页只有这一层：颜色来自本页自己算的封面主色。
    /// 单条渐变，实色段用停点做：展开档实色 57 再淡到带子底，收起档整条实色（无过渡）。
    /// 拆成「实色一块 + 淡出一块」那版会让整页停下来，这里退回单条：
    /// 跨档时实色长度会跳一下，宁可看见带子长一截，也不要整页死掉。
    private var topGradient: some View {
        let tint = pagePalette ?? theme.accent.highlight
        let stripHeight: CGFloat = stripCollapsed ? 132 : 57 + formulaHeaderHeight + 24
        // 收起档不再留过渡：实色直接铺到带子下沿（132），边界是一条干净的线，
        // 过渡带里不会再露出上一行封面的一角。
        let solidPoints: CGFloat = stripCollapsed ? 132 : 57
        let solidStop = max(0.001, min(1, solidPoints / max(stripHeight, 1)))
        return LinearGradient(stops: [.init(color: tint, location: 0),
                                      .init(color: tint, location: solidStop),
                                      .init(color: tint.opacity(0), location: 1)],
                              startPoint: .top, endPoint: .bottom)
            .frame(height: stripHeight)
            .frame(maxWidth: .infinity, alignment: .top)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.2), value: stripCollapsed)
    }

    /// 常驻搜索框：输入即过滤热门歌曲与专辑，不弹独立窗口，不抢焦点。
    private var artistSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.beansComment)
            TextField(beansLocalized("搜索歌手歌曲", "Search artist songs"), text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityIdentifier("beans.artist.searchField")
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.beansComment)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // 沉浸态这一条悬在壁纸上、又不在面板里：玻璃会透出照片颜色，
        // 换成实底，占位字和输入的字都不再随壁纸漂。
        .background(immersiveDetail ? AnyShapeStyle(Color.beansBackground)
                                    : AnyShapeStyle(.ultraThinMaterial),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var artistHeader: some View {
        if immersiveDetail {
            BeansImmersiveDetailHeader(coverURL: artist?.coverURL, title: artist?.name ?? artistName,
                                      metadata: "热门歌曲 \(hotSongs.count) 首 · 专辑 \(albums.count) 张",
                                      portrait: true, coverSize: 132, titleSize: 22,
                                      collapseProgress: collapseProgress,
                                      paletteOverride: pagePalette,
                                      onPlayAll: hotSongs.isEmpty ? nil : {
                                          player.play(songs: displayedHotSongs, startAt: 0)
                                      },
                                      playAllTint: theme.accent.highlight,
                                      textBackdrop: headerTextBackdrop,
                                      onPalette: { tint in
                                          // 只在真的换了颜色时才写状态：头部每次重排都可能重跑取色，
                                          // 无条件写会把“写状态→重排→再取色”接成环。
                                          guard tint != bandTint else { return }
                                          bandTint = tint
                                      })
                // 收起：只从底边收高度，内容不上移——上移会让内容跑到裁剪带上沿外面，
                // 露出一条封面像被横切。封面自己的缩放跟着同一个进度，收的时候整张留在带子里。
                .compositingGroup()
                .frame(height: max(0, collapsedHeaderHeight), alignment: .top)

                .task(id: artist?.coverURL) {
                    // 封面自己没什么颜色时（黑白封面、纯白底人物照）用它当头部色只会得到一块土色，
                    // 这时改用品牌色，和“播放全部”是同一个粉，页面整体才是一个调子。
                    let sample = await BeansImmersiveDetailHeader.paletteSample(for: artist?.coverURL)
                    let tint: Color
                    // 两个判据都要过：出彩的像素够多，取出来的颜色也得离灰够远。
                    // 任一不满足就当成“封面没有可用颜色”，用品牌粉兜底。
                    if let sample,
                       sample.coverage >= BeansImmersiveDetailHeader.liveColorCoverage,
                       sample.chroma >= 0.12 {
                        tint = sample.color
                    } else {
                        tint = theme.accent.highlight
                    }
                    if tint != pagePalette {
                        pagePalette = tint
                    }
                }
        } else {
        HStack(spacing: 14) {
            BeansAvatarView(remoteURL: artist?.coverURL, size: 72)
            .background(Color.beansGlassFill, in: Circle())

            VStack(alignment: .leading, spacing: 6) {
                Text(artist?.name ?? artistName)
                    .font(BeansFont.appFont(20, .bold))
                    .foregroundStyle(Color.beansLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                Text(beansLocalized("热门歌曲 \(hotSongs.count) 首 · 专辑 \(albums.count) 张", "Popular songs: \(hotSongs.count) · Albums: \(albums.count)"))
                    .font(BeansFont.appFont(12))
                    .foregroundStyle(Color.beansComment)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        }
    }

    /// 部分内容加载失败提示带：不遮内容，占固定高度，重试成功后淡出移除。
    private var partialTimeoutBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 14))
                .foregroundStyle(Color.beansSecondary)
            Text("部分内容加载失败")
                .font(BeansFont.appFont(13))
                .foregroundStyle(Color.beansLabel)
            Spacer(minLength: 8)
            Button {
                guard !bannerRetrying else { return }
                bannerRetrying = true
                loadTask?.cancel()
                loadTask = Task { await load() }
            } label: {
                Text(bannerRetrying ? "正在重试…" : "重试")
                    .font(BeansFont.appFont(13, .semibold))
                    .foregroundStyle(Color.beansAmber)
                    .frame(minWidth: 56, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .disabled(bannerRetrying)
            .accessibilityIdentifier("beans.artist.partialRetry")
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .transition(.opacity)
    }

    private var artistLoadingState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // 加载期就按沉浸头部的高度和样子占位：132 圆形封面、名字、副信息、播放全部，
                // 数据回来时不会跳，第 4 张验收拍的那一两秒也是这个样子。
                VStack(spacing: 16) {
                    BeansShimmerSkeleton(cornerRadius: 66)
                        .frame(width: 132, height: 132)
                    // 名字占位按规范取宽度 60%（约 264），高度按 22pt 名字的真实行高 27 排，
                    // 否则数据回来那一刻会把下面的播放全部顶下去。
                    BeansShimmerSkeleton(cornerRadius: 6)
                        .frame(width: 264, height: 27)
                    BeansShimmerSkeleton(cornerRadius: 5)
                        .frame(width: 180, height: 13)
                    BeansShimmerSkeleton(cornerRadius: 22)
                        .frame(height: 44)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 24)

                BeansSongRowsLoadingState(rowCount: 8, coverSize: 40, showsRank: true, horizontalPadding: 16)
            }
            .padding(.top, 6)
            .padding(.bottom, 170)
        }
        .beansScrollIndicatorsHidden()
    }

    private var hotSongsHeaderBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("热门歌曲")
                    .font(BeansFont.appFont(17, .bold))
                    .foregroundStyle(Color.beansLabel)
                Spacer(minLength: 0)
                // 播放全部已由头部承担，这里只保留批量下载，和标题同一行右对齐。
                if downloadFeatureUnlocked, displayedHotSongs.count > 1 {
                    GlassIconButton(systemName: "arrow.down.to.line.compact", size: 44, forceLiquid: true) {
                        BeansHaptics.tap()
                        showBatchDownload = true
                    }
                    .accessibilityLabel("批量下载")
                    .help("批量下载")
                }
            }
            .frame(minHeight: 44)
            .padding(.horizontal, 16)
            if hotSongs.isEmpty {
                Text("暂无歌曲")
                    .font(BeansFont.appFont(13))
                    .foregroundStyle(Color.beansComment)
                    .padding(.horizontal, 16)
            }
        }
    }

    /// 每一行都是整页 LazyVStack 的直接子项，滚到哪建到哪。
    @ViewBuilder
    private var hotSongsRows: some View {
                    ForEach(Array(displayedHotSongs.enumerated()), id: \.element.identityKey) { index, song in
                        Button {
                            BeansHaptics.tap()
                            player.play(songs: displayedHotSongs, startAt: index)
                        } label: {
                            HStack(spacing: 12) {
                                Text("\(index + 1)")
                                    .font(BeansFont.appFont(13, .semibold, .rounded))
                                    .foregroundStyle(index < 3 ? Color.beansAmber : Color.beansComment)
                                    .monospacedDigit()
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                    .frame(width: 32, alignment: .trailing)
                                CoverImage(url: song.coverURL, song: song, size: 40, cornerRadius: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(song.name)
                                            .font(BeansFont.appFont(14, .medium))
                                            .foregroundStyle(Color.beansLabel)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                            .layoutPriority(1)
                                        if showSongVIPBadge, song.isVIP {
                                            VIPBadgeView(text: "VIP")
                                        }
                                    }
                                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                                    Text(song.album)
                                        .font(BeansFont.appFont(11))
                                        .foregroundStyle(Color.beansComment)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 16)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                player.playNext(song)
                            } label: {
                                Label("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward")
                            }
                            Button {
                                player.play(songs: displayedHotSongs, startAt: index)
                            } label: {
                                Label("立即播放", systemImage: "play.fill")
                            }
                        }
                    }
    }

    private var displayedHotSongs: [Song] {
        let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else { return hotSongs }
        return hotSongs.filter { song in
            song.name.lowercased().contains(kw)
                || song.artists.lowercased().contains(kw)
                || song.album.lowercased().contains(kw)
        }
    }

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            albumShelf(title: "专辑", albums: studioAlbums)
            albumShelf(title: "EP 与单曲", albums: epsAndSingles)
        }
    }

    private var studioAlbums: [Album] {
        albums.filter { !$0.isEPOrSingle }
    }

    private var epsAndSingles: [Album] {
        albums.filter(\.isEPOrSingle)
    }

    @ViewBuilder
    private func albumShelf(title: String, albums: [Album]) -> some View {
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(BeansFont.appFont(17, .bold))
                    .foregroundStyle(Color.beansLabel)
                    .padding(.horizontal, 16)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(albums) { album in
                            Button {
                                openAlbum(album)
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    CoverImage(url: album.coverURL, size: 160, cornerRadius: 12)
                                    Text(album.name)
                                        .font(BeansFont.appFont(13, .medium))
                                        .foregroundStyle(Color.beansLabel)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                        .frame(width: 160, alignment: .leading)
                                    Text(album.releaseCaption)
                                        .font(BeansFont.appFont(11))
                                        .foregroundStyle(Color.beansComment)
                                        .lineLimit(1)
                                        .frame(width: 160, alignment: .leading)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func openAlbum(_ album: Album) {
        BeansHaptics.tap()
        selectedAlbum = album
    }

    /// 看门狗放在 onAppear 里起，不依赖 load() 走到哪一步：骨架屏一旦超过 15 秒，
    /// 一律退出并给出重试入口，不再出现停不下来的骨架屏。
    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled, loading else { return }
            BeansLogger.shared.log("歌手主页加载超时 name=\(artistName)", level: .error)
            errorMessage = "加载超时"
            loading = false
        }
    }

    private func load() async {
        let started = Date()

        let cache = ArtistHomeCache.shared
        if let cached = cache.cached(for: cacheKey) {
            artist = cached.artist ?? artist
            hotSongs = ArtistHomeLoader.creditedSongs(cached.songs, name: artistName, artist: artist)
            albums = cached.albums
            loading = false
            errorMessage = nil
            if cache.isFresh(cached), !BeansNetworkStatus.shared.isReachable {
                return
            }
        } else {
            loading = true
        }
        errorMessage = nil

        // 整条链在后台串行执行：页面只等一个结果，主线程不再参与任何请求或磁盘工作。
        let request = ArtistHomeRequest(
            artistName: artistName,
            source: artistSource,
            artistID: artistID,
            seedArtist: artist,
            seedSongs: hotSongs,
            seedAlbums: albums,
            cacheKey: cacheKey
        )
        let snapshot = await ArtistHomeLoader.load(request)
        guard !Task.isCancelled else {
            return
        }
        if let resolved = snapshot.artist { artist = resolved }
        if !snapshot.songs.isEmpty { hotSongs = snapshot.songs }
        if !snapshot.albums.isEmpty { albums = snapshot.albums }
        withAnimation(.easeOut(duration: 0.25)) { partialTimedOut = snapshot.timedOut }
        if !hotSongs.isEmpty || !albums.isEmpty {
            // 数据已经到手：清掉看门狗或上一次失败留下的错误，别让错误页盖住内容。
            errorMessage = nil
        } else if let message = snapshot.errorMessage {
            errorMessage = message
        }
        loading = false
        bannerRetrying = false
    }

    /// 带硬超时的 await：超时或任务失败都返回 fallback，调用方永远能继续往下走。
}


/// 歌手页的滚动进度：几何只读、写回节流。
///
/// 1. 只在主线程 runloop 下一轮写一次，不在布局回调里直接改状态；
/// 2. 进度跨过 1% 才写，滚动过程中不会每点都重排；
/// 3. 首屏布局结束后才开闸（`open`），第一屏那 60 行的布局不会再被几何回调打断。
final class ArtistScrollProgress: ObservableObject {
    @Published private(set) var progress: CGFloat = 0

    private var span: CGFloat = 273
    private var pending: CGFloat = 0
    private var appliedOffset: CGFloat = -1
    private var scheduled = false
    private var ready = false

    func open(span: CGFloat) {
        self.span = max(44, span)
        ready = true
    }

    func close() {
        ready = false
        scheduled = false
        pending = 0
        appliedOffset = -1
        if progress != 0 { progress = 0 }
    }

    func submit(_ offset: CGFloat) {
        guard ready else { return }
        pending = offset
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            guard self.ready else { return }
            // 按点算：跨过 1 点才写一次。按百分比会在慢拖时一格一格地跳。
            guard abs(self.pending - self.appliedOffset) >= 1 else { return }
            self.appliedOffset = self.pending
            let next = min(1, max(0, self.pending / self.span))
            guard abs(next - self.progress) > 0.0005 else { return }
            self.progress = next
        }
    }
}

/// 一次几何读数：偏移 + 第一屏是否已经排完。
struct ArtistScrollSnapshot: Equatable {
    let offset: CGFloat
    let laidOut: Bool
}
