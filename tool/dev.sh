#!/usr/bin/env bash
#
# KirbyScene 开发循环：跑调试版，并在源码变化时自动热重载。
#
# ── 为什么默认目标是 Web 而不是 macOS ────────────────────────────────────
#
# macOS 目标需要**完整 Xcode**（`xcodebuild` + macOS SDK），本机只有
# Command Line Tools，且数据卷仅剩约 20GB 而 Xcode 26 需要 40–50GB 可用空间。
# 所以 `flutter run -d macos` 当前直接失败，热重载也无从谈起。
#
# Web 通道零 Xcode 依赖，而且 Flutter 3.47 起 `--web-experimental-hot-reload`
# **默认开启**，配合 `--pid-file` 就能用信号触发热重载/热重启。
#
# 等补齐 Xcode 后，把 DEVICE 换成 macos 即可，其余逻辑（监听 + 发信号）完全一致：
#   flutter run -d macos --pid-file=...   # 同样支持 SIGUSR1 / SIGUSR2
#
# ── 用法 ────────────────────────────────────────────────────────────────
#
#   tool/dev.sh                 启动（有头 Chrome）+ 监听 lib/ 自动热重载
#   tool/dev.sh --no-watch      只启动，不自动监听（自己按 r / R）
#   tool/dev.sh --port 8123     指定 web 端口（默认 8123）
#   tool/dev.sh --query demo=1  附加查询串（例如开自动演示）
#   tool/dev.sh --macos         改用 macOS 目标（需要完整 Xcode）
#
#   tool/dev.sh reload          给正在跑的会话发 SIGUSR1（热重载）
#   tool/dev.sh restart         给正在跑的会话发 SIGUSR2（热重启）
#   tool/dev.sh status          查看会话状态
#   tool/dev.sh stop            结束会话
#
# ── 热重载 vs 热重启 ────────────────────────────────────────────────────
#
#   热重载（SIGUSR1 / r）：**保留**应用状态，只替换改动的代码。
#     适合改 UI、改数值、改每帧逻辑。本脚本默认用这个。
#   热重启（SIGUSR2 / R）：重置状态并重跑 main()。
#     改到初始化逻辑、或者状态已经被带坏了（比如启动时抛过异常）时用这个。
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUTTER="${KIRBY_FLUTTER:-/Users/liliang/flutter/bin/flutter}"
# pid 与日志都放项目内：系统临时目录在受限宿主里可能被删除保护拦住。
PID_FILE="$ROOT/build/dev_run.pid"
LOG_FILE="$ROOT/build/dev_run.log"

DEVICE="chrome"
WEB_PORT="8123"
DEBUG_PORT="9333"
QUERY=""
WATCH=1
CHECK_ONLY=0

die()  { printf '\033[31m✗ %s\033[0m\n' "$1" >&2; exit 1; }
info() { printf '\033[36m·\033[0m %s\n' "$1"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$1"; }

# ---- 给正在运行的会话发信号（子命令） --------------------------------------

_require_session() {
  [ -f "$PID_FILE" ] || die "没有正在运行的会话（找不到 $PID_FILE）。先执行 tool/dev.sh"
  SESSION_PID="$(cat "$PID_FILE")"
  kill -0 "$SESSION_PID" 2>/dev/null || die "会话进程 $SESSION_PID 已不在（脏 pid 文件）"
}

case "${1:-}" in
  reload)
    _require_session
    kill -USR1 "$SESSION_PID"
    ok "已发送 SIGUSR1（热重载）→ pid $SESSION_PID"
    exit 0
    ;;
  restart)
    _require_session
    kill -USR2 "$SESSION_PID"
    ok "已发送 SIGUSR2（热重启）→ pid $SESSION_PID"
    exit 0
    ;;
  status)
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
      ok "会话在跑：pid $(cat "$PID_FILE")"
      printf '  日志：%s\n' "$LOG_FILE"
      tail -n 6 "$LOG_FILE" 2>/dev/null | sed 's/^/    /'
    else
      info "没有正在运行的会话"
    fi
    exit 0
    ;;
  stop)
    if [ -f "$PID_FILE" ]; then
      SESSION_PID="$(cat "$PID_FILE")"
      kill "$SESSION_PID" 2>/dev/null || true
      sleep 1
      kill -0 "$SESSION_PID" 2>/dev/null && kill -9 "$SESSION_PID" 2>/dev/null || true
      rm -f "$PID_FILE" 2>/dev/null || true
      ok "会话已结束"
    else
      info "没有正在运行的会话"
    fi
    exit 0
    ;;
esac

# ---- 解析参数 -------------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    --port)      WEB_PORT="${2:?--port 需要一个值}"; shift 2 ;;
    --debug-port) DEBUG_PORT="${2:?--debug-port 需要一个值}"; shift 2 ;;
    --query)     QUERY="${2:?--query 需要一个值}"; shift 2 ;;
    --no-watch)  WATCH=0; shift ;;
    --macos)     DEVICE="macos"; shift ;;
    --check)     CHECK_ONLY=1; shift ;;
    -h|--help)   sed -n '2,50p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "未知参数：$1（用 --help 看用法）" ;;
  esac
done

[ -x "$FLUTTER" ] || die "找不到 flutter：$FLUTTER（可用 KIRBY_FLUTTER 覆盖）"
[ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null \
  && die "已有会话在跑（pid $(cat "$PID_FILE")）。先执行 tool/dev.sh stop"

# ---- 定位 Xcode 工具链 ----------------------------------------------------
#
# 本机的真实情况（值得留注释，否则下次还会踩）：
# Xcode 26.6 装在 `~/Downloads/Xcode.app`，**不在标准位置**，而
# `xcode-select -p` 仍指向 `/Library/Developer/CommandLineTools`。
# 这种组合下 `xcrun --find xcodebuild` 会失败、`flutter doctor` 也报
# "Xcode installation is incomplete"，**但只要把 DEVELOPER_DIR 指过去，
# 编译其实完全正常**（`flutter run -d macos` 能成功出 .app）。
#
# 所以这里主动去找，而不是直接判定"没有 Xcode"。
# 找到后导出 DEVELOPER_DIR，子进程（flutter run）就能继承。

XCODE_APP=""
_resolve_developer_dir() {
  # 1) 外部已经设好且有效 —— 尊重它
  if [ -n "${DEVELOPER_DIR:-}" ] && [ -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]; then
    XCODE_APP="$(cd "$DEVELOPER_DIR/../.." && pwd)"
    return 0
  fi

  # 2) xcode-select 指向真正的 Xcode
  local sel=""
  sel="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
  if [ -n "$sel" ] && [ -x "$sel/usr/bin/xcodebuild" ]; then
    export DEVELOPER_DIR="$sel"
    XCODE_APP="$(cd "$sel/../.." && pwd)"
    return 0
  fi

  # 3) 扫描常见位置（含非标准的 ~/Downloads —— 本机就是这么装的）
  local cand
  for cand in "/Applications/Xcode.app" "$HOME/Applications/Xcode.app" \
              "$HOME/Downloads/Xcode.app" "/Applications/Xcode-beta.app"; do
    if [ -x "$cand/Contents/Developer/usr/bin/xcodebuild" ]; then
      export DEVELOPER_DIR="$cand/Contents/Developer"
      XCODE_APP="$cand"
      return 0
    fi
  done

  return 1
}

if [ "$DEVICE" = "macos" ]; then
  if _resolve_developer_dir; then
    info "Xcode 工具链：$XCODE_APP"
    if [ "$XCODE_APP" != "/Applications/Xcode.app" ]; then
      printf '\033[33m!\033[0m Xcode 不在标准位置，只有拿到 DEVELOPER_DIR 的工具才用得上它。\n'
      printf '  flutter doctor 仍会报 incomplete，IDE / CI 里也可能失败。建议归位：\n'
      printf '    sudo mv "%s" /Applications/\n' "$XCODE_APP"
      printf '    sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer\n\n'
    fi
  else
    die "找不到可用的 Xcode 工具链。
    检查过：DEVELOPER_DIR、xcode-select -p、/Applications 与 ~/Downloads。
    装好 Xcode 后执行：sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer"
  fi
fi

# ---- 环境自检（--check 时只报告，不启动）------------------------------------

if [ "$CHECK_ONLY" -eq 1 ]; then
  printf '\n'
  info "目标设备：$DEVICE"
  if [ "$DEVICE" = "chrome" ]; then
    info "web 端口 $WEB_PORT ｜ 调试端口 $DEBUG_PORT（kirby_mcp 可 attach_only 接管）"
  fi
  if _resolve_developer_dir; then
    ok "Xcode：$XCODE_APP"
    info "DEVELOPER_DIR=${DEVELOPER_DIR:-<未设置>}"
  else
    printf '\033[33m!\033[0m 未找到 Xcode 工具链 —— macOS 目标不可用（Web 目标不受影响）\n'
  fi
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    ok "已有会话在跑：pid $(cat "$PID_FILE")"
  else
    info "没有正在运行的会话"
  fi
  exit 0
fi

# ---- 启动调试会话 ---------------------------------------------------------

mkdir -p "$(dirname "$LOG_FILE")"
rm -f "$PID_FILE" "$LOG_FILE" 2>/dev/null || true

# 本机环境注入了 HTTP_PROXY 却没有 NO_PROXY，会让 flutter 的本地调试服务
# （以及 Chrome 连 localhost）出错，所以这里显式清掉。
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy
export NO_PROXY="localhost,127.0.0.1"
export no_proxy="$NO_PROXY"

RUN_ARGS=(
  run -d "$DEVICE"
  --pid-file="$PID_FILE"
)

if [ "$DEVICE" = "chrome" ]; then
  URL="http://localhost:$WEB_PORT/${QUERY:+?$QUERY}"
  RUN_ARGS+=(
    --web-port="$WEB_PORT"
    # 固定调试端口，方便 kirby_mcp 用 attach_only 接管同一个浏览器，
    # 这样「热重载」和「MCP 工具」可以共用会话。
    --web-browser-debug-port="$DEBUG_PORT"
    # 本机 Chrome 在受限宿主里必须关沙箱，否则 GPU 进程起不来。
    "--web-browser-flag=--no-sandbox"
    "--web-browser-flag=--disable-gpu-sandbox"
    # 关掉后台节流：窗口被遮挡时 rAF 会被暂停，
    # 那通过 CDP 推帧的自动化就会一直等不到帧。
    "--web-browser-flag=--disable-backgrounding-occluded-windows"
    "--web-browser-flag=--disable-renderer-backgrounding"
  )
else
  URL="macOS 桌面窗口"
fi

info "启动 flutter run -d $DEVICE …"
"$FLUTTER" "${RUN_ARGS[@]}" >"$LOG_FILE" 2>&1 &
FLUTTER_PID=$!

_cleanup() {
  printf '\n'
  info "收尾中…"
  kill "$FLUTTER_PID" 2>/dev/null || true
  rm -f "$PID_FILE" 2>/dev/null || true
}
trap _cleanup EXIT INT TERM

# 等调试服务就绪（出现 "Flutter run key commands" 才算真正跑起来）
info "等待调试服务就绪…"
for _ in $(seq 1 90); do
  grep -q "Flutter run key commands" "$LOG_FILE" 2>/dev/null && break
  grep -qiE "^Error|Exception:|Failed to" "$LOG_FILE" 2>/dev/null && {
    printf '\n'; tail -n 30 "$LOG_FILE"; die "启动失败，见上方日志"
  }
  kill -0 "$FLUTTER_PID" 2>/dev/null || { tail -n 30 "$LOG_FILE"; die "flutter run 提前退出"; }
  sleep 1
done
grep -q "Flutter run key commands" "$LOG_FILE" || { tail -n 30 "$LOG_FILE"; die "等不到调试服务"; }

ok "已就绪：$URL"
printf '  调试端口 %s（kirby_mcp 可用 run_project {attach_only:true} 接管）\n' "$DEBUG_PORT"
printf '  日志     %s\n' "$LOG_FILE"
printf '\n'

if [ "$WATCH" -eq 0 ]; then
  info "未开启自动监听。在此终端按 r 热重载 / R 热重启 / q 退出。"
  wait "$FLUTTER_PID"
  exit 0
fi

# ---- 监听源码变化并自动热重载 ---------------------------------------------

# 源码快照：用**文件内容摘要**，不用 stat 元数据。
#
# 这是一个踩过的坑，值得留注释：`find -exec stat -f '%m %z %N'` 在受限宿主里
# 可能解析到 toybox 版的 stat（不认 macOS 的 `-f`），它会**安静地失败**——
# 于是快照恒定不变，「保存了却检测不到改动」，而且 find 的非零退出码还会在
# `set -o pipefail` 下把整个脚本带停。内容摘要不依赖 stat，
# 副作用是"只改 mtime、内容没变"不会触发重载——这正是我们想要的。
_snapshot() {
  local out=""
  if command -v md5 >/dev/null 2>&1; then
    out="$(find "$ROOT/lib" -type f -name '*.dart' -print0 2>/dev/null \
      | sort -z | xargs -0 md5 -q 2>/dev/null | md5 2>/dev/null)" || out=""
  else
    out="$(find "$ROOT/lib" -type f -name '*.dart' -print0 2>/dev/null \
      | sort -z | xargs -0 md5sum 2>/dev/null | md5sum 2>/dev/null)" || out=""
  fi
  printf '%s' "$out"
}

LAST="$(_snapshot)"
if [ -z "$LAST" ]; then
  die "源码快照为空，监听不会生效（检查 lib/ 是否可读、md5/xargs 是否可用）"
fi
info "开始监听 lib/**/*.dart —— 保存即热重载（Ctrl-C 结束）"
printf '\n'

while kill -0 "$FLUTTER_PID" 2>/dev/null; do
  sleep 1
  CURRENT="$(_snapshot)"
  if [ "$CURRENT" = "$LAST" ]; then continue; fi

  # 编辑器保存往往是多次写入，等文件稳定下来再触发，避免重载到一半的代码。
  STABLE="$CURRENT"
  sleep 1
  if [ "$(_snapshot)" != "$STABLE" ]; then continue; fi
  LAST="$STABLE"

  # 用日志里 "Reloaded application" 的出现次数判断这次重载是否成功，
  # 而不是只看有没有输出——否则会出现"看着成功其实没生效"。
  BEFORE="$(grep -c 'Reloaded application' "$LOG_FILE" 2>/dev/null || true)"
  BEFORE="${BEFORE:-0}"

  kill -USR1 "$FLUTTER_PID" 2>/dev/null || true

  AFTER="$BEFORE"
  for _ in $(seq 1 80); do
    sleep 0.25
    AFTER="$(grep -c 'Reloaded application' "$LOG_FILE" 2>/dev/null || true)"
    AFTER="${AFTER:-0}"
    if [ "$AFTER" -gt "$BEFORE" ]; then break; fi
  done

  if [ "$AFTER" -gt "$BEFORE" ]; then
    RELOAD_MS="$(grep 'Reloaded application in' "$LOG_FILE" | tail -n 1 | sed 's/.*in //')"
    ok "热重载完成${RELOAD_MS:+（$RELOAD_MS）}"
  else
    printf '\033[33m!\033[0m 热重载没有回报成功。若是改动涉及初始化逻辑，'
    printf '改用 tool/dev.sh restart 做热重启。日志末尾：\n'
    tail -n 8 "$LOG_FILE" | sed 's/^/    /'
  fi
done

info "flutter run 已退出"
