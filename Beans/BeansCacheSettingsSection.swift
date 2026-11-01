import SwiftUI

/// Functional reconstruction: cache controls share the existing settings card;
/// backups retain their own controls. This does not claim the original UI layout.
@MainActor
struct BeansCacheSettingsSection: View {
    @StateObject private var manager = BeansCacheManager()
    @Environment(\.locale) private var locale
    @State private var expanded = false
    @State private var pendingCategories: [BeansCacheCategory] = []
    @State private var showConfirmation = false
    @State private var didRefresh = false
    @State private var operationID = 0
    @State private var pendingOperation: Operation?
    @State private var operationRunning = false

    private enum Operation {
        case refresh
        case clear([BeansCacheCategory])
    }

    private var busy: Bool { operationRunning || manager.working }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                BeansHaptics.select()
                withAnimation(.easeInOut(duration: 0.22)) {
                    expanded.toggle()
                }
                if expanded && !didRefresh {
                    begin(.refresh)
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "internaldrive")
                        .foregroundStyle(Color.beansAmber)
                    Text("缓存管理")
                        .font(BeansFont.appFont(15))
                        .foregroundStyle(Color.beansLabel)
                    Spacer(minLength: 8)
                    if busy {
                        ProgressView().tint(Color.beansAmber)
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(Color.beansComment)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .accessibilityIdentifier("cache-manager")
            .accessibilityValue(expanded ? Text("已展开") : Text("已收起"))

            if expanded {
                cacheControls
            }
        }
        // One structured task drives both refresh and clear. Consume the request before
        // awaiting so disappearance/reappearance cannot replay a destructive operation.
        .task(id: operationID) {
            guard let operation = pendingOperation else { return }
            pendingOperation = nil
            defer { operationRunning = false }
            guard !Task.isCancelled else { return }
            switch operation {
            case .refresh:
                await manager.refresh()
            case .clear(let categories):
                await manager.clear(categories)
            }
            if !Task.isCancelled { didRefresh = true }
        }
        .confirmationDialog(
            Text("清理「\(selectionTitle)」？"),
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            Button("确认清理", role: .destructive) {
                let selection = pendingCategories
                pendingCategories = []
                guard !selection.isEmpty else { return }
                begin(.clear(selection))
            }
            .disabled(busy)
            Button("取消", role: .cancel) { pendingCategories = [] }
        } message: {
            Text("缓存会在使用时重新加载；保留登录信息、设置、壁纸、自定义封面、下载文件、本地音乐及字体。\n沉浸媒体可能保留正在使用的资源；哔哩哔哩视频或直播使用中会跳过清理，统计不一定归零。")
        }
    }

    private var cacheControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    begin(.refresh)
                } label: {
                    Label("刷新缓存统计", systemImage: "arrow.clockwise")
                        .font(BeansFont.appFont(13, .semibold))
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("cache-refresh")
                Spacer(minLength: 0)
                Button(role: .destructive) {
                    confirm(BeansCacheCategory.allCases)
                } label: {
                    Text("清理全部缓存")
                        .font(BeansFont.appFont(13, .semibold))
                        .frame(minHeight: 44)
                }
                .disabled(manager.usage.isEmpty)
                .accessibilityIdentifier("cache-clear-all")
            }
            .buttonStyle(.plain)
            .tint(Color.beansAmber)
            .disabled(busy)

            if busy {
                HStack(spacing: 8) {
                    ProgressView().tint(Color.beansAmber)
                    Text("正在处理缓存…")
                        .font(BeansFont.appFont(12))
                        .foregroundStyle(Color.beansComment)
                }
            } else if didRefresh && manager.usage.isEmpty {
                Text("暂无缓存统计，请刷新重试。")
                    .font(BeansFont.appFont(12))
                    .foregroundStyle(Color.beansComment)
            }

            VStack(spacing: 0) {
                ForEach(BeansCacheCategory.allCases) { category in
                    cacheRow(category)
                    if category != BeansCacheCategory.allCases.last {
                        Divider().opacity(0.35)
                    }
                }
            }
            .padding(.horizontal, 14)
            .background {
                BeansGlass(shape: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }

            if let message = manager.message, !message.isEmpty {
                Text(verbatim: message)
                    .font(BeansFont.appFont(12))
                    .foregroundStyle(Color.beansLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cache-message")
            }
            Text("元数据与歌词显示编码数据载荷估算，不是共享偏好文件的磁盘占用。")
                .font(BeansFont.appFont(11))
                .foregroundStyle(Color.beansComment)
                .fixedSize(horizontal: false, vertical: true)
            Text("内存仅为可统计部分的估算；未知不代表为零，不含全部图片与播放对象。")
                .font(BeansFont.appFont(11))
                .foregroundStyle(Color.beansComment)
                .fixedSize(horizontal: false, vertical: true)
            Text("沉浸媒体可能保留正在使用的资源；哔哩哔哩视频或直播使用中会跳过清理，统计不一定归零。")
                .font(BeansFont.appFont(11))
                .foregroundStyle(Color.beansComment)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 14)
    }

    private func cacheRow(_ category: BeansCacheCategory) -> some View {
        let usage = manager.usage.first { $0.category == category }
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(LocalizedStringKey(category.title))
                    .font(BeansFont.appFont(14, .semibold))
                    .foregroundStyle(Color.beansLabel)
                if let usage {
                    if usage.isDefaultsPayloadEstimate {
                        Text("数据载荷估算：\(bytes(usage.diskBytes))")
                    } else {
                        Text("磁盘：\(bytes(usage.diskBytes))")
                    }
                    if let memory = usage.memoryBytes {
                        Text("内存估算：\(bytes(memory))")
                    } else {
                        Text("内存：未知")
                    }
                } else {
                    Text("暂无统计")
                }
            }
            .font(BeansFont.appFont(11))
            .foregroundStyle(Color.beansComment)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(role: .destructive) {
                confirm([category])
            } label: {
                Text("清理")
                    .font(BeansFont.appFont(13, .semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(busy || usage == nil)
            .accessibilityLabel(Text("清理\(categoryTitle(category))"))
            .accessibilityIdentifier("cache-clear-\(category.rawValue)")
        }
        .padding(.vertical, 12)
    }

    private var selectionTitle: String {
        pendingCategories.map(categoryTitle).joined(separator: " / ")
    }

    private func categoryTitle(_ category: BeansCacheCategory) -> String {
        let language = locale.language.languageCode?.identifier == "en" ? "en" : "zh-Hans"
        let bundle = Bundle.main.path(forResource: language, ofType: "lproj")
            .flatMap(Bundle.init(path:)) ?? .main
        return bundle.localizedString(forKey: category.title, value: category.title, table: nil)
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file)
    }

    private func confirm(_ categories: [BeansCacheCategory]) {
        guard !busy else { return }
        pendingCategories = categories
        showConfirmation = true
    }

    private func begin(_ operation: Operation) {
        guard !busy else { return }
        operationRunning = true
        pendingOperation = operation
        operationID += 1
    }
}
