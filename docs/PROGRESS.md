# 项目进度与执行顺序

## 当前定位

可玩的程序化收集关卡与环境生态原型。尚未实现完整的类卡比战斗、漂浮、吞吸和能力系统。

## 基线验收结果（2026-09-17，macOS debug 构建）

| 项目 | 结果 |
|---|---|
| 依赖声明 | `hooks` 已声明为直接依赖（提交 `2bd603e`）；`flutter analyze` 零问题 |
| 全量测试 | 上轮工作区 182 项通过；当时干净导出的 `2bd603e` 是旧骨架，仅验证了 41 项，不能称为完整 182 项干净检出验证 |
| 音频审计 | `tool/audio_audit.mjs`：37/37 通过 |
| 天气审计 | `tool/sky_audit.mjs`：四档切档、帧前进、截图与云结构度量全部通过；cloudy/rain/night 实测 31.8–35.0fps（clear 档测速时恰逢帧短暂冻结，无有效读数） |
| 玩法端到端 | `tool/gameplay_audit.mjs`：收集 12/12 星核、通关、重玩归零、回出生点，全部通过 |
| 启动采样 | App 内 `bootTimeline.ready≈1277ms`；音频烘焙 28 份资源 0 失败；按键到移动 115–123ms |
| README | 已同步实际模块与开发约束 |

两处实测踩坑已修在脚本里（非游戏代码缺陷）：

- `audio_audit.mjs` 夜层等待判据（`>0.02`）与断言（`===0`）错配 → 撞上淡出尾段误报 3 项；改为与断言一致。
- `gameplay_audit.mjs` 星核坐标相位偏移必须用**全局 index**（`world.dart _spawnPickups`），用环内序号会 11/12 颗对不上；帧推进现在是硬判据，冻结帧直接判负。

## P1 性能测量进展

设备：Apple M1 / arm64，macOS 26.4.1；固定机位 yaw=0、pitch=0.0987、distance=8.5。

- **debug 四天气补测**：clear 31.9、cloudy 31.8、rain 31.0、night 32.2 FPS。均通过切档与截图帧推进检查；只作开发参考，不代表 profile/release 性能。
- **开发启动耗时**：增量构建加启动至 `ready` 共约 31s（2s 轮询粒度），不是纯 App 冷启动时间；App 内 `bootTimeline.ready=1183ms`，音频烘焙 1275ms。采样时 `armMs=0` 不能当初始化耗时通过。
- **输入延迟**：本轮探针未取得有效数据；上轮 115–123ms 是远程注入后的采样延迟，不是冷启动首次真实按键延迟。
- **profile 帧计时已接通**：应用内 `addTimingsCallback` 得到首个 2.083s / 75 帧窗口，35.5 FPS，UI 均值 24.11ms / p95 54.58ms，raster 均值 1.92ms / p95 2.38ms。属于启动短窗口，不能直接判定长期瓶颈。
- **晴天短窗口参考**：完整日志中另有 7 个约两秒的晴天窗口：38.6–42.5 FPS，UI 均值 19.87–22.02ms / 各窗口 p95 42.75–47.89ms，raster 均值 0.35–0.46ms。提示优先调查 UI 线程；这些是间断短窗口，不是连续 30s 稳态验收，也不能定位到具体对象分配。
- **桥接断连修复（已实机复验）**：已用真实 socket 复现“截图响应传输中客户端提前断开”，修复前测试报 `Write failed / Connection reset by peer, errno=54`。根因是 `socket.add()` 之后的异步写错误从未监听的 `socket.done` 逸出，同步 try/catch 和读取流 onError 无法处理。修复后在 profile App 上连续 3 轮接收截图前 4096 字节后强制断开，每次后续 `ping` 都成功，日志中未捕获异常与连接重置为 0；产物在 `docs/verification/bridge-disconnect/`。另在 `test/inproc_host_test.dart` 加了真实 socket 回归测试，桥接相关 33 项测试通过。
- **稳定 profile 基线仍未完成**：修复后 30 秒连续采样中仅第 1 秒前进 21 帧，其余逐秒 delta=0（`continuous=false`，表观 0.7 FPS），全部剔除——确认桥接修复不解决后台停帧，真正的稳态测量需要 App 持续前台（或由用户终端持有会话）。

新增 `lib/ui/perf.dart` 与显式启用的 HUD 计时：FPS 使用 `(帧数-1)/实际帧起始跨度`，p95 使用最近秩，raster 不标作纯 GPU 时间。测试覆盖时间跨度、停帧、空窗口、p95 和精确输出格式。默认及 release HUD 不启用此诊断。

复测命令（需保持 App 前台，不遮挡窗口）：

```bash
env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
  NO_PROXY=localhost,127.0.0.1 \
  /Users/liliang/flutter/bin/flutter run -d macos --profile --dart-define=KIRBY_PERF=true
```

每个约两秒帧时间窗口输出 `[PERF] fps=... frames=... window=... ui=... p95ui=... raster=... p95raster=... weather=...`。
验收需暖机、固定机位与窗口尺寸、逐秒确认帧推进，再保留稳定窗口；切档及暂停跨越窗口不得用于稳定基线。
本轮未修改游戏逻辑以“优化”分配，也没有可宣称的优化前后收益。

## 依赖升级调查：flutter_soloud 5.x 被阻塞（2026-09-17）

目标：取 SoLoud 5.x 的新能力（`playScheduled` 低延迟、`stopAudioDevice/startAudioDevice` 暂停恢复、`audioVisualizationEvents` FFT 流）。
结果：**无法升级，版本求解失败** —— `flutter_scene 0.23.0`（当前最新稳定版）锁定 `code_assets ^1.2.1`，而 `flutter_soloud >=5.0.0-pre.2` 要求 `code_assets ^2.0.0`，两者互斥；4.x 未声明 code_assets，不受影响。

已评估并否决的选项：降级 flutter_scene 到 0.20.x（为音频降渲染引擎，风险远大于收益）；`dependency_overrides` 强压 code_assets（两个包的 native 构建钩子都针对主版本 API 编写，强压可能构建时才炸）。
解除条件：flutter_scene 发布兼容 code_assets 2.x 的版本（届时重新评估，升级后必须重跑全量测试 + `audio_audit` + 实机音频复验）。当前保留 `flutter_soloud ^4.1.7`；新功能在 4.x 下不可用，待解锁后再评估，不提前写代码。

**override 实验已做并否决（2026-09-17）**：`dependency_overrides: code_assets ^2.0.0` 能通过版本求解，但 debug 构建在 `objective_c 9.5.0` 的 build hook 编译期失败——code_assets 2.x 的 `OS`/`Architecture` 枚举不再支持 const 集合/映射键（primitive equality），`objective_c`（flutter_scene 的依赖）的 hook 源码按 1.x API 写死。日志留档 `build/soloud5-build.log`。结论：flutter_scene 依赖链在 code_assets 2.x 下无法构建，与本轮是否接 SoLoud 无关；除非上游同时更新，否则无绕过方案。

## P0 依赖恢复与本轮验证

进度核对时发现工作区仍残留第二轮升级实验：`flutter_soloud ^5.1.1` 与
`dependency_overrides: code_assets: 2.0.0`。实际运行 `flutter test --no-pub`，
仍在 `objective_c 9.5.0` 构建钩子的 const 集合／映射键处失败，测试尚未启动；
这说明精确固定到 2.0.0 也未解决问题。静态分析当时通过，不能据此判断原生构建可用。

本轮恢复 `flutter_soloud ^4.1.7` 并移除 override，重新执行 `flutter pub get`，
解析结果为 SoLoud 4.1.7、code_assets 1.2.1、objective_c 9.5.0，无需额外固定 objective_c。

- `flutter analyze --no-pub`：零问题。
- `flutter test --no-pub --reporter expanded`：**187 项全部通过**，日志 `build/p0-test.log`。
- `flutter build macos --debug --no-pub`：成功，日志 `build/p0-macos-build.log`。
- 后续实机复验发现环境音装配泄漏，修复与最新验证结果见下节；上表音频 37/37 仍是历史基线，不代表本轮完整审计通过。
- 上述结果针对当前工作区，不代表干净检出验证；未自动提交现有记忆文档改动。

## P0 实机复验与环境音生命周期修复

已退出旧 App，重新启动本轮构建，而非对旧进程直接验收。

- **玩法**：修复前后均通过收集 12/12、通关、重玩归零、回出生点及帧推进检查。
- **天气**：修复前后四档切换、帧推进、非空截图均通过。修复前 debug / 1600×1200 / yaw=0、pitch=0.0987 短采样为 clear 34.4、cloudy 34.9、rain 31.9、night 34.4 FPS；不是 profile 稳态基线。晴天该机位云对比阈值占比为 0，截图通过不能等同于所有机位云可见性达标。
- **音频首轮**：36/37 通过，全部环境层静音后实测输出仍为 0.0234（静音前 0.0271）。短探针确认层 level/applied 已归零且 tracked voices 为 0，但引擎仍有 4 个声部持续出声超过 10 秒，期间没有新 SFX 起播。
- **根因与修复**：`AudioManager._installAllBaked()` 等路径重复调用 `AmbienceLayerPlayer.prepare()`；旧实现直接清空仍在播放的句柄列表，丢失旧循环声部的所有权。`lib/audio/ambience.dart` 现将装配改为幂等、并发共用 Future、资源完整后一次发布，释放等待进行中的装配结束。没有添加全局 stopAll，也没有修改音频审计阈值。
- **回归**：新增 `test/ambience_lifecycle_test.dart` 四项测试。旧实现复现重复装配后残留句柄、并发重复加载、释放后资源重新发布三个失败；修复后普通静音、重复／并发装配、装配中释放均通过。静态分析零问题、全量 **191 项通过**、macOS debug 构建成功。
- **修复后实机静音探针**：环境层静音约 2 秒后，引擎声部为 **0**，左右输出均为 **0**，持续至第 12 秒，帧正常推进。已证明孤立循环声部修复生效，不只依赖单测。

### 音频锁等待：已完成应用侧修复与一轮全量实机验证

修复后的完整音频审计在第 6 节远距离采样时 TCP 超时，不能记作 37/37 通过。
进程仍存活，拉前台后 ping 仍超时，区别于此前后台停帧但桥接可应答的情况。
3 秒原生线程采样显示主线程在 `SoLoud::update3dAudio()` 的
`_pthread_mutex_firstfit_lock_wait` 等待；音频线程在 `mix_internal` /
`readSourceSamples_internal` / `WavInstance::getAudio` 持续执行。
后续复现将触发条件缩小到远距离传送：位移按帧差计算成 -2820.06m/s 的伪速度，
送入多普勒。使用当前 SoLoud 源码和 NULL 后端的单线程原生探针，同一位置下正常速度
可完成混音，记录到的负向超大速度在 3 秒内无法完成；无需窗口或两个应用线程的锁序列。
尚未定位原生重采样内部的精确停滞机制，不能用 Dart timeout 或外层互斥锁冒充修复。

应用修复：新增 `lib/audio/motion.dart`，拒绝超出角色合理运动范围（64m/s）的位移速度，
处理非法 dt／非有限数据；传送与重玩显式 `audio.resetMotion()`，避免伪速度进入多普勒及脚步。
保留 3D 音频，移除实验开关，不修改依赖缓存。新增四项运动采样测试。

最新验证：analyze 零问题、全量 **195 项通过**、macOS debug 构建成功；
默认 3D 配置 **72 次远距离传送通过**，随后原音频审计 **37/37 通过**，静音输出为 0。
后续两次重复传送因帧未推进判负，桥接仍正常应答；原生采样为正常事件等待而非音频锁等待。
所以原卡死触发路径已通过一轮完整验收，但持续前台稳定性仍未完成，不能混同为全部问题解决。
证据、探针源码、复现命令和通过／失败日志见 `docs/verification/audio-velocity/`。

主要证据在 `docs/verification/audio-lifecycle/`（静音前后对比、线程采样）；
完整本地过程在 `build/p0-e2e/`（含失败与修复后审计日志、两轮天气截图）。
本轮未创建提交，也没有修改原有未提交记忆文档。

## 执行队列

1. **P0：版本固化** —— 主要功能已按主题提交；依赖实验已回退且测试、macOS 构建通过。待整理剩余记忆／进度文档改动并完成固化版本验证。
2. **P0：端到端复验** —— 环境音孤立声部、传送伪速度导致的混音停滞均已修复；最新默认 3D 传送 72 次、音频 37/37 通过。玩法／天气最近通过在运动采样修复前；修复后重复传送被窗口停帧中断，持续前台验收待完成。
3. **P1：性能基线**（进行中）—— 断连修复已实机复验；前台冻结问题仍在，阻碍连续采样。待完成：后台停帧根因定位，或由用户终端持有会话后采集稳态 profile；以及纯 App 启动、首次真实输入测量。
4. **P1：核心玩法切片**（未开始）—— 基线稳定后选"漂浮＋平台挑战"或"吞吸＋一种敌人"。
5. **P1：基础使用体验**（待规划）—— 暂停、音量／静音、画质与操作引导。
6. **P2：关卡与发布**（待规划）—— 挑战、检查点、昼夜×降水组合、Web/macOS 分发。
