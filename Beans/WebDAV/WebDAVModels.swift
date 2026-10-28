import Foundation

// Reconstructed from the verified 2.0.3 reflection fields, rather than recovered original Swift.
struct WebDAVConnection: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var address: String
    var username: String
    var allowHTTP = false

    var accountKey: String { address + "|" + username }
}

struct WebDAVTrack: Codable, Hashable, Sendable {
    let connectionID: UUID
    let relativePath: String
    let accountKey: String
}

struct WebDAVEntry: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64?
    var id: String { url.absoluteString }
    var isAudio: Bool { Self.audioExtensions.contains(url.pathExtension.lowercased()) }
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aif", "aiff", "alac", "caf", "ogg", "opus"]
}

enum WebDAVError: LocalizedError {
    case http(Int), keychain(Int32), invalidAddress, outsideRoot, invalidListing, tooLarge, missingConnection, invalidBackup
    var errorDescription: String? {
        switch self {
        case .http(401): return "账号或应用密码不正确（401）。"
        case .http(403): return "服务器拒绝访问，请检查目录权限（403）。"
        case .http(404): return "WebDAV 目录或文件不存在（404）。"
        case .http(408): return "服务器等太久没有回应（408）。"
        case .http(let code) where (500...599).contains(code):
            return "服务器那边出错了（HTTP \(code)），过一会儿再试。"
        case .http(let code): return "WebDAV 请求失败（HTTP \(code)）。"
        case .keychain: return "无法保存或读取钥匙串凭据，请解锁设备后重试。"
        case .invalidAddress: return "请输入完整的 HTTPS 地址；HTTP 需单独确认，地址不能含账号、密码或查询参数。"
        case .outsideRoot: return "拒绝访问 WebDAV 根目录之外的路径。"
        case .invalidListing: return "服务器未返回有效的 WebDAV 目录。"
        case .tooLarge: return "文件超过允许大小。"
        case .missingConnection: return "请先保存 WebDAV 连接，或重新输入密码。"
        case .invalidBackup: return "不是受支持的恢复版备份，或文件内容无效。"
        }
    }

    /// 把系统错误翻成用户能看懂的话：域名、连不上、超时、证书、被 ATS 挡。
    static func message(for error: Error) -> String {
        if let dav = error as? WebDAVError { return dav.errorDescription ?? "WebDAV 请求失败。" }
        guard let url = error as? URLError else { return error.localizedDescription }
        switch url.code {
        case .cannotFindHost, .dnsLookupFailed:
            return "找不到这个服务器：检查地址有没有写错。"
        case .cannotConnectToHost:
            return "连不上服务器：检查地址、端口，以及服务器是否在同一个网络里。"
        case .timedOut:
            return "连接超时：服务器没有回应。"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            return "HTTPS 证书没通过校验：换成可信证书，或改用 HTTP 并确认风险。"
        case .appTransportSecurityRequiresSecureConnection:
            return "系统不允许这个 HTTP 连接。"
        case .notConnectedToInternet, .networkConnectionLost:
            return "网络断了，连上再试。"
        case .userAuthenticationRequired:
            return "需要先登录这个服务器。"
        default:
            return "网络错误：\(url.localizedDescription)"
        }
    }
}
