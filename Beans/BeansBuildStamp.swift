import Foundation

// ⚠️ 生成文件，勿手改、勿单独提交：由 scripts/gen-build-stamp.sh 覆盖。
/// 构建戳常量：由 scripts/gen-build-stamp.sh 在编之前整份重写，装机抹不掉。
enum BeansBuildInfo {
    static let compiledAt = "2026-11-01 00:34 UTC"
    static let commit = "7fbb8cb"
}

/// 一行构建标识：版本、构建号、编译时间、提交短号。
enum BeansBuildStamp {
    static var text: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "—"
        let build = info["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build)) · 构建 \(BeansBuildInfo.compiledAt) · 提交 \(BeansBuildInfo.commit)"
    }
}
