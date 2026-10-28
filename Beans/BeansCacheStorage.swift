import Foundation

/// Logical file lengths, not filesystem allocation. Never follows cache symlinks.
/// Call blocking methods on a utility queue or a non-main actor.
enum BeansCacheFiles {
    static func validateDirectory(_ directory: URL, under root: URL) throws -> Bool {
        let root = root.standardizedFileURL
        let directory = directory.standardizedFileURL
        guard directory.path == root.path || directory.path.hasPrefix(root.path + "/") else {
            throw CocoaError(.fileReadNoPermission)
        }
        let suffix = directory.path.dropFirst(root.path.count)
        var current = root
        let components = [""] + suffix.split(separator: "/").map(String.init)
        for component in components {
            if !component.isEmpty { current.appendPathComponent(component, isDirectory: true) }
            guard let type = try itemType(current) else { return false }
            guard type == .typeDirectory else { throw CocoaError(.fileReadInvalidFileName) }
        }
        return true
    }

    static func bytes(in directory: URL, under root: URL) throws -> Int64 {
        guard try validateDirectory(directory, under: root) else { return 0 }
        return try childrenBytes(directory)
    }

    static func clearContents(of directory: URL, under root: URL, retaining: Set<URL> = []) throws {
        guard try validateDirectory(directory, under: root) else { return }
        for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if retaining.contains(child.standardizedFileURL) { continue }
            // removeItem unlinks a symlink itself; it does not follow its target.
            try FileManager.default.removeItem(at: child)
        }
    }

    /// True only for a regular file at the leaf; symlinks are refused rather than followed.
    static func isRegularFile(_ file: URL, under root: URL) throws -> Bool {
        guard try validateDirectory(file.deletingLastPathComponent(), under: root) else { return false }
        return try itemType(file) == .typeRegular
    }

    static func fileBytes(_ file: URL, under root: URL) throws -> Int64 {
        guard try validateDirectory(file.deletingLastPathComponent(), under: root),
              let type = try itemType(file) else { return 0 }
        guard type == .typeRegular else {
            if type == .typeSymbolicLink { return 0 }
            throw CocoaError(.fileReadInvalidFileName)
        }
        return try size(file)
    }

    static func removeFile(_ file: URL, under root: URL) throws {
        guard try validateDirectory(file.deletingLastPathComponent(), under: root),
              try itemType(file) != nil else { return }
        guard try itemType(file) != .typeDirectory else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.removeItem(at: file)
    }

    private static func childrenBytes(_ directory: URL) throws -> Int64 {
        var total: Int64 = 0
        for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            switch try itemType(child) {
            case .typeDirectory: total += try childrenBytes(child)
            case .typeRegular: total += try size(child)
            default: break // Links, sockets and other non-cache data are not followed.
            }
        }
        return total
    }

    private static func size(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else { throw CocoaError(.fileReadUnknown) }
        return size.int64Value
    }

    private static func itemType(_ url: URL) throws -> FileAttributeType? {
        do {
            return try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
    }
}

/// Only verified cache payload keys. Migration markers, accounts and user content are excluded.
enum BeansCacheDefaults {
    /// 页面数据缓存现在存 Caches 下的文件；这里只剩歌单广场这类小键。
    /// 旧版的几份大载荷键不再参与统计与清理，由各自的迁移在写文件成功后删除。
    static let metadataKeys: Set<String> = []
    static let lyricPrefix = "beans.lyrics.cache.v1."

    static func isPlaylistSquareKey(_ key: String) -> Bool {
        // Only versions currently written by PlaylistSquareCache, with the exact key shape.
        let parts = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 7, Array(parts[0...2]) == ["beans", "playlistSquare", "cache"],
              ["v5", "v8"].contains(parts[3]),
              SearchProvider.allCases.map(\.rawValue).contains(parts[4]),
              ["login", "guest"].contains(parts[5]), !parts[6].isEmpty else { return false }
        return parts[6].range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }

    static func keys(in defaults: UserDefaults, category: BeansCacheCategory) -> [String] {
        defaults.dictionaryRepresentation().keys.filter {
            switch category {
            case .metadata: return metadataKeys.contains($0) || isPlaylistSquareKey($0)
            case .lyrics: return $0.hasPrefix(lyricPrefix)
            default: return false
            }
        }
    }

    /// Encoded payload estimate; not the allocation of the shared UserDefaults plist.
    static func payloadBytes(in defaults: UserDefaults, category: BeansCacheCategory) -> Int64 {
        keys(in: defaults, category: category).reduce(0) { total, key in
            guard let value = defaults.object(forKey: key) else { return total }
            if let data = value as? Data { return total + Int64(data.count) }
            let data = try? PropertyListSerialization.data(fromPropertyList: [key: value], format: .binary, options: 0)
            return total + Int64(data?.count ?? 0)
        }
    }

    static func clear(_ category: BeansCacheCategory, in defaults: UserDefaults) {
        let targets = keys(in: defaults, category: category)
        for key in targets { defaults.removeObject(forKey: key) }
    }
}
