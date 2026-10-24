#!/usr/bin/env bash
#
# 原生版构建入口。产物：macos/build/EZPcMonitor.app
#
# 为什么不用 Xcode 工程：整个应用只有一个 Swift 模块，`.xcodeproj` 是二进制
# plist，改一行要整份重写，冲突起来没法看；这个项目也没有 nib/storyboard/
# 资源编译这些非 Xcode 不可的东西。
#
# 为什么也不用 SwiftPM：这台机器只装了 CommandLineTools，其中的
# PackageDescription 模块和 dylib 版本对不上（`.swiftLanguageMode` 编译期找不到，
# `swiftLanguageVersions` 链接期找不到），任何 manifest 都编不过。应用就一个模块，
# 直接 `swiftc` 把全部源文件一起编译反而更简单，也不依赖那个库。
# 代价是没有增量编译——两千多行几秒钟，可以接受。
#
# 用法：
#   ./macos/build.sh            # release 构建
#   ./macos/build.sh --open     # 构建并启动
#   ./macos/build.sh --debug    # 不优化（快，但内存/CPU 数据别拿它量）
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAC="$ROOT/macos"
CONFIG="release"
OPEN_AFTER=0

for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG="debug" ;;
    --open)  OPEN_AFTER=1 ;;
    *) echo "未知参数: $arg" >&2; exit 2 ;;
  esac
done

# 目标架构跟着本机走；要出通用包再加 -arch x86_64
ARCH="$(uname -m)"
DEPLOY="13.0"

NODE="${NODE:-node}"
if ! command -v "$NODE" >/dev/null 2>&1; then
  NODE="/Users/wargon/.workbuddy-ai/binaries/node/versions/22.22.2-6/bin/node"
fi

echo "==> 1/4 Rust core（${CONFIG}）"
if [ "${CONFIG}" = "release" ]; then
  cargo build --manifest-path "$ROOT/core/Cargo.toml" --release
  LIBDIR="$ROOT/core/target/release"
else
  cargo build --manifest-path "$ROOT/core/Cargo.toml"
  LIBDIR="$ROOT/core/target/debug"
fi

echo "==> 2/4 多语言字典"
if [ -x "$NODE" ] || command -v "$NODE" >/dev/null 2>&1; then
  "$NODE" --experimental-strip-types "$MAC/tools/extract-strings.mjs" || \
    echo "    （字典导出失败，沿用已有的 strings.json）"
fi

echo "==> 3/4 Swift（${CONFIG}，${ARCH}-apple-macos${DEPLOY}）"
APP="$MAC/build/EZPcMonitor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"

if [ "${CONFIG}" = "release" ]; then
  OPT=(-O -whole-module-optimization)
else
  OPT=(-Onone -g)
fi

# shellcheck disable=SC2046
swiftc "${OPT[@]}" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -import-objc-header "$ROOT/core/include/ezpcm_core.h" \
  -o "$APP/Contents/MacOS/EZPcMonitor" \
  $(find "$MAC/Sources/EZPcMonitor" -name '*.swift' | sort) \
  "$LIBDIR/libezpcm_core.a" \
  -framework IOKit -framework CoreFoundation -framework OpenDirectory

echo "==> 4/4 组装 .app"
cp "$MAC/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$MAC/Resources/strings.json" "$APP/Contents/Resources/strings.json"
cp "$ROOT/src-tauri/icons/icon.icns" "$APP/Contents/Resources/AppIcon.icns"
# 硬盘 SMART 要它；没有就回落系统装的那份（brew install smartmontools）
if [ -f "$ROOT/src-tauri/resources/bin/smartctl" ]; then
  cp "$ROOT/src-tauri/resources/bin/smartctl" "$APP/Contents/Resources/bin/smartctl"
  chmod +x "$APP/Contents/Resources/bin/smartctl"
  cp "$ROOT/src-tauri/resources/bin/COPYING" "$APP/Contents/Resources/bin/COPYING" 2>/dev/null || true
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

# ad-hoc 签名够本地跑。要分发得换开发者证书，否则换台机器会被 Gatekeeper 拦。
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || \
  echo "    （签名失败，不影响本机运行）"

echo "完成：${APP} ($(du -sh "${APP}" | cut -f1))"

if [ "$OPEN_AFTER" = "1" ]; then
  pkill -f "EZPcMonitor.app/Contents/MacOS/EZPcMonitor" 2>/dev/null || true
  sleep 0.3
  open "$APP"
  echo "已启动。"
fi
