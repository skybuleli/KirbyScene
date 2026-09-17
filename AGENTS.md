# AGENTS.md

本文件面向在本仓库工作的 AI 助手（AGENTS）。

## 语言

- **必须使用中文进行推理与交流。** 思考过程（reasoning / thinking）、对用户的回复、
  代码注释与文档，一律使用中文。不要用英文思考或回复，除非用户明确要求。
- 代码标识符（类名、函数名、变量名）沿用仓库既有英文风格，不因本要求而改动。

## 项目速览

- `~/KirbyScene`：Flutter + `flutter_scene` 0.23.0 的类星之卡比 3D 游戏；
  全程序化生成、零美术资产，走 `imperative + Game 类` 模式。
- 目录：`lib/game/`（噪声/地形/河/水/草/植被/天空/角色/输入/控制器/外观/世界）、
  `lib/ui/`、`lib/mcp/`、`test/`。
- 更长的事实与踩坑记录在 `.workbuddy/memory/MEMORY.md`，动手前先读它。

## 工具链

- Flutter SDK 不在 PATH，用绝对路径：`/Users/liliang/flutter/bin/flutter`、
  `/Users/liliang/flutter/bin/dart`。
- 跑测试前必须先清代理（否则 `flutter_tester` 报 WebSocket 错误）：
  ```bash
  env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy NO_PROXY=localhost,127.0.0.1 \
    /Users/liliang/flutter/bin/flutter test
  ```

## 调试（主要手段：macOS 端 Hot reload）

**改代码后的默认调试回路是 macOS 端的 Hot reload**，而不是重新构建 Web。
流程：

1. 把 App 跑起来。**实测：助手自己也能拉起，不必干等用户**：
   ```bash
   nohup env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
     bash tool/dev.sh --macos --no-watch > build/agent_dev.log 2>&1 &
   ```
   * 工具在命令结束时可能回收进程组，`dev.sh` 包装进程会消失
     （`build/dev_run.pid` 可能没生成），但 **`flutter run` 与 App 会存活**：
     用 `pgrep -fl flutter_tools.snapshot run` 拿 pid，或直接用
     `tool/verify_weather.mjs`（它自带 pid 兜底）。
   * 用户在**自己的终端**前台跑 `tool/dev.sh --macos` 也可以，
     且只有那种情况下 `tool/dev.sh stop/reload/restart` 子命令才可用。
   * 拉起后先 `nc -z 127.0.0.1 7008` 或 `node tool/inproc_eval.mjs '{"op":"ping"}'`
     确认就绪（首次启动含构建，可能等 1–2 分钟）。
2. 找到进程并热重载 / 热重启：
   ```bash
   pgrep -fl flutter            # 拿到 flutter run 的 pid（ps 在沙箱里被拦）
   kill -USR1 <pid>             # 热重载（保留状态）
   kill -USR2 <pid>             # 热重启（重跑 main）
   ```
3. 远程读状态 / 下命令 / 截图（App 内回环端口 7008）：
   ```bash
   node tool/inproc_eval.mjs '{"op":"state"}'
   node tool/inproc_eval.mjs '{"op":"cmd","command":{"cmd":"set_weather","kind":"rain"}}'
   node tool/inproc_eval.mjs '{"op":"screenshot"}' --out shot.png
   ```
   （协议：换行分隔 JSON，op = `state` / `cmd` / `screenshot` / `ping`。）
4. 一键复验（推荐）：`tool/verify_weather.mjs` —— 自动热重启/热重载、
   逐天气切档并截图到 `build/reverify/`，并以 `state.ready` + `frame` 前进作为判据。
   ```bash
   node tool/verify_weather.mjs                          # 默认 night,rain
   node tool/verify_weather.mjs --weathers night,rain,clear
   node tool/verify_weather.mjs --reload                 # 仅改 Dart 逻辑时
   node tool/verify_weather.mjs --no-restart             # 只切档截图
   ```
5. **天空/天气类的客观验收：`tool/sky_audit.mjs`** —— 合了像素统计、云结构度量、
   ASCII 目视，并自带**帧前进判据**（截图前后各读一次 `state.frame`，不前进就先
   拉前台重试）。因为"天空好不好看"没法用眼睛验，只能靠这些量：
   ```bash
   # 逐档截图 + 度量（需要 App 在跑）；--camera 归位才能跨版本比
   node tool/sky_audit.mjs --weathers clear,cloudy,rain,night --camera 0,0.0987 --fps
   # 只分析已有截图，不需要 App
   node tool/sky_audit.mjs build/reverify/*.png --ascii --hp
   ```
   四条解读铁律（都踩过坑）：
   * **必须带 `--camera` 归位**：云在 8~46° 仰角上，俯角/方位一变天空带里的东西
     就整个换掉（同一版代码：默认机位 cloudy σ18.1 / 亮云 2.18%，yaw 归零后
     只剩 σ7.7 / 0.00%）；不归位的话两次测的数根本不可比。
   * **云不一定比天空亮**：晴天白云的实例色亮度≈1.0，而晴天天空本就接近饱和白 ——
     云会"隐入天空"。所以要看"亮云 / 暗云 / 总对比"三个值（阴天、雨天主要靠暗云）。
   * **不带 `--hp` 的 ASCII 看不出云**：天空是上暗下亮强渐变，会把字符表吃满（近地平线
     那几行永远是 `@`）；`--hp` 减掉逐行中位数才能看出云形。
   * **亮度不能只取 R 通道**：夜空是饱和蓝（R≈0，B≈30），只取 R 会把"深蓝夜空"
     量成"纯黑"（工具里已统一算 0.299R+0.587G+0.114B）。
6. **水流音效的客观验收：`tool/audio_audit.mjs`** —— 声音听不到，所以判据全部落在
   **引擎自己报出来的量**上，一条命令给出 20 项通过/失败：
   ```bash
   node tool/audio_audit.mjs --verbose      # 需要 App 在跑；脚本自己发 arm_audio 解锁
   ```
   * **音频是用户手势之后才起播的**（Web autoplay policy，原生端同路径）。
     所以自动化必须先发 `{"op":"cmd","command":{"cmd":"arm_audio"}}` —— 不发的话
     `engine=false playing=false` 会被误读成"功能没做"。
   * `outputLeft/Right` 是**混音后**的实测电平（
     `getApproximateVolume` 读 `mVisualizationChannelVolume`，**必须先
     `setVisualizationEnabled(true)`**，否则恒为 0 —— 已实测踩过）。空间衰减只能看它；
     而 `bandVolume` 是下发**前**的档位音量，不含 3D 衰减，拿它判衰减会得出"没衰减"。
   * `flowPositionMs` 每 0.5s 才刷新一次（`_probeInterval`），250ms 采样必然出现
     "0, 500, 0, 500"的锯齿 —— **别把它当断点判据**；判据是
     `Δ流位置 / Δ墙钟 ≈ 窗内 mean(playbackRate)`（位置是按 playbackRate 走的，不等于 1.0）。
   * 河道是弯的：**不能假设沿 x 就是沿距离**（实测 z=0 那条横线上 x=10 离中心线 21.5m，
     x=24 只有 9.7m），判空间衰减要按引擎报出的 `sourceDistance` 排序。

要点与判据：

- **判据是帧计数前进**（`state` 里的 `frame`），不是"信号发出去了"。
- 窗口不在前台时帧循环会冻结，`open -a <path>/kirby_scene.app` 拉前台即恢复。
- **热重载不重建已有对象**：改到 `initialize()` 里的几何/节点组装（如 `sky.build()`、
  `Scene` 里新增节点）必须热重启（SIGUSR2），单纯 SIGUSR1 看不到效果。
- `tool/vm_reload.mjs`（VM Service 直连）不可用：增量编译由 flutter 工具持有。
- 备用路径（无 macOS 会话时）：Web 预览 + CDP。
  * 构建：`flutter build web --no-tree-shake-icons`（本环境可直接跑）。
  * 自动截图：`tool/web.sh --shot out.png --no-build [--weather rain]`。
  * 运行时验证（本环境实测可用）：`python3 -m http.server 8123 --directory build/web`
    起服务，再用无头 Chrome 加 `--headless=new --no-sandbox --disable-gpu-sandbox
    --no-proxy-server --enable-unsafe-swiftshader --remote-debugging-port=9444` 启动，
    然后用 `tool/cdp_eval.mjs`（需 `KIRBY_CDP_PORT=9444`）读 `window.kirbyMcp.state`、
    用 `tool/cdp_shot.mjs` 截图。**运行验证看 `frame` 是否持续增长 + `ready:true`**。
  * ⚠️ 无头 Chrome 的 `--user-data-dir` **必须放项目外**（如 `$(mktemp -d)`）。
  * 无头 swiftshader 下帧率很低（约 4 FPS），天气过渡（1.7s）需等十几秒才会完成。

## 约定

- **不要删掉 `assets/`（哪怕它是空的，`.gitkeep` 就是为了保它）。** 这是 macOS 构建能否
  成功的**硬前提**，不是可选的资源目录：
  * flutter_scene 的 hook 把 `assets/` 声明为构建依赖目录（`discoveryDependencyDirectory`），
    目录不存在时会**回退到最近的已存在祖先 —— 也就是项目根**。
  * 依赖目录变成项目根之后，`hooks_runner` 会**递归整棵树**算依赖哈希
    （`src/utils/file.dart` 的 `Directory.lastModified` 用默认 `list()`），
    而它的 `TracingDirectory.wrapLink` 遇到**悬空符号链接**直接 `throw UnimplementedError`
    （`tracing_file_system.dart:115`）。
  * 症状极具误导性：`Oops; flutter has exited unexpectedly: "UnimplementedError"` +
    `PhaseScriptExecution failed with a nonzero exit code` + `Failed to package` +
    `** BUILD FAILED **` —— 看着像 Xcode / 环境 / 沙箱坏了，其实三行都不相干。
  * 实测的**死锁**形态（flutter_soloud 首次接入 SwiftPM 时）：Xcode 在
    `build/macos/Build/Products/Debug/PackageFrameworks/flutter-soloud.framework` 留下一个
    **二进制还没链接上的空框架**（`flutter-soloud -> Versions/Current/flutter-soloud` 悬空），
    于是每次构建都崩；而构建一崩，SPM 那边就永远没机会把它链接完整 —— 删那个框架也没用，
    下次构建会再生成一份半成品。补上 `assets/` 后立刻恢复正常（同一次构建里框架也链接好了）。
  * 排查：
    ```bash
    # 哪些目录里含符号链接（含悬空的）
    find . -type l -not -path './.git/*'
    # 只看悬空的（真正会炸构建的那种）
    for l in $(find . -type l -not -path './.git/*'); do [ -e "$l" ] || echo "DANGLING: $l"; done
    ```
    修复就是**恢复 `assets/` 目录**（把依赖收窄回去），而不是去删 `build/` 里的东西。
  * 另一次踩坑（同一个根因、不同表现）：无头 Chrome 的 `--user-data-dir` 放在 `build/`
    下会创建 `SingletonLock` 等悬空 symlink，同样炸构建。
- 不要用 `FastNoiseLite`；用 `lib/game/noise.dart` 的自研确定性噪声（dart2js 下整数溢出会静默算错）。
- `vector_math` 的类型不是 const 构造。
- 隐藏节点用零缩放，不要用零矩阵。
- 写完代码要跑 `flutter analyze` 与相关测试验证。
