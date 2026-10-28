import CryptoKit
import SwiftUI

/// A native browser for the configured WebDAV collection. Remote audio is copied to a
/// local cache by PlayerManager before AVPlayer receives it.
struct WebDAVView: View {
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = WebDAVStore.shared

    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var allowHTTP = false
    @State private var directory: URL?
    @State private var folders: [URL] = []
    @State private var entries: [WebDAVEntry] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var showDisconnect = false
    @State private var showClearCache = false
    @State private var includeAccounts = false
    @State private var includeWallpapers = false
    @State private var transferInProgress = false
    @State private var pendingRestore: [String: Any]?
    @State private var showRestore = false
    @State private var message: String?
    @State private var editingConnection = false
    @State private var lastLoadFailed = false

    var body: some View {
        NavigationStack {
            List {
                if store.connection == nil || editingConnection { connectionForm }
                else {
                    browserSection
                    backupSection
                    Section("连接") {
                        LabeledContent("地址", value: store.connection?.address ?? "")
                        Button("编辑连接") { editingConnection = true }
                        Button("清理已缓存音乐") { showClearCache = true }
                        Button("移除此 WebDAV 连接", role: .destructive) { showDisconnect = true }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(GlassBackdrop())
            .navigationTitle("WebDAV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
            .task { restoreConnection() }
            .confirmationDialog("移除此 WebDAV 连接？", isPresented: $showDisconnect) {
                Button("移除连接", role: .destructive) {
                    do {
                        try store.disconnect()
                        // 移除连接后表单要回到空白，否则残留上一台的地址和账号，看起来像已经连上了。
                        directory = nil; entries = []; folders = []; message = nil
                        address = ""; username = ""; password = ""; allowHTTP = false
                    }
                    catch { errorMessage = WebDAVError.message(for: error) }
                }
            }
            .confirmationDialog("清理 WebDAV 音乐缓存？", isPresented: $showClearCache) {
                Button("清理缓存", role: .destructive) {
                    Task {
                        do { try await WebDAVAudioCache.shared.clear() }
                        catch { errorMessage = WebDAVError.message(for: error) }
                    }
                }
            }
            .confirmationDialog("恢复这个 WebDAV 备份？", isPresented: $showRestore, titleVisibility: .visible) {
                Button("恢复设置") {
                    if let pendingRestore {
                        let count = WebDAVBackup.restore(pendingRestore)
                        message = "已恢复 \(count) 项设置，重新启动应用后生效。"
                    }
                    pendingRestore = nil
                }
                Button("取消", role: .cancel) { pendingRestore = nil }
            }
            .alert("WebDAV", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("确定", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private var connectionForm: some View {
        Section {
            TextField("https://example.com/dav/", text: $address)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            TextField("用户名", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("应用密码", text: $password)
            Toggle("允许 HTTP 连接", isOn: $allowHTTP)
            Button("保存并连接") {
                do {
                    let connection = WebDAVConnection(id: store.connection?.id ?? UUID(), address: address, username: username, allowHTTP: allowHTTP)
                    try store.save(connection, password: password)
                    password = ""
                    directory = try WebDAVPaths.root(for: connection)
                    editingConnection = false
                    folders = []
                    Task { await load() }
                } catch { errorMessage = WebDAVError.message(for: error) }
            }
            .disabled(address.isEmpty || username.isEmpty || password.isEmpty)
        } header: { Text("连接服务器") } footer: {
            Text("密码保存在设备钥匙串。建议使用 HTTPS 和服务器提供的应用密码。")
        }
    }

    private var browserSection: some View {
        Section {
            if !folders.isEmpty {
                Button {
                    directory = folders.removeLast()
                    Task { await load() }
                } label: { Label("返回上一级", systemImage: "arrow.up.left") }
            }
            if loading { ProgressView("正在读取目录…") }
            ForEach(entries) { entry in
                if entry.isDirectory {
                    Button {
                        guard let current = directory else { return }
                        folders.append(current)
                        directory = entry.url
                        Task { await load() }
                    } label: { Label(entry.name, systemImage: "folder") }
                } else if entry.isAudio {
                    Button {
                        do {
                            let audio = entries.filter { !$0.isDirectory && $0.isAudio }
                            let songs = try audio.map(song(for:))
                            let start = audio.firstIndex(of: entry) ?? 0
                            BeansLogger.shared.log("WebDAV 点歌：\(entry.name)（\(songs.count) 首，起始 \(start)）", level: .info)
                            player.play(songs: songs, startAt: start)
                        } catch {
                            BeansLogger.shared.log("WebDAV 点歌失败：\(entry.name)｜\(error.localizedDescription)", level: .error)
                            errorMessage = WebDAVError.message(for: error)
                        }
                    } label: { Label(entry.name, systemImage: "music.note") }
                    .contextMenu {
                        Button("收藏到本地歌单", systemImage: "heart") {
                            do {
                                message = LocalLibraryStore.shared.addToDefaultFavorites(try song(for: entry))
                            } catch { errorMessage = WebDAVError.message(for: error) }
                        }
                    }
                } else if entry.url.pathExtension.lowercased() == "json" {
                    Button { Task { await prepareRestore(entry.url) } } label: {
                        Label(entry.name, systemImage: "doc.badge.arrow.up")
                    }
                    .disabled(transferInProgress)
                }
            }
            // 连不上和"目录里真的没有音频"是两回事，别用同一句话糊过去。
            if !loading && !lastLoadFailed && !hasRenderableEntry {
                Text("目录中没有可播放的音频文件").foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("文件")
                Spacer()
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
            }
        }
    }

    /// 目录里只有视频、图片这类不可播文件时，列表是空的——也要给出空态提示，
    /// 否则看起来像"连上了但什么都没加载出来"。
    private var hasRenderableEntry: Bool {
        entries.contains { entry in
            entry.isDirectory || entry.isAudio || entry.url.pathExtension.lowercased() == "json"
        }
    }

    private func song(for entry: WebDAVEntry) throws -> Song {
        guard let connection = store.connection else { throw WebDAVError.missingConnection }
        let root = try WebDAVPaths.root(for: connection)
        let path = try WebDAVPaths.relativePath(entry.url, root: root)
        let track = WebDAVTrack(connectionID: connection.id, relativePath: path, accountKey: connection.accountKey)
        let digest = SHA256.hash(data: Data((track.accountKey + "|" + path).utf8))
        let id = digest.prefix(8).reduce(UInt64.zero) { ($0 << 8) | UInt64($1) }
        return Song(id: Int(truncatingIfNeeded: id), name: (entry.name as NSString).deletingPathExtension,
                    artists: "WebDAV", album: "WebDAV", coverURL: nil, duration: 0, source: .webdav, webDAVTrack: track)
    }

    private var backupSection: some View {
        Section("备份与恢复") {
            Toggle("备份登录信息", isOn: $includeAccounts)
            Toggle("备份壁纸图片", isOn: $includeWallpapers)
            Button("备份到当前目录") { Task { await uploadBackup() } }
                .disabled(transferInProgress || loading)
            if transferInProgress { ProgressView("正在传输…") }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            Text("点击目录中的 JSON 备份可恢复。密码和 API 密钥不会写入备份。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func uploadBackup() async {
        guard let directory else { return }
        transferInProgress = true
        defer { transferInProgress = false }
        do {
            if includeWallpapers {
                ThemeStore.shared.refreshWallpaperBackupForExport()
                LyricBackgroundStore.refreshForExport()
            }
            let client = try store.client()
            let prefix = try WebDAVPaths.relativePath(directory, root: client.root)
            let date = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let path = (prefix.isEmpty ? "" : prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/") + "Beans-\(date).json"
            let data = try WebDAVBackup.export(includeAccounts: includeAccounts, includeWallpapers: includeWallpapers)
            _ = try await client.uploadBackup(data, fileName: path)
            message = "备份已上传并通过回读校验。"
            await load()
        } catch { errorMessage = WebDAVError.message(for: error) }
    }

    private func prepareRestore(_ url: URL) async {
        transferInProgress = true
        defer { transferInProgress = false }
        do {
            let client = try store.client()
            let data = try await client.downloadBackup(url)
            pendingRestore = try WebDAVBackup.validated(data)
            showRestore = true
        } catch { errorMessage = WebDAVError.message(for: error) }
    }

    private func restoreConnection() {
        guard let connection = store.connection, directory == nil else { return }
        address = connection.address
        username = connection.username
        allowHTTP = connection.allowHTTP
        do {
            directory = try WebDAVPaths.root(for: connection)
            Task { await load() }
        } catch { errorMessage = WebDAVError.message(for: error) }
    }

    private func load() async {
        guard let directory else { return }
        loading = true
        defer { loading = false }
        do {
            let client = try store.client()
            let listed = try await client.list(directory: directory)
            guard self.directory == directory else { return }
            lastLoadFailed = false
            entries = listed.sorted { left, right in
                if left.isDirectory != right.isDirectory { return left.isDirectory }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
        } catch {
            guard self.directory == directory else { return }
            entries = []
            lastLoadFailed = true
            errorMessage = WebDAVError.message(for: error)
        }
    }
}
