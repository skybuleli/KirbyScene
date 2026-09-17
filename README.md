# KirbyScene

Flutter + `flutter_scene 0.23.0` 的类星之卡比 3D 游戏原型。场景、角色与音效全部程序化生成，不依赖外部美术或音频资产。

**当前阶段：可玩的收集关卡 + 环境生态原型，不是完整的类卡比游戏。**

## 已实现

- 第三人称移动、奔跑、跳跃、相机旋转与缩放；收集 12 颗星核、通关提示、重玩。
- 确定性噪声地形、河谷雕刻、预算 11 万草叶、花、灌木、树、芦苇和石块。
- 晴／阴／雨／夜四档天气、渐变天空盒、动态云、星月、雨幕、水花、积水和谷雾。
- 共享流场驱动的水面波动、水草摇摆、鱼虾活动。
- SoLoud 音频：河／雨／风／夜环境层、跳跃／落地／拾取／通关等事件音；程序化烘焙、混音与诊断。
- Web CDP 与 macOS 回环 TCP 两条调试通道；状态、输入、截图及天气／音频验收脚本。

还未实现吞吸、漂浮、能力复制、敌人战斗及多关卡流程。优先级与验收结果见 [项目进度](docs/PROGRESS.md)。

## 快速开始

Flutter SDK 默认路径为 `/Users/liliang/flutter/bin/flutter`，开发脚本可用 `KIRBY_FLUTTER` 覆盖。

```bash
# 推荐的调试通道：macOS，保存 Dart 文件后自动热重载
bash tool/dev.sh --macos

# Web 开发预览
bash tool/dev.sh

# Web 静态构建、预览及截图
bash tool/web.sh --shot out.png
```

macOS 需要完整 Xcode，本机安装位置为 `/Applications/Xcode.app`。脚本会解析 `DEVELOPER_DIR`；插件走 Swift Package Manager，无需为本项目单独安装 CocoaPods。

**必须保留 `assets/.gitkeep`。** 即使没有资产，该目录也是 flutter_scene 构建 hook 的依赖边界；删除它可能让构建扫描整个项目，并因悬空符号链接失败。无头 Chrome 的用户数据目录必须放在项目外。

### 操作

| 输入 | 功能 |
|---|---|
| WASD / Shift | 移动 / 奔跑 |
| 空格 | 跳跃 |
| 按住鼠标拖拽 / 滚轮 | 转视角 / 缩放 |
| 1 / 2 / 3 / 4 | 晴 / 阴 / 雨 / 夜 |
| T / R | 循环天气 / 重玩 |

Web 音频需要浏览器允许用户手势起播；首次按键或点击会尝试解锁。

### 热重载与热重启

```bash
bash tool/dev.sh reload
bash tool/dev.sh restart
bash tool/dev.sh status
bash tool/dev.sh stop
```

子命令适用于脚本持有的会话。若由其他终端持有 `flutter run`，可用 `pgrep -fl flutter_tools.snapshot` 查找对应进程，然后对该进程发 `SIGUSR1`（热重载）或 `SIGUSR2`（热重启）。

**改 `initialize()` 内的几何或节点组装必须热重启**，热重载不会重建已有对象。

## 验证

测试前清代理，避免 Flutter 测试进程的回环 WebSocket 被代理干扰：

```bash
env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
  NO_PROXY=localhost,127.0.0.1 /Users/liliang/flutter/bin/flutter analyze

env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
  NO_PROXY=localhost,127.0.0.1 /Users/liliang/flutter/bin/flutter test
```

macOS App 已运行时：

```bash
node tool/inproc_eval.mjs '{"op":"state"}'
node tool/verify_weather.mjs --weathers clear,cloudy,rain,night --no-restart
node tool/sky_audit.mjs --weathers clear,cloudy,rain,night --camera 0,0.0987 --fps
node tool/audio_audit.mjs --verbose
```

- 就绪判据是 `ready=true` 且 `frame` 持续前进，不是仅有端口响应。
- macOS 窗口在后台时可能停帧，需要将 App 拉到前台再测。
- 天空对比必须固定机位；音频检查必须区分目标音量、实际下发量和混音后输出。
- 单测通过不代表 GPU 渲染或音频设备通过，运行验收需单独执行。

## 架构

```text
lib/
  game/
    noise.dart / terrain.dart          确定性噪声与高度场
    river.dart / flow.dart             河道与共享流场
    water_waves.dart / water.dart      波场与水面渲染
    grass.dart / flora.dart            草地与分层植被
    aquatic_flora.dart                 水草
    aquatic_fauna.dart                 鱼虾行为与渲染
    sky.dart / look.dart               天气、天空与外观
    kirby.dart / player_controller.dart 角色与控制器
    input.dart / world.dart            输入与世界编排
  audio/                              音频门面、引擎、混音、合成与烘焙
  mcp/                                Web 桥接与原生回环宿主
  ui/hud.dart                         收集、天气与通关提示
```

纯数学模块可直接单测；渲染模块依赖 GPU，不能把整个 `lib/game/` 当成纯逻辑。

### MCP

`tool/kirby_mcp.dart` 是纯 `dart:io` 的 stdio MCP 服务器，由 `.mcp.json` 注册。两条通道共用工具层：

```text
Web：  MCP → CDP → window.kirbyMcp → KirbyWorld
macOS：MCP → TCP 127.0.0.1:7008 → KirbyWorld
```

工具包括构建、启动／接管、热重载、控制台、截图、状态、等帧、天气、重玩、相机、传送与按键。

注意区分：`tool/dev.sh` 的 Web 开发会话支持热重载；MCP 的 Web `hot_reload` 路径是重编译与刷新。macOS MCP 路径通过信号执行原生热重载／热重启。

## 已知边界

- Web 渲染后端是实验性的，与 macOS 的完整后处理效果不等价。
- 草地与植被在固定范围生成，尚无按玩家位置分块流式加载。
- 昼夜和降水共用一个天气枚举，不支持夜雨组合。
- 当前玩法是收集原型，环境系统的完成度领先于关卡和战斗系统。
- 启动与帧率必须按构建模式和设备测量；历史 debug 数据不能当作 release 性能承诺。

详细开发约束见 [AGENTS.md](AGENTS.md)。历史踩坑见 `.workbuddy/memory/MEMORY.md`，存在已明确订正的旧结论，请以当前源码、后续订正和最新实测为准。
