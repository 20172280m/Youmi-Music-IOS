#!/bin/bash
# 生成 Beans/BeansBuildStamp.swift：编译期常量 + 显示逻辑，整份重写。
# 目标文件已在 target 内（不要新建文件，xcodegen 不一定收）。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
stamp="$(TZ=UTC date '+%Y-%m-%d %H:%M') UTC"
# 打包副本里通常没有 .git：优先用签出目录预先写好的 .airbuild/build-commit，
# 其次是当前 worktree 的 HEAD，都没有才写“未提供”。
commit="$(cat "$root/.airbuild/build-commit" 2>/dev/null | tr -d '[:space:]' || true)"
if [ -z "${commit:-}" ]; then
  commit="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || true)"
fi
[ -z "${commit:-}" ] && commit="未提供"
cat > "$root/Beans/BeansBuildStamp.swift" <<SWIFT
import Foundation

// ⚠️ 生成文件，勿手改、勿单独提交：由 scripts/gen-build-stamp.sh 覆盖。
/// 构建戳常量：由 scripts/gen-build-stamp.sh 在编之前整份重写，装机抹不掉。
enum BeansBuildInfo {
    static let compiledAt = "${stamp}"
    static let commit = "${commit}"
}

/// 一行构建标识：版本、构建号、编译时间、提交短号。
enum BeansBuildStamp {
    static var text: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "—"
        let build = info["CFBundleVersion"] as? String ?? "—"
        return "\\(version) (\\(build)) · 构建 \\(BeansBuildInfo.compiledAt) · 提交 \\(BeansBuildInfo.commit)"
    }
}
SWIFT
echo "build stamp: ${stamp} ${commit}"
