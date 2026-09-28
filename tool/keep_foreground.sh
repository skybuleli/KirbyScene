#!/usr/bin/env bash
# 持续把 App 拉前台的看门狗：macOS 窗口一旦失去 key 状态帧循环就会冻结，
# 判据（state.frame 前进）随之失败。open -a 只给瞬时前台，System Events 的
# set frontmost 才能稳住，所以审计期间用它在后台循环拉。
PID="${1:?需要 App 进程 pid}"
while kill -0 "$PID" 2>/dev/null; do
  osascript -e "tell application \"System Events\" to set frontmost of every process whose unix id is $PID to true" >/dev/null 2>&1
  sleep 2
done
