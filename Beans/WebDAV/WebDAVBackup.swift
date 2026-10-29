import Foundation

/// Uses the existing Beans JSON backup shape, including its Data marker. Validates the
/// whole import before applying it, so a malformed preference never causes a partial restore.
enum WebDAVBackup {
    static let maximumSize = 16 * 1024 * 1024

    static func export(defaults: UserDefaults = .standard, includeAccounts: Bool = false,
                       includeWallpapers: Bool = false) throws -> Data {
        var settings: [String: Any] = [:]
        for (key, value) in defaults.dictionaryRepresentation() where allowed(key, accounts: includeAccounts, wallpapers: includeWallpapers) {
            if let data = value as? Data, data.count > 2 * 1024 * 1024 { continue }
            settings[key] = jsonValue(value)
        }
        settings["beans.backup.meta"] = ["app": "Beans Music", "format": "beans-webdav-v1",
                                       "created": ISO8601DateFormatter().string(from: Date()),
                                       "includedAccounts": includeAccounts, "includedWallpapers": includeWallpapers]
        // 字体文件不在 UserDefaults 里，得单独把名字和内容带进来，否则换设备恢复后字体就丢了。
        if let font = FontManager.exportFontData() {
            settings["beans.font.restore"] = ["name": font.name, "data": font.data.base64EncodedString()]
        }
        guard JSONSerialization.isValidJSONObject(settings) else { throw WebDAVError.invalidBackup }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys, .prettyPrinted])
        guard data.count <= maximumSize else { throw WebDAVError.tooLarge }
        return data
    }

    static func validated(_ data: Data) throws -> [String: Any] {
        guard data.count <= maximumSize,
              let settings = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let metadata = settings["beans.backup.meta"] as? [String: Any], metadata["app"] as? String == "Beans Music" else { throw WebDAVError.invalidBackup }
        if let format = metadata["format"] as? String, format != "beans-webdav-v1" { throw WebDAVError.invalidBackup }
        var result: [String: Any] = [:]
        for (key, value) in settings where allowed(key, accounts: true, wallpapers: true) {
            result[key] = try plistValue(value)
        }
        guard !result.isEmpty else { throw WebDAVError.invalidBackup }
        return result
    }

    struct RestoreResult {
        var count = 0
        /// 备份里带了字体，但这次没装上（例如同一次运行里字体还挂在 CoreText 上卸不掉）。
        var fontPending = false
    }

    @discardableResult
    static func restore(_ validated: [String: Any], defaults: UserDefaults = .standard) -> RestoreResult {
        var result = RestoreResult()
        for (key, value) in validated where key != "beans.font.restore" && allowed(key, accounts: true, wallpapers: true) {
            defaults.set(value, forKey: key)
            result.count += 1
        }
        // 字体是文件不是偏好：写回 Documents/Fonts 并重新注册，选字体列表里才会出现它。
        if let font = validated["beans.font.restore"] as? [String: Any],
           let name = font["name"] as? String,
           let encoded = font["data"] as? String,
           let data = Data(base64Encoded: encoded) {
            if FontManager.restoreFont(name: name, data: data) {
                result.count += 1
            } else {
                result.fontPending = true
            }
        }
        return result
    }

    private static func allowed(_ key: String, accounts: Bool, wallpapers: Bool) -> Bool {
        guard key.hasPrefix("beans."), key != "beans.backup.meta",
              key != "beans.launchInProgress", key != "beans.wallpapers.deleted",
              !key.hasPrefix("beans.log"), !key.hasPrefix("beans.crash"), !key.hasPrefix("beans.search.") else { return false }
        let lower = key.lowercased()
        guard !lower.contains("password"), !lower.contains("secret"), !lower.contains("apikey"),
              key != "beans.thirdPartyAPIKeys" else { return false }
        if !accounts && (key == "beans.user" || key.hasPrefix("beans.netease.") || key.hasPrefix("beans.qqmusic.") || key.hasPrefix("beans.kugou.") || key.hasPrefix("beans.bilibili.")) { return false }
        if !wallpapers && (key.hasPrefix("beans.wallpapers.") || key.hasPrefix("beans.background.image") || key.hasPrefix("beans.background.custom") || key.hasPrefix("beans.lyricBackground.")) { return false }
        return true
    }

    private static func jsonValue(_ value: Any) -> Any {
        if let data = value as? Data { return ["__beansData__": data.base64EncodedString()] }
        if let date = value as? Date { return date.timeIntervalSince1970 }
        if let array = value as? [Any] { return array.map(jsonValue) }
        if let dictionary = value as? [String: Any] { return dictionary.mapValues(jsonValue) }
        return value
    }

    private static func plistValue(_ value: Any, depth: Int = 0) throws -> Any {
        guard depth < 32 else { throw WebDAVError.invalidBackup }
        if let dictionary = value as? [String: Any] {
            if dictionary.count == 1, let encoded = dictionary["__beansData__"] as? String {
                guard let data = Data(base64Encoded: encoded) else { throw WebDAVError.invalidBackup }
                return data
            }
            return try dictionary.mapValues { try plistValue($0, depth: depth + 1) }
        }
        if let array = value as? [Any] { return try array.map { try plistValue($0, depth: depth + 1) } }
        if value is String || value is NSNumber { return value }
        throw WebDAVError.invalidBackup
    }
}
