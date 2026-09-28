# 持续前台条件下的玩法／天气／音频三套审计（2026-09-29）

补齐 `docs/PROGRESS.md`「执行队列」第 2 项留下的尾巴：玩法与天气审计的上一次通过
发生在 `lib/audio/motion.dart` 运动采样修复**之前**，修复后没有重跑。本目录是修复后
在**持续前台**条件下的完整一轮复验。

代码基线：`529c544`（干净检出，Flutter 3.47.4 / Xcode 26.6 / debug 1600×1200）。

## 结论

三套审计全部通过，且这一轮的关键区别是**帧计数全程持续前进**，不是"信号发出去了"。

| 审计 | 命令 | 结果 | 日志 |
|---|---|---|---|
| 音频 | `node tool/audio_audit.mjs --verbose` | **37/37 通过**，静音后输出 0 | `audio.log` |
| 玩法 | `node tool/gameplay_audit.mjs` | **8/8 通过**（连续两轮） | `gameplay-run1.log`、`gameplay-run2.log` |
| 天气 | `node tool/sky_audit.mjs --weathers clear,cloudy,rain,night --camera 0,0.0987 --fps` | 四档切档／帧前进／非空截图全通过 | `sky.log`、`sky-ascii.log`、`screenshots/` |
| 传送压力 | `node tool/audio_teleport_audit.mjs` | **72/72 通过**，5 个活跃声部、输出非零 | `teleport.log` |

附带基线：`flutter analyze --no-pub` 零问题、`flutter test --no-pub` **195 项全部通过**、
`flutter build macos --debug` 成功。

## 本轮真正的技术要点：`open -a` 不足以维持前台

这是任务书里"重点是在自动化流程里把 App 保持在前台"的具体答案，也是之前两次
传送判负的直接原因。

1. `open -a build/macos/.../kirby_scene.app`（**相对路径**）在本机直接失败：
   `Unable to find application named ...`，`open` 退出码 1。必须给**绝对路径**。
2. 即使用绝对路径（退出码 0），它也只给**瞬时**前台：实测 `open -a` 后
   `state.frame` 从 2233 动到 2256，随即又冻结。
3. 真正能稳住的是 System Events 的 `set frontmost`：

   ```bash
   osascript -e 'tell application "System Events" to set frontmost of every process whose unix id is <pid> to true'
   ```

   之后连续 5 次读 `state`，帧 2306 → 2350 → 2385 → 2422 → 2450 稳定推进（约 18 FPS）。

因此新增 `tool/keep_foreground.sh`：审计期间在后台循环发上面那条 `osascript`。
三套审计与传送压力都是在它保活下跑完的。

> 本机是 Aqua 会话（`launchctl managername` = Aqua，`/dev/console` 属主为当前用户），
> 所以 `osascript` 的辅助功能调用可用。若在无 GUI 会话里跑，`open` 与 `osascript`
> 都会失败，那时才需要退回 `AGENTS.md` 里的 Web + CDP 通道。

## 复现命令

```bash
# 1. 先把 debug 构建产物准备好（dev.sh 的等待窗口短于首次完整构建，
#    直接跑会被判「等不到调试服务」而收尾杀掉，所以先单独构建一次）
env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy NO_PROXY=localhost,127.0.0.1 \
  /Users/liliang/flutter/bin/flutter build macos --debug --no-pub

# 2. 起 App
nohup env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
  bash tool/dev.sh --macos --no-watch > build/agent_dev.log 2>&1 &

# 3. 等桥接就绪（首次约 100s）
until nc -z 127.0.0.1 7008; do sleep 5; done

# 4. 每套审计都在保活下跑
PID=$(pgrep -f 'Debug/kirby_scene.app/Contents/MacOS/kirby_scene' | head -1)
bash tool/keep_foreground.sh "$PID" > /dev/null 2>&1 &
KEEPER=$!
node tool/audio_teleport_audit.mjs
node tool/audio_audit.mjs --verbose
node tool/gameplay_audit.mjs
node tool/sky_audit.mjs --weathers clear,cloudy,rain,night --camera 0,0.0987 --fps
kill $KEEPER

# 5. 天气截图与离线度量
node tool/sky_audit.mjs screenshots/*.png --ascii --hp
```

## 天气档的客观度量（本轮）

`--camera 0,0.0987` 归位后，1600×1200 debug：

| 档 | 帧率 | 全图均值 | 天空带均值 | 起伏σ | 亮云% | 暗云% |
|---|---|---|---|---|---|---|
| clear | ≈28.6 | 169.2 | 197.8 | 8.5 | 0.00 | 0.00 |
| cloudy | ≈28.3 | 145.8 | 181.5 | 16.9 | 4.56 | 9.15 |
| rain | ≈26.4 | 105.4 | 138.0 | 22.7 | 1.41 | 24.84 |
| night | ≈28.1 | 27.7 | 21.2 | 12.7 | 14.44 | 0.00 |

沿用既有四条解读铁律的边界：

- **晴天亮云 0.00% 不是缺陷**。该机位（yaw=0、pitch=0.0987）下晴天天空本身接近饱和白
  （高亮占比 58.47%），云"隐入天空"；这与 `audio-velocity` 之前记录的一致，
  截图通过**不能**推广成"所有机位云可见性达标"。
- 帧率是 debug 短采样，不是 profile 稳态基线。本机跑着保活循环
  （每 2 秒一次 `osascript`），与上一轮 31.9~34.9 FPS 的测量条件也不同，
  两个数字**不可直接比较**。
- 夜空的 14.44% 亮云来自饱和蓝夜空被算成真亮度
  （`0.299R+0.587G+0.114B`），只取 R 通道会误判为纯黑。

## 过程中一次未复现的判负（如实记录）

第一次跑 `gameplay_audit.mjs` 时判负，但**不是同一个原因**，值得单独记一笔：

```
✓ App 就绪且帧在推进        —— frame=2792
✗ 12 颗星核全部收集         —— score=11/12
✗ 通关判据 cleared=true
✓ 收集期间帧持续推进        —— 2804 → 2946     ← 帧是前进的
```

帧在前进，所以这次**不是**窗口停帧那一类。`tool/gameplay_audit.mjs` 的坐标公式与
`lib/game/world.dart` 的 `_spawnPickups` 逐项一致（三环 8/14/19.5 各 4 颗、
相位偏移用**全局 index** × 0.35），不是脚本与游戏脱节。

随后用 `tool/pickup_probe.mjs` 逐颗打印落点，**12/12 全部收集**、
`cleared=true`（`pickup-probe.log`）；紧接着连跑两轮 `gameplay_audit.mjs` 也是 8/8。
所以判负只在**紧接上一次窗口冻结之后**的那一次出现，未能复现。

采集半径是 1.5m 的**三维**距离（`world.dart` 的 `_updatePickups`），星核挂在
`terrain.heightAt+1.15`，而 `teleport` 只给 x/z、角色仍需落地稳定。
该轮在冻结恢复后的边界状态下，某次传送的 900ms 落点稳定窗口可能不足。
本轮**不**把它记为代码缺陷，也**不**因此调大采集半径或延长 sleep ——
那会用放宽判据掩盖问题。若要定论，需要能稳定复现的循环。
