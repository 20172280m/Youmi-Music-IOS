import SwiftUI
import UIKit
import Combine

// Reconstruction, not recovered implementation. Binary evidence confirms the nominal
// overlay/button/panel types, weak manager.player, draggable button, preference key,
// and accessibility identifier below. Scene ownership, non-key presentation, throttling,
// timeline UI and tests are new safety-oriented implementation choices.
// See .airbuild/reverse/lyric-debug-evidence.md for addresses and limitations.

enum LyricDebugPreferences {
    /// Original 2.0.3 preference. Missing value means disabled; Close persists false.
    static let enabledKey = "beans.developer.lyricDebugger"
}

/// Stateless upper-bound lookup: before the first line => nil; exact boundaries are
/// inclusive; the last duplicate wins. A backward seek needs no cursor reset.
/// Input timestamps must be finite and sorted in ascending order.
enum LyricDebugTimeline {
    static func hitIndex(in timestamps: [Double], at time: Double) -> Int? {
        guard time.isFinite else { return nil }
        var low = 0
        var high = timestamps.count
        while low < high {
            let middle = low + (high - low) / 2
            if timestamps[middle] <= time { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : low - 1
    }

    /// Preserve source order at duplicate timestamps, discarding unusable times only.
    static func orderedLines(_ lines: [LyricLine]) -> [LyricLine] {
        lines.enumerated().filter { $0.element.time.isFinite }.sorted {
            $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time
        }.map(\.element)
    }

    /// Only report a declared raw offset if one actually exists. Values are milliseconds,
    /// matching LyricParser; parsed line times already include this offset.
    static func declaredOffsetMilliseconds(in raw: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"\[offset:([+-]?\d+)\]"#),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let range = Range(match.range(at: 1), in: raw),
              let value = Double(raw[range]), value.isFinite else { return nil }
        return value
    }
}

/// Integrate once at app-root appearance: shared.configure(player: player).
/// Safe to call repeatedly, including after another scene appears. Settings can embed
/// LyricDebugSettingsControl or use setEnabled(_:). All UI/lifecycle work is main-actor.
/// No audio commands, session configuration, remote controls or Now Playing writes.
@MainActor
final class LyricDebugOverlayWindow {
    static let shared = LyricDebugOverlayWindow()
    private weak var player: PlayerManager?
    private var hosts: [String: LyricDebugButtonController] = [:]
    private var observers = Set<AnyCancellable>()
    private var supervisor: Timer?
    private var defaultsObserver: AnyCancellable?
    private var isEnabled = false
    private var liveLyrics: LyricDebugInput?
    /// 桥接诊断：播放页调用次数 / 被 songKey 拒收次数，用来判断面板为什么拿不到歌词。
    private var bridgeCalls = 0
    private var bridgeRejected = 0

    private init() {}

    func configure(player: PlayerManager) {
        if self.player !== player {
            removeAllWindows()
            liveLyrics = nil
            self.player = player
        }
        if defaultsObserver == nil {
            defaultsObserver = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in self?.applyStoredPreference() }
                }
        }
        applyStoredPreference()
    }

    func setEnabled(_ enabled: Bool) {
        if UserDefaults.standard.bool(forKey: LyricDebugPreferences.enabledKey) != enabled {
            UserDefaults.standard.set(enabled, forKey: LyricDebugPreferences.enabledKey)
        }
        applyStoredPreference()
    }

    /// Optional live bridge from PlayerView's existing parsed lyric array. This source's
    /// PlayerManager owns the clock, NOT the lyrics. No fetching is performed here.
    /// Supply the actual song identity to reject stale asynchronous results. Raw/format
    /// metadata are optional: absent values are omitted rather than guessed.
    func updateLyrics(_ lines: [LyricLine], forSongKey songKey: String,
                      wordPayloadBytes: Int? = nil, wordFormat: LyricWordFormat? = nil) {
        // 记录与开关无关：面板晚于歌词加载打开时也要能看到界面正在用的这份歌词。
        // 播放器尚未接入（启动早期）时也先记下，接入后再由 songKey 校验是否过期。
        bridgeCalls += 1
        if let currentKey = player?.currentSong?.identityKey, currentKey != songKey {
            bridgeRejected += 1
            return
        }
        liveLyrics = LyricDebugInput(songKey: songKey, lines: LyricDebugTimeline.orderedLines(lines),
                                    wordPayloadBytes: wordPayloadBytes,
                                    parserFormat: wordFormat?.rawValue, isLive: true)
        guard isEnabled else { return }
        for controller in hosts.values {
            controller.noteLivePush(lines: lines.count)
            controller.refreshNow()
        }
    }

    private func applyStoredPreference() {
        let enabled = UserDefaults.standard.bool(forKey: LyricDebugPreferences.enabledKey)
        isEnabled = enabled
        guard enabled, player != nil else {
            observers.removeAll()
            stopSupervisor()
            // 保留最近一次界面歌词：中途打开开关时也能立刻看到界面正在用的那份歌词。
            // 换歌后由 reconcileScenes 按 songKey 丢掉过期数据。
            removeAllWindows()
            return
        }
        if observers.isEmpty {
            // Receive notifications on main, then explicitly enter main-actor isolation.
            // Reconciliation queries current scene state, not stale notification payloads.
            for name in [UIScene.didActivateNotification, UIScene.willDeactivateNotification,
                         UIScene.didEnterBackgroundNotification, UIScene.didDisconnectNotification,
                         UIWindow.didBecomeKeyNotification, UIScreen.didConnectNotification,
                         Notification.Name("UIAccessibilityScreenChangedNotification"), UIApplication.didBecomeActiveNotification] {
                NotificationCenter.default.publisher(for: name)
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] _ in
                        Task { @MainActor [weak self] in self?.reconcileScenes() }
                    }.store(in: &observers)
            }
        }
        reconcileScenes()
    }

    /// 0.4 秒巡检一次：最上层变了（播放页开了/关了）就把浮层重挂过去。
    private func startSupervisor() {
        supervisor?.invalidate()
        supervisor = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.superviseOverlay() }
        }
    }

    private func stopSupervisor() {
        supervisor?.invalidate()
        supervisor = nil
    }

    private func reconcileScenes() {
        guard isEnabled, let player else { removeAllWindows(); return }
        // Never attach to CarPlay/external-display scenes; one overlay per active app
        // scene. Deactivation destroys UI and its refresh task, including open panels.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.filter {
            $0.session.role == .windowApplication && $0.activationState == .foregroundActive
        }
        let activeIDs = Set(scenes.map { $0.session.persistentIdentifier })
        for id in Array(hosts.keys) where !activeIDs.contains(id) { removeWindow(id) }
        // 只在播放器已经有歌、且歌不同名时丢弃；启动恢复阶段 currentSong 还是 nil，
        // 那时不能把刚记录下来的界面歌词清掉。
        if let current = player.currentSong?.identityKey, liveLyrics?.songKey != current { liveLyrics = nil }
        for scene in scenes {
            let id = scene.session.persistentIdentifier
            // 悬浮按钮放回独立窗口：窗口里只有一个 52pt 的按钮（面板打开时是面板矩形），
            // 其余位置的命中测试返回 nil，触摸照常落到下面的应用界面。
            // 挂成子控制器会整屏盖住应用界面，热歌榜这类页面会点不动、读屏也读不到。
            if let existing = hosts[id], existing.parent != nil { continue }
            if hosts[id] != nil { removeWindow(id) }
            let controller = LyricDebugButtonController(
                player: player,
                input: { [weak self] in self?.liveLyrics },
                stats: { [weak self] in
                    guard let self else { return "—" }
                    return "\(self.bridgeCalls) / \(self.bridgeRejected)"
                },
                onClose: { [weak self] in self?.setEnabled(false) })
            // 不再用旁挂窗口：播放页这类全屏呈现期间系统只把触摸交给呈现层自己的窗口，
            // 旁挂窗口画得出来却收不到事件。改成作为子控制器挂到最上层视图里，
            // 触摸走应用自己的命中链；穿透过滤由 LyricDebugPassthroughView 负责。
            hosts[id] = controller
            attach(controller)
        }
        superviseOverlay()
    }

    private func removeWindow(_ id: String) {
        guard let controller = hosts.removeValue(forKey: id) else { return }
        controller.tearDown()
        detach(controller)
    }

    /// 当前最上层的视图控制器：有播放页/弹层时是它们，否则是主界面。
    private func topPresenter() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        let windows = scenes.flatMap(\.windows)
        let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    private func attach(_ controller: LyricDebugButtonController) {
        guard let top = topPresenter(), top.view.window != nil else { return }
        if controller.parent === top { return }
        detach(controller)
        top.addChild(controller)
        controller.view.frame = top.view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        top.view.addSubview(controller.view)
        controller.didMove(toParent: top)
        controller.placeBubbleWindow()
    }

    private func detach(_ controller: LyricDebugButtonController) {
        guard controller.parent != nil || controller.view.superview != nil else { return }
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
    }

    /// 最上层会变（打开/关闭播放页、弹层进出）：巡检一次，父视图不是当前最上层就重挂。
    private func superviseOverlay() {
        guard !hosts.isEmpty else { return }
        let top = topPresenter()
        for controller in hosts.values where controller.parent !== top {
            attach(controller)
        }
    }

    /// 不再按“有没有弹层”收起调试窗。
    /// 播放页在 iOS 27 上是按 sheet 呈现的，以前这里会把它当弹层、把窗口藏起来，
    /// 结果播放页上按钮直接消失（屏幕上剩的那个波形圆圈是播放页自己的控件）。
    /// 调试窗现在层级高于播放页，且窗口外触摸一律让给应用，没有必要再藏。
    private func updateOverlayVisibility() {}

    private func removeAllWindows() {
        for id in Array(hosts.keys) { removeWindow(id) }
    }
}

@MainActor
struct LyricDebugSettingsControl: View {
    @AppStorage(LyricDebugPreferences.enabledKey) private var enabled = false

    var body: some View {
        Toggle(isOn: $enabled) {
            Label(beansLocalized("歌词调试悬浮窗", "Floating lyric debugger"), systemImage: "waveform.path.ecg")
        }
        .accessibilityHint(beansLocalized("只读歌词时间轴，不影响播放。关闭窗口会同时关闭此开关。",
                                         "Read-only timeline; does not change playback. Closing the window also turns this off."))
        .onChange(of: enabled) { _, value in LyricDebugOverlayWindow.shared.setEnabled(value) }
    }
}

@MainActor
private final class LyricDebugPassthroughView: UIView {
    /// 只有按钮（或打开的面板）所在的矩形接收触摸，其余区域穿透给下面的应用界面。
    var isPointInteractive: ((CGPoint) -> Bool)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isPointInteractive?(point) ?? false else { return nil }
        return super.hitTest(point, with: event)
    }
}

private struct LyricDebugInput {
    let songKey: String
    let lines: [LyricLine]
    /// 逐字歌词载荷的 UTF-8 字节数；该来源没有逐字载荷时为 nil。
    let wordPayloadBytes: Int?
    let parserFormat: String?
    let isLive: Bool
}

@MainActor
private final class LyricDebugModel: ObservableObject {
    @Published private(set) var songTitle = ""
    @Published private(set) var artist = ""
    @Published private(set) var progress: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var userOffset: Double = 0
    @Published private(set) var lines: [LyricLine] = []
    @Published private(set) var hitIndex: Int?
    @Published private(set) var wordPayloadBytes: Int?
    @Published private(set) var bridgeSummary = "—"
    @Published private(set) var parserFormat: String?
    @Published private(set) var isLive = false
    @Published private(set) var karaokeEnabled = true
    @Published private(set) var wordSegmentCount = 0
    @Published private(set) var platformSongID = "—"
    /// 诊断用：这一份歌词来自界面实时数组还是本地缓存（原版无此行，排查完可去）。
    @Published private(set) var lyricSource = "—"
    /// 诊断用：播放页把界面歌词推给面板的次数与行数（排查完可去）。
    @Published private(set) var livePushCount = 0
    @Published private(set) var livePushLines = 0
    /// 面板上“检测当前歌词”的结论；初始状态与 2.0.3 的提示一致。
    @Published private(set) var detectionText = beansLocalized("等待歌曲、歌词响应或界面记录", "Waiting for a song, lyric response or UI record")
    private(set) var lyricRequestFailed = false
    private weak var player: PlayerManager?
    private let input: () -> LyricDebugInput?
    private let stats: () -> String
    private var refreshTask: Task<Void, Never>?
    private var songKey: String?
    private var cachedPayload: String?
    private var lastCacheRead = Date.distantPast
    private var timestamps: [Double] = []

    init(player: PlayerManager, input: @escaping () -> LyricDebugInput?,
         stats: @escaping () -> String = { "—" }) {
        self.player = player
        self.input = input
        self.stats = stats
    }

    deinit { refreshTask?.cancel() }

    func start() {
        guard refreshTask == nil else { return }
        refresh()
        // 4 Hz only while a panel is visible. Reads PlaybackClock, never extrapolates
        // wall time during buffering/pause and never subscribes to 120 Hz lyric frames.
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    func stop() { refreshTask?.cancel(); refreshTask = nil }

    func noteLivePush(lines: Int) {
        livePushCount += 1
        livePushLines = lines
    }

    func refresh() {
        guard let player else { stop(); return }
        let song = player.currentSong
        if songKey != song?.identityKey {
            songKey = song?.identityKey
            cachedPayload = nil
            lastCacheRead = .distantPast
            apply(nil)
        }
        let title = song?.name ?? beansLocalized("暂无播放歌曲", "No current song")
        if songTitle != title { songTitle = title }
        if artist != (song?.artists ?? "") { artist = song?.artists ?? "" }
        let elapsed = player.clock.progress
        if progress != elapsed { progress = elapsed }
        if duration != player.clock.duration { duration = player.clock.duration }
        let offset = UserDefaults.standard.double(forKey: LyricTiming.userOffsetKey)
        if userOffset != offset { userOffset = offset }
        if let live = input(), live.songKey == songKey, !live.lines.isEmpty {
            apply(live)
            if lyricSource != "界面实时" { lyricSource = "界面实时" }
        } else if Date().timeIntervalSince(lastCacheRead) >= 1 {
            lastCacheRead = Date()
            refreshCache(for: song)
        }
        let hit = LyricDebugTimeline.hitIndex(in: timestamps,
                                             at: LyricTiming.effectiveProgress(progress, userOffset: userOffset))
        if hitIndex != hit { hitIndex = hit }
        let summary = stats()
        if bridgeSummary != summary { bridgeSummary = summary }
        let karaoke = (UserDefaults.standard.object(forKey: "beans.lyricKaraokeEnabled") as? Bool) ?? true
        if karaokeEnabled != karaoke { karaokeEnabled = karaoke }
        let identity = song.map { $0.source.rawValue.uppercased() + " · " + $0.identityKey } ?? "—"
        if platformSongID != identity { platformSongID = identity }
    }

    /// 当前显示行的时间轴时间；没有命中行时退回为 nil。
    var validLyricTime: Double? {
        guard let hitIndex, lines.indices.contains(hitIndex) else { return nil }
        return lines[hitIndex].time
    }

    /// “检测当前歌词”：根据已加载数据给出可判定的结论，不联网、不修改播放。
    func detectCurrentLyrics() {
        if player?.currentSong == nil || lines.isEmpty {
            detectionText = lyricRequestFailed
                ? beansLocalized("本次歌词请求失败，需检查日志中的错误记录", "This lyric request failed; check the logged error")
                : beansLocalized("等待歌曲、歌词响应或界面记录", "Waiting for a song, lyric response or UI record")
        } else if wordSegmentCount == 0 {
            detectionText = beansLocalized("本次接口未返回逐字数据，不能据此判断其他版本", "The response had no word timeline; this says nothing about other versions")
        } else if !karaokeEnabled {
            detectionText = beansLocalized("逐字歌词开关已关闭", "Word-by-word lyrics are turned off")
        } else {
            detectionText = beansLocalized("界面已收到逐字时间轴，需结合播放采样确认同步", "The UI received a word timeline; sample playback to confirm sync")
        }
    }

    /// “检测逐字片段”：只报告当前已解析出的片段数量。
    func detectWordSegments() {
        detectionText = wordSegmentCount > 0
            ? String(format: beansLocalized("已加载逐字片段 %d 个", "%d word segments loaded"), wordSegmentCount)
            : beansLocalized("接口含逐字数据，但未解析出有效逐字时间轴", "The response had word data but no usable word timeline was parsed")
    }

    /// “导出检测日志”：把当前面板数据写成一份可分享文本。
    func exportReport() -> String {
        var linesOut: [String] = ["Beans Music 悬浮歌词调试", "导出时间：\(Date())"]
        linesOut.append("平台与歌曲 ID：\(platformSongID)")
        linesOut.append("音频实际时间：\(String(format: "%.3f", progress)) s / \(String(format: "%.3f", duration)) s")
        linesOut.append("歌词有效时间：\(validLyricTime.map { String(format: "%.3f s", $0) } ?? "—")")
        linesOut.append("已加载歌词行：\(lines.count)")
        linesOut.append("已加载逐字片段：\(wordSegmentCount)")
        linesOut.append("逐字歌词开关：\(karaokeEnabled ? "开" : "关")")
        linesOut.append("解析输入格式：\(parserFormat ?? "—")")
        linesOut.append("用户偏移：\(String(format: "%+.3f", userOffset)) s")
        linesOut.append("结论：\(detectionText)")
        for (index, line) in lines.enumerated() {
            linesOut.append(String(format: "#%d %7.3f %@", index + 1, line.time, line.text))
        }
        return linesOut.joined(separator: "\n")
    }

    private func apply(_ value: LyricDebugInput?) {
        let newLines = value?.lines ?? []
        if lines != newLines {
            lines = newLines
            timestamps = newLines.map(\.time)
            wordSegmentCount = newLines.reduce(0) { $0 + ($1.words?.count ?? 0) }
        }
        if wordPayloadBytes != value?.wordPayloadBytes { wordPayloadBytes = value?.wordPayloadBytes }
        if parserFormat != value?.parserFormat { parserFormat = value?.parserFormat }
        if isLive != (value?.isLive ?? false) { isLive = value?.isLive ?? false }
    }

    private func refreshCache(for song: Song?) {
        guard let song, let cached = LyricsCache.shared.value(for: Self.cacheKey(for: song)) else {
            if cachedPayload != nil { lyricRequestFailed = lines.isEmpty }
            cachedPayload = nil
            apply(nil)
            return
        }
        // Include all parser inputs in change detection; do not parse the same LRC at 4Hz.
        // JSON length-prefixing avoids collisions when lyrics contain separator characters.
        let payload = [cached.lyric, cached.translation ?? "", cached.wordTiming ?? "", cached.wordFormat?.rawValue ?? ""]
            .map { "\($0.utf8.count):\($0)" }.joined()
        guard payload != cachedPayload || isLive else { return }
        cachedPayload = payload
        let parsed = LyricParser.parse(cached.lyric, translationRaw: cached.translation,
                                       wordRaw: cached.wordTiming, wordFormat: cached.wordFormat)
        lyricRequestFailed = parsed.isEmpty
        if lyricSource != "本地缓存" { lyricSource = "本地缓存" }
        let wordFormat = cached.wordTiming?.isEmpty == false ? cached.wordFormat?.rawValue : nil
        apply(LyricDebugInput(songKey: song.identityKey, lines: LyricDebugTimeline.orderedLines(parsed),
                             wordPayloadBytes: cached.wordTiming?.utf8.count,
                             parserFormat: wordFormat.map { "LRC + \($0)" } ?? "LRC", isLive: false))
    }

    /// Same cache identities as PlayerView.loadLyrics; this is a read-only fallback,
    /// not evidence that the cached array is the currently displayed live lyric array.
    private static func cacheKey(for song: Song) -> String {
        switch song.source {
        case .webdav: return "webdav:" + song.identityKey
        case .kugou: return "kugou:\(song.kugouHash ?? song.identityKey)"
        case .qq: return "qq:\(song.qqMid ?? song.identityKey)"
        case .kuwo, .migu: return "\(song.source.rawValue):\(song.id)"
        case .qishui: return "qishui:\(song.qishuiID ?? song.identityKey)"
        case .bilibili: return "bilibili:\(song.bilibiliID ?? song.identityKey)"
        default: return "netease:\(song.id)"
        }
    }
}

/// 只承载调试按钮的窗口。
/// 播放页是按 sheet 呈现的，那期间系统只把触摸发给能为 key 的窗口；
/// 这里必须允许成为 key，否则按钮看得见却收不到任何触摸（拖动、点击全落空）。
/// 不会自己抢焦点：只有用户按住按钮那一小块时底层窗口才可能被点中。
@MainActor
final class LyricDebugHostingWindow: UIWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeFirstResponder: Bool { false }
}

@MainActor
private final class LyricDebugButtonController: UIViewController {
    private let button = UIButton(type: .system)
    private let model: LyricDebugModel
    private let onClose: () -> Void
    private var panel: UIHostingController<LyricDebugPanel>?
    private var dragStart = CGPoint.zero
    private var hasPosition = false
    /// 让路窗口期：这段时间窗口不接收任何触摸，点击直接落到下面的应用界面。
    private var passThroughUntil: Date?

    init(player: PlayerManager, input: @escaping () -> LyricDebugInput?,
         stats: @escaping () -> String, onClose: @escaping () -> Void) {
        self.model = LyricDebugModel(player: player, input: input, stats: stats)
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let passthrough = LyricDebugPassthroughView()
        passthrough.isPointInteractive = { [weak self] point in
            guard let self else { return false }
            return self.containsInteractivePoint(point)
        }
        view = passthrough
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        button.setImage(UIImage(systemName: "waveform.path.ecg"), for: .normal)
        button.backgroundColor = .secondarySystemBackground
        button.tintColor = .label
        button.layer.cornerRadius = 26
        button.layer.borderWidth = 1
        button.layer.borderColor = UIColor.separator.cgColor
        button.alpha = 0.92
        button.accessibilityIdentifier = "beans.lyricDebug.floating"
        button.accessibilityLabel = beansLocalized("歌词调试", "Lyric debugger")
        button.accessibilityHint = beansLocalized("轻点打开；可拖动位置；自定操作可关闭。", "Tap to open. Drag to move. Use the custom action to close.")
        button.accessibilityCustomActions = [UIAccessibilityCustomAction(
            name: beansLocalized("关闭歌词调试", "Close lyric debugger"), target: self, selector: #selector(closeFromAccessibility))]
        button.addTarget(self, action: #selector(openPanel), for: .touchUpInside)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
        button.addGestureRecognizer(pan)
        view.addSubview(button)
    }

    private static let bubbleSize: CGFloat = 76
    private static let buttonSize: CGFloat = 52

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        button.bounds.size = CGSize(width: Self.buttonSize, height: Self.buttonSize)
        if panel == nil && !hasPosition {
            button.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        }
        if let panel {
            panel.view.frame = view.bounds
        }
    }

    /// 按钮放到记住的位置（父视图是整屏，坐标直接用父视图的）。
    func placeBubbleWindow() {
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }
        button.center = savedCenter(in: bounds, insets: view.safeAreaInsets)
        hasPosition = true
    }

    /// 面板跟按钮同一个父视图，铺满这一步不再需要动窗口。
    private func expandWindow() { view.setNeedsLayout() }

    /// 收起面板后按钮回到记住的位置。
    private func shrinkWindow() {
        // 父视图永远是整屏，按钮位置只认记忆值，不再从视图中心推算（那样收起会跳正中）。
        placeBubbleWindow()
    }

    private func savedCenter(in bounds: CGRect, insets: UIEdgeInsets) -> CGPoint {
        let defaults = UserDefaults.standard
        let minX = 26 + insets.left
        let maxX = bounds.width - 26 - insets.right
        let minY = 26 + insets.top + 8
        let maxY = bounds.height - 26 - insets.bottom - 8
        if defaults.object(forKey: Self.xKey) != nil, defaults.object(forKey: Self.yKey) != nil {
            let x = bounds.width * defaults.double(forKey: Self.xKey)
            let y = bounds.height * defaults.double(forKey: Self.yKey)
            return CGPoint(x: min(max(x, minX), max(minX, maxX)), y: min(max(y, minY), max(minY, maxY)))
        }
        // 默认：右侧贴边、偏上，避开播放按钮和底部那一排。
        return defaultSpot(bounds: bounds, insets: insets)
    }

    /// 默认位置：右侧贴边，从偏上往下找一个不压可点控件的高度。
    private func defaultSpot(bounds: CGRect, insets: UIEdgeInsets) -> CGPoint {
        let x = bounds.width - 26 - insets.right
        for ratio in stride(from: 0.24, through: 0.80, by: 0.07) {
            let candidate = CGPoint(x: x, y: insets.top + (bounds.height - insets.top - insets.bottom) * ratio)
            if !appControl(at: candidate) { return candidate }
        }
        return CGPoint(x: x, y: insets.top + (bounds.height - insets.top - insets.bottom) * 0.62)
    }

    func containsInteractivePoint(_ point: CGPoint) -> Bool {
        if let until = passThroughUntil, Date() < until { return false }
        if let panel { return panel.view.frame.contains(point) }
        return !button.isHidden && button.frame.contains(point)
    }

    /// 按钮底下如果是应用自己的可点控件，第一次点按钮先让路：隐藏触摸、变淡提示，
    /// 紧接着的第二下就落到原控件上。按钮压在功能上时，功能永远点得到。
    private func yieldToControlUnderneathIfNeeded() -> Bool {
        guard appControl(at: view.convert(button.center, to: nil)) else { return false }
        passThroughUntil = Date().addingTimeInterval(1.2)
        UIView.animate(withDuration: 0.15) { self.button.alpha = 0.28 }
        BeansHaptics.tap()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            self.passThroughUntil = nil
            UIView.animate(withDuration: 0.2) { self.button.alpha = 1 }
        }
        return true
    }

    /// 屏幕坐标点上是否是应用自己的可交互控件。
    private func appControl(at screenPoint: CGPoint) -> Bool {
        guard let ourWindow = view.window else { return false }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for other in scene.windows where other !== ourWindow && !other.isHidden {
                let point = other.convert(screenPoint, from: nil)
                guard other.bounds.contains(point) else { continue }
                guard let hit = other.hitTest(point, with: nil) else { continue }
                if let control = hit as? UIControl, control.isUserInteractionEnabled { return true }
                if let recognizers = hit.gestureRecognizers, !recognizers.isEmpty { return true }
                if hit.isAccessibilityElement, hit.accessibilityTraits.contains(.button) { return true }
            }
        }
        return false
    }

    var isPanelOpen: Bool { panel != nil }

    func refreshNow() { if panel != nil { model.refresh() } }

    func noteLivePush(lines: Int) { model.noteLivePush(lines: lines) }

    func tearDown() {
        minimizePanel()
        button.removeFromSuperview()
    }

    @objc private func closeFromAccessibility() -> Bool { onClose(); return true }

    @objc private func openPanel() {
        guard panel == nil else { return }
        if yieldToControlUnderneathIfNeeded() { return }
        expandWindow()
        let host = UIHostingController(rootView: LyricDebugPanel(model: model, onClose: onClose,
                                                                onMinimize: { [weak self] in self?.minimizePanel() },
                                                                onExport: { [weak self] in self?.shareReport() }))
        panel = host
        addChild(host)
        view.addSubview(host.view)
        host.didMove(toParent: self)
        host.view.layer.cornerRadius = 18
        host.view.clipsToBounds = true
        button.isHidden = true
        model.start()
        view.setNeedsLayout()
        view.layoutIfNeeded()
        UIAccessibility.post(notification: .screenChanged, argument: host.view)
    }

    /// 导出检测日志：把面板数据写成文本文件并弹出系统分享。
    private func shareReport() {
        let text = model.exportReport()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BeansLyricDebug-")
            .appendingPathComponent("lyric-debug.txt")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            ToastCenter.shared.show(beansLocalized("导出检测日志失败", "Could not export the debug log"))
            return
        }
        let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = view
        share.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        present(share, animated: true)
    }

    private func minimizePanel() {
        model.stop()
        if let host = panel {
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
            panel = nil
        }
        button.isHidden = false
        shrinkWindow()
        if viewIfLoaded?.window != nil { UIAccessibility.post(notification: .layoutChanged, argument: button) }
    }

    override func accessibilityPerformEscape() -> Bool { onClose(); return true }

    private static let xKey = "beans.lyricDebug.x"
    private static let yKey = "beans.lyricDebug.y"

    @objc private func drag(_ gesture: UIPanGestureRecognizer) {
        let bounds = view.bounds
        let insets = view.safeAreaInsets
        if gesture.state == .began { dragStart = button.center }
        let translation = gesture.translation(in: view)
        let proposed = CGPoint(x: dragStart.x + translation.x, y: dragStart.y + translation.y)
        button.center = clamp(proposed, bounds: bounds, insets: insets)
        if gesture.state == .ended || gesture.state == .cancelled {
            // 松手贴边停稳：靠哪边就近贴哪边，纵向保留拖到的位置。
            let left = button.center.x < bounds.midX
            let x = left ? bounds.minX + 26 + insets.left : bounds.maxX - 26 - insets.right
            UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut]) {
                self.button.center = CGPoint(x: x, y: self.button.center.y)
            }
            UserDefaults.standard.set(Double(button.center.x / max(1, bounds.width)), forKey: Self.xKey)
            UserDefaults.standard.set(Double(button.center.y / max(1, bounds.height)), forKey: Self.yKey)
        }
    }

    private func clamp(_ point: CGPoint, bounds: CGRect, insets: UIEdgeInsets) -> CGPoint {
        let minX = bounds.minX + 26 + insets.left
        let maxX = bounds.maxX - 26 - insets.right
        let minY = bounds.minY + 26 + insets.top + 8
        let maxY = bounds.maxY - 26 - insets.bottom - 8
        return CGPoint(x: min(max(point.x, minX), max(minX, maxX)),
                       y: min(max(point.y, minY), max(minY, maxY)))
    }
}

@MainActor
private struct LyricDebugPanel: View {
    @ObservedObject var model: LyricDebugModel
    let onClose: () -> Void
    let onMinimize: () -> Void
    let onExport: () -> Void
    @State private var followsPlayback = true

    var body: some View {
        NavigationStack {
            List {
                    Section(beansLocalized("检测数据", "Detection")) {
                        valueRow(beansLocalized("音频实际时间", "Actual audio time"), seconds(model.progress))
                        valueRow(beansLocalized("歌词有效时间", "Valid lyric time"), model.validLyricTime.map(seconds) ?? "—")
                        valueRow(beansLocalized("响应逐字字节", "Word payload bytes"),
                                 model.wordPayloadBytes.map { "\($0) B" } ?? "—")
                        valueRow(beansLocalized("已加载歌词行", "Loaded lyric lines"), "\(model.lines.count)")
                        valueRow(beansLocalized("已加载逐字片段", "Loaded word segments"), "\(model.wordSegmentCount)")
                        valueRow(beansLocalized("实际歌词界面", "Actual lyric UI"), model.karaokeEnabled
                                 ? beansLocalized("逐字显示已开启", "Word-by-word display is on")
                                 : beansLocalized("逐字歌词开关已关闭", "Word-by-word lyrics are off"))
                        valueRow(beansLocalized("平台与歌曲 ID", "Platform and song ID"), model.platformSongID)
                        valueRow(beansLocalized("歌词来源", "Lyric source"), model.lyricSource)
                        valueRow(beansLocalized("实时推送", "Live pushes"), "\(model.livePushCount) · \(model.livePushLines) 行")
                        valueRow(beansLocalized("桥接调用 / 拒收", "Bridge calls / rejected"), model.bridgeSummary)
                        HStack(spacing: 10) {
                            Button { model.detectCurrentLyrics() } label: {
                                Label(beansLocalized("检测当前歌词", "Check current lyrics"), systemImage: "checkmark.circle")
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("beans.lyricDebug.detect")
                            Button { model.detectWordSegments() } label: {
                                Label(beansLocalized("检测逐字片段", "Check word segments"), systemImage: "text.word.spacing")
                            }
                            .buttonStyle(.bordered)
                        }
                        Text(model.detectionText)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("beans.lyricDebug.conclusion")
                        Button { onExport() } label: {
                            Label(beansLocalized("导出检测日志", "Export debug log"), systemImage: "square.and.arrow.up")
                        }
                        .accessibilityIdentifier("beans.lyricDebug.export")
                    }
                    Section(beansLocalized("当前歌曲", "Current song")) {
                        Text(model.songTitle).font(.headline).fixedSize(horizontal: false, vertical: true)
                        if !model.artist.isEmpty { Text(model.artist).foregroundStyle(.secondary) }
                        valueRow(beansLocalized("播放时间", "Elapsed"), "\(seconds(model.progress)) / \(seconds(model.duration))")
                        valueRow(beansLocalized("用户偏移（秒）", "User offset (s)"), signed(model.userOffset))

                        if let format = model.parserFormat {
                            valueRow(beansLocalized("解析输入格式", "Parser input format"), format)
                        }
                        Text(model.isLive ? beansLocalized("来源：播放器提供的实时歌词", "Source: live lines supplied by player")
                             : beansLocalized("来源：本地歌词缓存快照（不主动联网）", "Source: local lyric cache snapshot (no fetching)"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section(beansLocalized("歌词时间轴", "Lyric timeline")) {
                        Toggle(beansLocalized("跟随当前行", "Follow current line"), isOn: $followsPlayback)
                        valueRow(beansLocalized("当前命中行", "Current hit line"),
                                 model.hitIndex.map { "\($0 + 1) / \(model.lines.count)" } ?? beansLocalized("无", "None"))
                        if model.lines.isEmpty {
                            Text(beansLocalized("暂无可用歌词。可打开播放器加载歌词后查看；调试器不会请求歌词或改变播放。",
                                                "No available lyrics. Open the player to load lyrics; the debugger never fetches lyrics or changes playback."))
                                .foregroundStyle(.secondary)
                        }
                        if !model.lines.isEmpty {
                            // 时间轴放在自己的滚动区里跟随当前行，检测数据固定在上方不被滚走。
                            ScrollViewReader { reader in
                                ScrollView {
                                    LazyVStack(alignment: .leading, spacing: 0) {
                                        ForEach(Array(model.lines.enumerated()), id: \.offset) { index, line in
                                            lyricRow(line, index: index).id(index)
                                        }
                                    }
                                }
                                .frame(height: 300)
                                .onAppear { scrollToHit(reader) }
                                .onChange(of: model.hitIndex) { _, _ in scrollToHit(reader) }
                                .onChange(of: followsPlayback) { _, _ in scrollToHit(reader) }
                                .onChange(of: model.lines) { _, _ in scrollToHit(reader) }
                            }
                        }
                    }
            }
            .navigationTitle(beansLocalized("歌词调试", "Lyric debugger"))
            .safeAreaInset(edge: .top, spacing: 0) {
                Text(BeansBuildStamp.text)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.vertical, 4)
                    .accessibilityIdentifier("beans.lyricDebug.buildStamp")
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onMinimize) { Image(systemName: "minus") }
                        .accessibilityLabel(beansLocalized("收起为悬浮按钮", "Minimize to floating button"))
                        .accessibilityIdentifier("beans.lyricDebug.minimize")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onClose) { Image(systemName: "xmark") }
                        .accessibilityLabel(beansLocalized("关闭歌词调试", "Close lyric debugger"))
                        .accessibilityIdentifier("beans.lyricDebug.close")
                }
            }
        }
        .accessibilityAction(.escape, onClose)
    }

    private func scrollToHit(_ reader: ScrollViewProxy) {
        guard followsPlayback, !UIAccessibility.isVoiceOverRunning, let hit = model.hitIndex else { return }
        // No repeated animated scrolls or unsolicited VoiceOver announcements at 4 Hz.
        reader.scrollTo(hit, anchor: .center)
    }

    private func valueRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).monospacedDigit().fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func lyricRow(_ line: LyricLine, index: Int) -> some View {
        let hit = model.hitIndex == index
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                if hit { Image(systemName: "arrow.right.circle.fill").accessibilityHidden(true) }
                Text("#\(index + 1) · \(seconds(line.time))").font(.caption.monospacedDigit())
            }.foregroundStyle(hit ? Color.accentColor : .secondary)
            Text(line.text.isEmpty ? beansLocalized("（空行）", "(Empty line)") : line.text)
                .fontWeight(hit ? .semibold : .regular)
                .fixedSize(horizontal: false, vertical: true)
            if let translation = line.translation, !translation.isEmpty {
                Text(translation).font(.caption).foregroundStyle(.secondary)
            }
        }
        .listRowBackground(hit ? Color.accentColor.opacity(0.13) : Color(uiColor: .secondarySystemGroupedBackground))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(hit ? .isSelected : [])
    }

    private func seconds(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return String(format: "%.3f s", value)
    }

    private func signed(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return String(format: "%+.3f", value)
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
