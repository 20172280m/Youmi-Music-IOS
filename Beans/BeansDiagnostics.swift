import Foundation
import SwiftUI
import UIKit
import CryptoKit

/// 全局诊断中心：记录用户操作、页面路由、网络摘要、性能快照和最近事件。
/// iOS 不能在进程被系统直接终止时可靠地拦截所有 Swift trap，因此原生崩溃仍由
/// CrashReporter 与 MetricKit 负责，这里保存崩溃前的上下文，方便下次启动定位。
final class BeansDiagnostics: ObservableObject {

    static let shared = BeansDiagnostics()

    @Published private(set) var breadcrumbCount = 0
    /// 诊断页「最近操作」列表的数据源：由同一条已落盘的日志行解析得到，不新增采集。
    @Published private(set) var recentEntries: [BeansDiagnosticEntry] = []
    @Published private(set) var lastRoute = "启动"
    @Published private(set) var lastSnapshotDate: Date?
    @Published private(set) var lastCrashFile: URL?
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) }
    }

    private static let enabledKey = "beans.diagnostics.enabled"
    private let lock = NSLock()
    private var breadcrumbs: [String] = []
    private var currentRoute = "启动"
    private var lastAction = "启动"
    private var started = false
    private var performanceTimer: DispatchSourceTimer?
    private var mainBeat = Date()
    private let maxBreadcrumbs = 80
    private let maxEntries = 80

    private init() {
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        lastCrashFile = Self.latestCrashFile()
    }

    func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()

        UIDevice.current.isBatteryMonitoringEnabled = true
        route("应用启动")
        recordAction("应用启动")
        startPerformanceSampler()
    }

    func route(_ name: String, file: String = #fileID, line: Int = #line, function: String = #function) {
        lock.lock()
        currentRoute = name
        lastAction = "进入页面：\(name)"
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.lastRoute = name }
        record("route=\(name)", level: .info, file: file, line: line, function: function)
    }

    func recordAction(_ action: String, file: String = #fileID, line: Int = #line, function: String = #function) {
        lock.lock()
        lastAction = action
        lock.unlock()
        record("action=\(action)", level: .debug, file: file, line: line, function: function)
    }

    /// 页面进入：走 route= 这条线，列表里归到「页面进入」。
    /// 开关文案承诺记录页面进入，所以主要页面都显式报一次自己的名字。
    func recordPage(_ name: String, file: String = #fileID, line: Int = #line, function: String = #function) {
        route(name, file: file, line: line, function: function)
    }

    /// 点击：走 action= 这条线，列表里归到「点击」，只记按钮名，不记输入内容。
    func recordTap(_ name: String, file: String = #fileID, line: Int = #line, function: String = #function) {
        recordAction("点击：\(name)", file: file, line: line, function: function)
    }

    func recordNetwork(url: URL, method: String, status: Int? = nil, duration: TimeInterval? = nil, error: String? = nil,
                       file: String = #fileID, line: Int = #line, function: String = #function) {
        var message = "network method=\(method) url=\(url.absoluteString)"
        if let status { message += " status=\(status)" }
        if let duration { message += String(format: " duration=%.0fms", duration * 1000) }
        if let error { message += " error=\(redact(error))" }
        record(message, level: error == nil ? .debug : .error, file: file, line: line, function: function)
    }

    func recordError(_ message: String, file: String = #fileID, line: Int = #line, function: String = #function) {
        record("error=\(redact(message))", level: .error, file: file, line: line, function: function)
    }

    func snapshot(reason: String = "手动快照") -> String {
        let text = diagnosticContext(reason: reason)
        record(text, level: .info)
        lastSnapshotDate = Date()
        return text
    }

    func exportLogURL() -> URL {
        let directory = logDirectory
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let file = directory.appendingPathComponent("BeansDiagnostics-\(formatter.string(from: Date())).txt")
        let crashText = Self.crashFiles(in: directory).prefix(6).compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n\n")
        let exportReason = "导出"
        let emptyCrashText = "暂无"
        let content = "Beans Music 全局诊断日志\n\(diagnosticContext(reason: exportReason))\n\n最近结构化日志：\n\(BeansLogger.shared.fullText)\n\n最近崩溃与系统诊断：\n\(crashText.isEmpty ? emptyCrashText : crashText)\n"
        try? content.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func clear() {
        BeansLogger.shared.clear()
        clearCachedState()
    }

    func clearCachedState() {
        lock.lock()
        breadcrumbs.removeAll()
        UserDefaults.standard.removeObject(forKey: "beans.diagnostics.breadcrumbs")
        UserDefaults.standard.removeObject(forKey: "beans.crash.recentEvents")
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastCrashFile = nil
            self.breadcrumbCount = 0
            self.recentEntries = []
        }
    }

    func record(_ message: String, level: BeansLogLevel = .debug, file: String = #fileID, line: Int = #line, function: String = #function) {
        guard enabled || level == .error || level == .fatal else { return }
        let context = diagnosticContext(reason: message, includeMetrics: false)
        let lineText = "\(context) file=\(URL(fileURLWithPath: file).lastPathComponent):\(line) function=\(function) content=\(redact(message))"
        lock.lock()
        breadcrumbs.append(lineText)
        if breadcrumbs.count > maxBreadcrumbs { breadcrumbs.removeFirst(breadcrumbs.count - maxBreadcrumbs) }
        let recent = breadcrumbs
        UserDefaults.standard.set(recent, forKey: "beans.diagnostics.breadcrumbs")
        lock.unlock()
        // 这两个值驱动 SwiftUI（计数、列表），只能回主线程写；record() 会被网络层、
        // 缓存队列这类后台上下文调到，直接写会把界面状态从后台线程发出去。
        DispatchQueue.main.async { [weak self] in self?.breadcrumbCount = recent.count }
        if let entry = BeansDiagnosticEntry(line: lineText) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var entries = self.recentEntries
                entries.append(entry)
                if entries.count > self.maxEntries { entries.removeFirst(entries.count - self.maxEntries) }
                self.recentEntries = entries
            }
        }
        BeansLogger.shared.log(lineText, level: level)
    }

    private func startPerformanceSampler() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "Beans.Diagnostics.Performance"))
        timer.schedule(deadline: .now() + 5, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self, self.enabled else { return }
            DispatchQueue.main.async { [weak self] in self?.mainBeat = Date() }
            self.record(self.diagnosticContext(reason: "性能采样"), level: .debug)
        }
        performanceTimer = timer
        timer.resume()
    }

    private func diagnosticContext(reason: String, includeMetrics: Bool = true) -> String {
        lock.lock()
        let currentRoute = self.currentRoute
        let action = lastAction
        lock.unlock()
        let now = ISO8601DateFormatter().string(from: Date())
        var text = "ts=\(now) levelContext route=\(currentRoute) action=\(action) reason=\(redact(reason))"
        if includeMetrics {
            let deviceDigest = SHA256.hash(data: Data(DeviceIdentity.userID.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12)
            let battery = UIDevice.current.batteryLevel >= 0 ? String(format: "%.0f%%", UIDevice.current.batteryLevel * 100) : "unknown"
            let storage = (try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
            text += " device=\(UIDevice.current.model) hardware=\(DeviceIdentity.hardwareModel) os=\(UIDevice.current.systemName)-\(UIDevice.current.systemVersion) app=\(BeansLogger.appVersion) build=\(build) deviceID=\(deviceDigest) network=\(BeansNetworkStatus.shared.connectionKind) reachable=\(BeansNetworkStatus.shared.isReachable) freeStorage=\(storage) battery=\(battery) freeMemory=\(ProcessInfo.processInfo.physicalMemory)"
        }
        return text
    }

    private func redact(_ value: String) -> String {
        value.replacingOccurrences(of: "(Authorization|Cookie|Set-Cookie|access_token|refresh_token|password|sign)[=:][^; ,&]+", with: "$1=[REDACTED]", options: .regularExpression)
    }

    /// 与原版一致的落盘位置：Application Support/BeansDiagnostics。
    /// 旧版本写在 Documents/BeansLogs，首次访问时把已有文件搬过来，不丢历史日志。
    static var logDirectoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("BeansDiagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        migrateLegacyLogsIfNeeded(to: url)
        return url
    }

    private static var didMigrateLegacyLogs = false
    private static func migrateLegacyLogsIfNeeded(to destination: URL) {
        guard !didMigrateLegacyLogs else { return }
        didMigrateLegacyLogs = true
        let legacy = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeansLogs", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil), !items.isEmpty else { return }
        for item in items {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            if !FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.moveItem(at: item, to: target)
            }
        }
    }

    private var logDirectory: URL { Self.logDirectoryURL }

    private static func crashFiles(in directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.lastPathComponent.hasPrefix("crash-") || $0.lastPathComponent.hasPrefix("metric-") }
            .sorted { modificationDate($0) > modificationDate($1) } ?? []
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func latestCrashFile() -> URL? {
        crashFiles(in: logDirectoryURL).first
    }
}

/// 诊断页列表里的一行。内容全部来自已经写下的日志行，只做字段拆分，不改采集。
struct BeansDiagnosticEntry: Identifiable, Equatable {
    enum Category: String, CaseIterable, Identifiable {
        case page, tap, network, error

        var id: String { rawValue }

        var title: String {
            switch self {
            case .page: return "页面进入"
            case .tap: return "点击"
            case .network: return "网络"
            case .error: return "异常"
            }
        }
    }

    let id = UUID()
    let date: Date
    let category: Category
    let content: String
    let position: String?

    init?(line: String) {
        guard let contentRange = line.range(of: " content=", options: .backwards) else { return nil }
        let content = String(line[contentRange.upperBound...])
        guard let category = Self.category(for: content) else { return nil }
        let head = String(line[..<contentRange.lowerBound])
        guard let tsRange = head.range(of: "ts=") else { return nil }
        let stamp = String(head[tsRange.upperBound...].prefix { $0 != " " })
        guard let date = Self.parseTimestamp(stamp) else { return nil }
        self.date = date
        self.category = category
        self.content = content
        self.position = Self.position(in: head)
    }

    init(date: Date, category: Category, content: String, position: String? = nil) {
        self.date = date
        self.category = category
        self.content = content
        self.position = position
    }

    /// 性能采样、手动快照这类没有交互语义的记录不进列表，仍然留在导出日志里。
    static func category(for content: String) -> Category? {
        if content.hasPrefix("route=") { return .page }
        if content.hasPrefix("action=") { return .tap }
        if content.hasPrefix("network ") { return .network }
        if content.hasPrefix("error=") { return .error }
        return nil
    }

    static func parseTimestamp(_ text: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    /// 文件位置这类技术字段只在详情里露一行，叫「位置」。
    static func position(in head: String) -> String? {
        guard let fileRange = head.range(of: " file="),
              let functionRange = head.range(of: " function=", options: .backwards),
              fileRange.upperBound <= functionRange.lowerBound else { return nil }
        let file = String(head[fileRange.upperBound..<functionRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        let function = String(head[functionRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        let name = function.split(separator: "(").first.map(String.init) ?? function
        guard !file.isEmpty else { return nil }
        return name.isEmpty ? file : "\(file) · \(name)"
    }
}

/// 列表顶部的分段筛选，顺序：全部、页面进入、点击、网络、异常。
enum BeansDiagnosticFilter: String, CaseIterable, Identifiable {
    case all, page, tap, network, error

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .page: return "页面进入"
        case .tap: return "点击"
        case .network: return "网络"
        case .error: return "异常"
        }
    }

    var category: BeansDiagnosticEntry.Category? {
        switch self {
        case .all: return nil
        case .page: return .page
        case .tap: return .tap
        case .network: return .network
        case .error: return .error
        }
    }

    func matches(_ entry: BeansDiagnosticEntry) -> Bool {
        guard let category else { return true }
        return entry.category == category
    }
}

struct BeansDiagnosticsSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var diagnostics = BeansDiagnostics.shared
    @State private var showShare = false
    @State private var showClearConfirm = false
    private var recentEntryCount: Int { diagnostics.recentEntries.count }

    var body: some View {
        BeansNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("诊断与日志", systemImage: "stethoscope")
                            .font(BeansFont.appFont(17, .semibold))
                            .foregroundStyle(Color.beansAmber)
                        Toggle("启用诊断记录", isOn: $diagnostics.enabled)
                            .tint(Color.beansAmber)
                        Text("记录页面进入、点击、网络摘要、卡顿前上下文和系统诊断。账号、Cookie、密码与令牌会自动脱敏。")
                            .font(BeansFont.appFont(12))
                            .foregroundStyle(Color.beansComment)
                        diagnosticRow("构建", value: BeansBuildStamp.text)
                        NavigationLink {
                            BeansDiagnosticsLogView()
                        } label: {
                            HStack(spacing: 6) {
                                Text("最近操作").foregroundStyle(Color.beansComment)
                                Spacer()
                                Text("\(recentEntryCount) 条").foregroundStyle(Color.beansLabel)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color.beansComment)
                            }
                            .font(BeansFont.appFont(12))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(GlassPressButtonStyle())
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("最近操作，\(recentEntryCount) 条，进入列表"))
                        .accessibilityIdentifier("diagnostics-recent")
                        diagnosticRow("当前页面", value: diagnostics.lastRoute)
                        diagnosticRow("系统", value: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
                        HStack(spacing: 10) {
                            actionButton("camera.viewfinder", "记录快照") { diagnostics.recordTap("记录快照") ; _ = diagnostics.snapshot() ; ToastCenter.shared.show("诊断快照已记录") }
                            actionButton("square.and.arrow.up", "导出日志") { diagnostics.recordTap("导出日志") ; showShare = true }
                        }
                        Button(role: .destructive) { showClearConfirm = true } label: {
                            Label("清空本地诊断日志", systemImage: "trash")
                                .font(BeansFont.appFont(13, .medium))
                        }
                    }
                    .padding(16)
                    .background { BeansGlass(shape: RoundedRectangle(cornerRadius: 18, style: .continuous), forceLiquid: true) }
                    VStack(alignment: .leading, spacing: 12) {
                        Label("悬浮歌词调试", systemImage: "waveform.path.ecg")
                            .font(BeansFont.appFont(17, .semibold))
                            .foregroundStyle(Color.beansAmber)
                        LyricDebugSettingsControl()
                        Text("开启后在屏幕上显示可拖动的调试按钮，点开可看音频实际时间、歌词有效时间、逐字数据与当前歌词界面状态，并导出检测日志。只读歌词时间轴，不会请求歌词或改变播放。")
                            .font(BeansFont.appFont(12))
                            .foregroundStyle(Color.beansComment)
                    }
                    .padding(16)
                    .background { BeansGlass(shape: RoundedRectangle(cornerRadius: 18, style: .continuous), forceLiquid: true) }
                    Text("系统级闪退和卡死报告会在下次启动由 MetricKit 交付；应用被系统直接终止时，应用内无法保证拦截到最后一条指令。")
                        .font(BeansFont.appFont(11))
                        .foregroundStyle(Color.beansComment)
                        .padding(.horizontal, 4)
                }
                .padding(16)
            }
            .navigationTitle("诊断与日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .sheet(isPresented: $showShare) { ShareSheet(items: [diagnostics.exportLogURL()]) }
        .onAppear { BeansDiagnostics.shared.recordPage("诊断与日志") }
        .confirmationDialog("确定清空本地诊断日志？", isPresented: $showClearConfirm, titleVisibility: .visible) {
            // 清空本身不记：记录是异步入列，清完再入列会剩一条「点击：清空诊断日志」，
            // 用户就永远看不到「还没有诊断记录」那段空态。
            Button("清空", role: .destructive) { diagnostics.clear() }
            Button("取消", role: .cancel) {}
        }
    }

    private func diagnosticRow(_ title: String, value: String) -> some View {
        HStack { Text(title).foregroundStyle(Color.beansComment); Spacer(); Text(value).foregroundStyle(Color.beansLabel).lineLimit(1).truncationMode(.middle) }
            .font(BeansFont.appFont(12))
    }

    private func actionButton(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).font(BeansFont.appFont(13, .medium)).frame(maxWidth: .infinity).padding(.vertical, 10).background { BeansSurface(shape: Capsule()) } }
            .buttonStyle(.plain)
    }
}



/// A4 列表 / 筛选 / 详情。数据只来自已经记下的记录，不新增采集、不碰请求层。
/// 视觉照 design 的 diagnostics-list-spec：横滚药丸筛选、56 行高、详情四项字段。
struct BeansDiagnosticsLogView: View {
    @ObservedObject private var diagnostics = BeansDiagnostics.shared
    @State private var filter: BeansDiagnosticFilter = .all

    private var entries: [BeansDiagnosticEntry] {
        diagnostics.recentEntries.filter(filter.matches)
    }

    private static let rowTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            pills
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if entries.isEmpty {
                        Text(diagnostics.recentEntries.isEmpty
                             ? "还没有诊断记录。用一会儿应用，这里会按时间列出页面进入、点击和网络请求。"
                             : "这一类还没有记录。")
                            .font(BeansFont.appFont(14))
                            .foregroundStyle(Color.beansComment)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 64)
                            .accessibilityIdentifier("diagnostics-empty")
                    } else {
                        SettingsCatalogGroup {
                            VStack(spacing: 0) {
                                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                    row(entry)
                                    if index != entries.count - 1 {
                                        Divider().overlay(Color.primary.opacity(0.09))
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .navigationTitle("最近操作")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 计数跟标题同一行右端，药丸那行只放药丸（Ato 口径，对应 Camo 的「标题旁边」）。
            ToolbarItem(placement: .primaryAction) {
                Text("\(entries.count) 条")
                    .font(BeansFont.appFont(13, .medium))
                    .foregroundStyle(Color.beansComment)
                    .accessibilityIdentifier("diagnostics-count")
            }
        }
    }

    private var pills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(BeansDiagnosticFilter.allCases) { item in
                    let selected = filter == item
                    Button {
                        filter = item
                        BeansHaptics.select()
                    } label: {
                        Text(item.title)
                            .font(BeansFont.appFont(12, selected ? .semibold : .medium))
                            .foregroundStyle(selected ? Color.beansAmber : Color.beansLabel)
                            .padding(.horizontal, 12)
                            .frame(height: 31)
                            .background { pillBackground(selected: selected) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 1)
        }
        .accessibilityLabel(Text("按类型筛选"))
    }

    /// 与音质那排同一套：玻璃胶囊 + 选中琥珀底。
    @ViewBuilder
    private func pillBackground(selected: Bool) -> some View {
        ZStack {
            BeansGlass(shape: Capsule())
            if selected {
                Capsule().fill(Color.beansAmber.opacity(0.16))
            }
        }
    }

    private func row(_ entry: BeansDiagnosticEntry) -> some View {
        let time = Self.rowTimeFormatter.string(from: entry.date)
        return NavigationLink {
            BeansDiagnosticDetailView(entry: entry)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(time)
                        .monospacedDigit()
                    Circle()
                        .fill(dotColor(entry.category))
                        .frame(width: 6, height: 6)
                    Text(entry.category.title)
                }
                .font(BeansFont.appFont(12, .medium))
                .foregroundStyle(Color.beansComment)
                Text(summary(entry.content))
                    .font(BeansFont.appFont(13))
                    .foregroundStyle(Color.beansLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(GlassPressButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(time)，\(entry.category.title)，\(summary(entry.content))"))
    }

    /// 类型已经在上一列，摘要里不重复那个前缀。
    private func summary(_ content: String) -> String {
        var text = content
        if text.hasPrefix("route=") { text.removeFirst("route=".count) }
        else if text.hasPrefix("action=") { text.removeFirst("action=".count) }
        else if text.hasPrefix("error=") { text.removeFirst("error=".count) }
        else if text.hasPrefix("network ") { text.removeFirst("network ".count) }
        return text
    }

    /// 圆点只是辅助，类型永远以文字出现。
    private func dotColor(_ category: BeansDiagnosticEntry.Category) -> Color {
        switch category {
        case .page: return .beansAmber
        case .tap: return .blue
        case .network: return .green
        case .error: return .red
        }
    }
}

/// 一条记录的详情：时间、类型、内容，技术位置放最后。
struct BeansDiagnosticDetailView: View {
    let entry: BeansDiagnosticEntry

    private static let detailTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private var timeText: String {
        Self.detailTimeFormatter.string(from: entry.date)
    }

    private var copyText: String {
        var lines = ["时间：\(timeText)", "类型：\(entry.category.title)", "内容：\(entry.content)"]
        if let position = entry.position { lines.append("位置：\(position)") }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        ScrollView {
            SettingsCatalogGroup {
                VStack(alignment: .leading, spacing: 14) {
                    field("时间", timeText)
                    field("类型", entry.category.title)
                    field("内容", entry.content)
                    if let position = entry.position {
                        field("位置", position)
                    }
                }
                .padding(.vertical, 16)
            }
            .padding(16)
        }
        .navigationTitle("记录详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    UIPasteboard.general.string = copyText
                    ToastCenter.shared.show("已复制")
                } label: {
                    Text("复制")
                        .font(BeansFont.appFont(13, .medium))
                        .foregroundStyle(Color.beansAmber)
                }
            }
        }
    }

    private func field(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(BeansFont.appFont(12))
                .foregroundStyle(Color.beansComment)
            Text(value)
                .font(BeansFont.appFont(15))
                .foregroundStyle(Color.beansLabel)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
