#!/bin/bash
# 正式包不允许带调试外壳和调试开关。
# 之前一次排查把“SHELL 0 / 自动分层 / 探针”留在页面里混进了包，导致一半结论是测在假页面上。
# 构建第一步就跑这个，命中直接失败。
set -u
PATTERN='SHELL 0|SHELL 1|ArtistHomeProbe|BodyCounter|probeTaps|probeButton|bisectLevel|bisectControls|rootping|vprobe|logWindowState|debugProbe|mainHeartbeatTask|beansStartRootMainPing|shellLevel|autoLevelTask'
HITS=$(grep -rnE "$PATTERN" Beans Modules --include='*.swift' 2>/dev/null || true)
if [ -n "$HITS" ]; then
  echo "✗ 检出调试外壳或调试开关，构建中止：" >&2
  echo "$HITS" >&2
  echo "把这些代码删掉再构建；正式包里不允许留调试层。" >&2
  exit 1
fi
echo "✓ 没有调试外壳残留"
