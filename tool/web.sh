#!/usr/bin/env bash
# KirbyScene Web 预览 / 截图（完全不需要 Xcode）
#
# 用法：
#   tool/web.sh                      构建并起本地服务，前台运行（Ctrl-C 结束）
#   tool/web.sh --shot out.png       构建 + 起服务 + 无头截图 + 自动关服务
#   tool/web.sh --demo               预览自动演示模式（?demo=1）
#   tool/web.sh --weather rain       预览指定天气（clear / cloudy / rain）
#   tool/web.sh --no-build           跳过构建，直接服务现有 build/web
#   tool/web.sh --port 8200          换端口
#
# 可覆盖的环境变量：FLUTTER / PYTHON / CHROME
#
# 为什么这个脚本存在：Flutter 的 macOS 目标要求完整 Xcode（xcodebuild + macOS SDK +
# CocoaPods），而 Web 目标不需要——产物是 JS + CanvasKit，没有原生宿主壳要编译。

set -euo pipefail

PORT=8100
SHOT=""
DO_BUILD=1
QUERY=""

usage() {
  sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --shot) SHOT="$2"; shift 2 ;;
    --no-build) DO_BUILD=0; shift ;;
    --demo) QUERY="${QUERY}&demo=1"; shift ;;
    --weather) QUERY="${QUERY}&weather=$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; usage >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FLUTTER="${FLUTTER:-$(command -v flutter || true)}"
[[ -n "$FLUTTER" ]] || FLUTTER=/Users/liliang/flutter/bin/flutter
PYTHON="${PYTHON:-$(command -v python3)}"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"

if [[ "$DO_BUILD" == "1" ]]; then
  echo "==> 构建 Web（无需 Xcode）"
  "$FLUTTER" build web --no-tree-shake-icons
fi

[[ -f build/web/index.html ]] || { echo "build/web 不存在，请先构建" >&2; exit 1; }

echo "==> 启动静态服务：http://localhost:${PORT}"
"$PYTHON" -m http.server "$PORT" --directory build/web >/dev/null 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

sleep 1

URL="http://localhost:${PORT}/?v=$(date +%s)${QUERY}"

if [[ -n "$SHOT" ]]; then
  echo "==> 无头截图 → ${SHOT}"
  mkdir -p "$(dirname "$SHOT")"
  # 参数说明（缺一个都会出问题）：
  #  --no-sandbox / --disable-gpu-sandbox : 受限宿主里 Chrome 的 seatbelt 起不来
  #  --enable-unsafe-swiftshader          : 无 GPU 时用软件光栅化，否则拿不到 WebGL2
  #  --no-proxy-server                    : 环境里有 HTTP_PROXY，会干扰 localhost
  #  --run-all-compositor-stages-before-draw :
  #      关键！否则 headless 下 requestAnimationFrame 只跑 1 帧，
  #      画面会停在初始状态（看起来像"游戏没在动"）。
  #  --virtual-time-budget                : 给足虚拟时间让帧循环推进。
  "$CHROME" \
    --headless=new --no-sandbox --disable-gpu-sandbox \
    --no-proxy-server --enable-unsafe-swiftshader --hide-scrollbars \
    --run-all-compositor-stages-before-draw \
    --virtual-time-budget=120000 \
    --screenshot="$SHOT" --window-size=1440,900 \
    "$URL" >/dev/null 2>&1 || true
  if [[ -f "$SHOT" ]]; then
    echo "完成：${SHOT}"
  else
    echo "截图失败——检查 CHROME 路径是否正确" >&2
    exit 1
  fi
else
  echo "打开 ${URL}"
  echo "（Ctrl-C 结束；加 --demo 可看自动演示）"
  wait "$SERVER_PID"
fi
