#!/usr/bin/env bash
#
# 资源占用基线测量。每加一个功能、每改一次热路径，都跑一遍它，
# 把数字和上一次比——这个项目的卖点就是「轻」，靠感觉是守不住的。
#
# 用法：
#   ./scripts/measure.sh              # 构建后测量，结果追加到 docs/PERF.md
#   ./scripts/measure.sh --no-build   # 直接用现有产物
#   ./scripts/measure.sh --note "主面板背景"   # 给这一行加个说明
#   ./scripts/measure.sh --backdrop '{"kind":"image","image":"backdrop.jpg"}'
#                                     # 量图片背景那一档（默认量系统材质）
#
# 量的是什么：
#   .app / 二进制      磁盘占用（`du`、`stat`）
#   悬浮窗 footprint    phys_footprint，不含 dyld 共享缓存
#   悬浮窗 RSS          内核 sysinfo 报的口径（含共享缓存，比 footprint 大）
#   主面板 footprint    打开主面板 8 秒后
#   CPU 1s / 5s         采集频率 1 秒 / 5 秒下的常驻 CPU（单核百分比，取中位数）
#
# 为什么 CPU 用 scripts/probe.swift 而不是 top/ps：那两个要 task_for_pid 权限，
# 在受限环境里直接 "operation not permitted"。probe 走内核自己的全进程表，
# 和界面上显示的数字同源。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/macos/build/EZPcMonitor.app"
BIN="$APP/Contents/MacOS/EZPcMonitor"
SUPPORT="$HOME/Library/Application Support/dev.ezpc.monitor"
SETTINGS="$SUPPORT/settings.json"
PERF="$ROOT/docs/PERF.md"
PROBE="/tmp/ezpcm-probe-bin"

BUILD=1
NOTE=""
BD='{"kind":"material","color":"graphite","opacity":0.94}'
while [ $# -gt 0 ]; do
  case "$1" in
    --no-build) BUILD=0 ;;
    --note) shift; NOTE="${1:-}" ;;
    --backdrop) shift; BD="${1:-}" ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------- 固定测量环境
#
# 三次测量必须在同一套设置下跑：采集频率、主题、悬浮窗形态都会影响数字。
# 先备份用户当前的状态，跑完原样还回去。

BK=$(mktemp -d)
cp "$SETTINGS" "$BK/settings.json" 2>/dev/null || true
defaults export dev.ezpc.monitor "$BK/defaults.plist" 2>/dev/null || true

restore() {
  pkill -f "EZPcMonitor.app/Contents/MacOS/EZPcMonitor" 2>/dev/null || true
  [ -f "$BK/settings.json" ] && cp "$BK/settings.json" "$SETTINGS"
  [ -f "$BK/defaults.plist" ] && defaults import dev.ezpc.monitor "$BK/defaults.plist" 2>/dev/null || true
  rm -rf "$BK"
}
trap restore EXIT

kill_app() { pkill -f "EZPcMonitor.app/Contents/MacOS/EZPcMonitor" 2>/dev/null || true; sleep 1; }

write_settings() { # $1 = intervalMs
  mkdir -p "$SUPPORT"
  cat > "$SETTINGS" <<JSON
{
  "intervalMs": $1,
  "historyEnabled": false,
  "historyRetentionSecs": 86400,
  "language": "zh-CN",
  "theme": "auto"
}
JSON
}

# 悬浮窗固定成卡片、不透明、不穿透——形态不同，画的视图数量差一倍
defaults write dev.ezpc.monitor ezpcm.mode -string "card"
defaults write dev.ezpc.monitor ezpcm.opacity -float 1.0
defaults write dev.ezpc.monitor ezpcm.clickThrough -bool false

# 主面板背景也固定住。默认是系统材质（也是最省的一档）；要量图片背景就传
# --backdrop '{"kind":"image","image":"backdrop.jpg"}'。不固定的话，用户上次
# 挑的那张照片会跟着进测量，两张表就没法比了。
BD_HEX=$(printf '%s' "$BD" | xxd -p | tr -d '\n')
defaults write dev.ezpc.monitor ezpcm.backdrop -data "$BD_HEX"

# ---------------------------------------------------------------- 构建

kill_app
if [ "$BUILD" = "1" ]; then
  echo "==> 构建"
  "$ROOT/macos/build.sh" >/tmp/ezpcm-measure-build.log 2>&1 || {
    echo "构建失败，日志在 /tmp/ezpcm-measure-build.log" >&2
    exit 1
  }
fi

echo "==> 编译探针"
swiftc -O "$ROOT/scripts/probe.swift" \
  "$ROOT/core/target/release/libezpcm_core.a" \
  -import-objc-header "$ROOT/core/include/ezpcm_core.h" \
  -framework IOKit -framework CoreFoundation -framework OpenDirectory \
  -o "$PROBE" 2>/dev/null || { echo "探针编译失败" >&2; exit 1; }

# ---------------------------------------------------------------- 单次测量

footprint_mb() { # $1 = pid → 打印 MB 整数
  footprint -p "$1" 2>/dev/null \
    | awk -F'Footprint: ' '/Footprint:/ {print $2}' \
    | awk '{ if ($2 == "GB") printf "%.0f\n", $1*1024;
             else if ($2 == "MB") printf "%.0f\n", $1;
             else if ($2 == "KB") printf "%.1f\n", $1/1024;
             else print "0" }'
}

measure() { # $1 = 启动参数, $2 = intervalMs → 输出 "footprint rss cpu"
  write_settings "$2"
  kill_app
  # disown：不然 pkill 之后 shell 会往 stderr 打一行 "Terminated: 15"
  "$BIN" $1 >/dev/null 2>&1 &
  disown
  sleep 8                       # 等首帧、首拍、历史落盘这些一次性开销过去
  local pid; pid=$(pgrep -f "EZPcMonitor.app/Contents/MacOS/EZPcMonitor" | tail -1)
  if [ -z "$pid" ]; then echo "0 0 0"; return; fi
  local fp; fp=$(footprint_mb "$pid")
  local out; out=$("$PROBE" "$pid" 5 2)
  local rss cpu
  rss=$(echo "$out" | sed -n 's/.*mem=\([0-9]*\).*/\1/p')
  cpu=$(echo "$out" | sed -n 's/.*cpu=\([0-9.]*\).*/\1/p')
  kill_app
  echo "$fp ${rss:-0} ${cpu:-0}"
}

echo "==> 悬浮窗（1 秒采集）"
read -r FP_W RSS_W CPU_1 < <(measure "" 1000)
echo "    footprint ${FP_W}MB / rss $(awk -v b="$RSS_W" 'BEGIN{printf "%.0f", b/1048576}')MB / cpu ${CPU_1}%"

echo "==> 悬浮窗（5 秒采集）"
read -r _ _ CPU_5 < <(measure "" 5000)
echo "    cpu ${CPU_5}%"

echo "==> 主面板"
read -r FP_D RSS_D _ < <(measure "--dashboard" 1000)
echo "    footprint ${FP_D}MB / rss $(awk -v b="$RSS_D" 'BEGIN{printf "%.0f", b/1048576}')MB"

# ---------------------------------------------------------------- 体积

# 体积用 0.1MB 精度：`du -sm` 会把 5.9 报成 6、6.2 报成 7，
# 一个 +0.3MB 的改动看起来像 +1MB——这个项目的体积敏感，取整会把结论搞反。
APP_MB=$(awk -v k="$(du -sk "$APP" | cut -f1)" 'BEGIN{printf "%.1f", k/1024}')
BIN_MB=$(awk -v b="$(stat -f%z "$BIN")" 'BEGIN{printf "%.1f", b/1048576}')
SHA=$(git -C "$ROOT" rev-parse --short HEAD)
DATE=$(date +%Y-%m-%d)

RSS_W_MB=$(awk -v b="$RSS_W" 'BEGIN{printf "%.0f", b/1048576}')
RSS_D_MB=$(awk -v b="$RSS_D" 'BEGIN{printf "%.0f", b/1048576}')

# ---------------------------------------------------------------- 记录 + 对比

if [ ! -f "$PERF" ]; then
  cat > "$PERF" <<'HEAD'
# 资源占用记录

每加一个功能、每改一次热路径，跑 `./scripts/measure.sh` 追加一行。
数字在同一个环境下测：Release 构建、1 秒采集（CPU 另测一档 5 秒）、
悬浮窗卡片形态、历史记录关闭。**看 delta，不看绝对值。**

同一份代码连测两次会差：内存 ±1~2 MB、CPU ±0.5%。小于这个幅度的差异没有意义。

| 日期 | 提交 | 说明 | .app | 二进制 | 悬浮窗 footprint | 悬浮窗 RSS | 主面板 footprint | CPU 1s | CPU 5s |
|---|---|---|---|---|---|---|---|---|---|
HEAD
fi

# 非默认背景时在说明里带一笔，不然一行数字看不出量的是哪个形态
if [ "$BD" != '{"kind":"material","color":"graphite","opacity":0.94}' ]; then
  KIND=$(printf '%s' "$BD" | sed -n 's/.*"kind":"\([a-z]*\)".*/\1/p')
  NOTE="${NOTE:+$NOTE · }背景=$KIND"
fi

ROW="| $DATE | \`$SHA\` | ${NOTE:--} | ${APP_MB} MB | ${BIN_MB} MB | ${FP_W} MB | ${RSS_W_MB} MB | ${FP_D} MB | ${CPU_1}% | ${CPU_5}% |"
# 先取上一次的数据行（只认以日期开头的行，别把表头当成上一次）
PREV=$(grep -E '^\| [0-9]{4}-' "$PERF" | tail -1 || true)

# 插在**最后一条记录行之后**，而不是文件末尾：表格后面还跟着正文段落
# （比如「图片背景的尺寸账」），直接 >> 会把新行甩到文末，表格就断了。
LINE=$(grep -nE '^\| [0-9]{4}-' "$PERF" | tail -1 | cut -d: -f1 || true)
if [ -n "$LINE" ]; then
  { head -n "$LINE" "$PERF"; echo "$ROW"; tail -n +"$((LINE + 1))" "$PERF"; } > "$PERF.tmp"
  mv "$PERF.tmp" "$PERF"
else
  echo "$ROW" >> "$PERF"
fi

echo
echo "本次：$ROW"
if [ -n "$PREV" ]; then
  echo "上次：$PREV"
  python3 - "$PREV" "$ROW" <<'PY'
import sys
def nums(row):
    out = []
    for c in [c.strip() for c in row.strip().strip('|').split('|')]:
        try:
            out.append(float(c.replace('MB','').replace('%','').strip()))
        except ValueError:
            out.append(None)
    return out
labels = ['.app', '二进制', '悬浮窗 footprint', '悬浮窗 RSS', '主面板 footprint', 'CPU 1s', 'CPU 5s']
a, b = nums(sys.argv[1]), nums(sys.argv[2])
# 前 4 列是日期/提交/说明/... 对齐到数值列
a, b = a[3:], b[3:]
print('差异：')
for name, x, y in zip(labels, a, b):
    if x is None or y is None:
        continue
    d = y - x
    unit = '%' if 'CPU' in name else ' MB'
    flag = '' if abs(d) < 0.05 else ('  ↑' if d > 0 else '  ↓')
    print(f'  {name:16s} {x:6.1f} → {y:6.1f}{unit}   ({d:+.1f}){flag}')
PY
fi
echo
echo "已追加到 docs/PERF.md"
