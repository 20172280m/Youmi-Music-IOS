import Foundation

/// B 站接口只认两种视频身份：BV 号（`bvid=`）或数字 aid（`aid=` / `avid=`）。
/// App 里同一条视频可能带着三种形态走到请求层：
/// - 正常 BV 号；
/// - `av1050631`，首页/搜索里只有 aid 的卡片合成出来的占位；
/// - `BV1xx411c7mD:123456`，带了分 P 的 CID 尾巴（Beans 音乐侧把 bvid 和 cid 拼在一个字段里）。
/// 后两种直接塞进 `bvid=` 会被服务端判成参数错误（`-400 请求错误`），
/// 所以在这一层统一换算成接口认的参数，调用点不再各自清洗。
nonisolated enum BiliVideoIdentityQuery {
    /// 统一的视频身份参数：合法 BV 号走 `bvid`，其余能解析出 aid 的走 `aidKey`。
    /// `aidKey` 默认 `aid`（video/view、archive/related），播放地址接口用 `avid`。
    static func parameters(for rawIdentity: String, aidKey: String = "aid") -> [String: String] {
        let normalized = normalizedBVID(rawIdentity)
        if isBVVID(normalized) {
            return ["bvid": normalized]
        }
        if let aid = aidValue(from: normalized), aid > 0 {
            return [aidKey: String(aid)]
        }
        return [:]
    }

    /// 去掉空白和分 P 尾巴，只留视频本体的标识。
    static func normalizedBVID(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.firstIndex(of: ":") else { return trimmed }
        return String(trimmed[trimmed.startIndex..<separator])
    }

    /// `BV` 开头且后面全是字母数字，才算真正能被接口接受的 BV 号。
    static func isBVVID(_ value: String) -> Bool {
        guard value.count > 2, value.hasPrefix("BV") else { return false }
        return value.dropFirst(2).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// 从 `av1050631` 或纯数字里取 aid。
    static func aidValue(from value: String) -> Int? {
        if let number = Int(value), number > 0 { return number }
        guard value.count > 2, value.lowercased().hasPrefix("av") else { return nil }
        guard let number = Int(value.dropFirst(2)), number > 0 else { return nil }
        return number
    }
}