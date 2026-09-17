/// KirbyScene 入口。
///
/// 只做三件事：起 [KirbyWorld]、把 Flutter 的输入事件转进去、把 3D 视口和 HUD 叠起来。
/// 所有游戏逻辑都在 `lib/game/` 里，这里刻意保持薄。

library;
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_scene/scene.dart';

import 'game/sky.dart';
import 'game/world.dart';
import 'mcp/bridge.dart';
import 'mcp/inproc_host.dart';
import 'ui/hud.dart';

void main() {
  runApp(const KirbyApp());
}

class KirbyApp extends StatelessWidget {
  const KirbyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KirbyScene',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0E0A14),
        fontFamilyFallback: const ['PingFang SC', 'Heiti SC', 'Microsoft YaHei'],
      ),
      home: const GamePage(),
    );
  }
}

class GamePage extends StatefulWidget {
  const GamePage({super.key});

  @override
  State<GamePage> createState() => _GamePageState();
}

class _GamePageState extends State<GamePage> {
  final KirbyWorld world = KirbyWorld();
  final FocusNode _keyboardFocus = FocusNode();

  /// 包住 3D 视口的边界，供原生通道抓图（macOS 的 `screenshot` op）。
  final GlobalKey _viewportKey = GlobalKey();

  /// 原生通道的进程内桥接宿主。Web 下是空实现（改走 window.kirbyMcp）。
  late final InprocMcpHost _mcpHost = InprocMcpHost(
    world,
    screenshotProvider: _captureViewport,
  );

  /// HUD 的刷新节流：世界状态每帧都在变，但没必要每帧重建 widget。
  final ValueNotifier<int> _hudTick = ValueNotifier<int>(0);
  double _hudAccumulator = 0;

  String? _initError;

  /// 自动演示模式（URL 加 `?demo=1`）。
  ///
  /// 用途是**验证循环**：无头环境（以及远程/CI）没法真的按键，
  /// 但可以通过虚拟输入走同一条游戏逻辑路径，确认角色能跑、能跳、能吃到星核。
  /// 实际驾驶逻辑在 `KirbyWorld._driveDemo`，这里只负责开关——
  /// 这样 MCP 也能用 `set_demo` 命令远程控制同一套逻辑。
  bool _demoMode = false;

  @override
  void initState() {
    super.initState();
    _demoMode = Uri.base.queryParameters['demo'] == '1';
    unawaited(_boot());
  }

  Future<void> _boot() async {
    try {
      await world.initialize();

      world.demoDriving = _demoMode;

      // 允许用 URL 直接指定天气，便于自动化截图与远程演示：?weather=rain
      final requested = Uri.base.queryParameters['weather'];
      if (requested != null) {
        for (final kind in WeatherKind.values) {
          if (kind.name == requested) world.setWeather(kind);
        }
      }

      // 音频：在**没有用户手势**的情况下先把设备备好。
      //
      // 原生端允许（没有 autoplay policy），于是"打开音频设备"这件事被移到
      // 地图还在渲染的时候，**第一次按键不必再等它** —— 上一版把 init + 装载
      // 全挂在第一次按键上，实测那一下要停顿主线程约 1.2 秒，玩家感受到的
      // 就是"按了键没反应"。Web 上这一步会被浏览器拒绝，那就安静地留到
      // 第一次手势（`notifyUserGesture`）再来一次；两端走同一条路径。
      unawaited(world.audio.preArm());

      // 挂出 `window.kirbyMcp`，供宿主进程经 Chrome DevTools Protocol 读写。
      // Web 通道下这是唯一的接入点（浏览器里没有 dart:io，开不了端口）。
      // 必须在 initialize 之后：状态快照要读 player / controller 这两个 late 字段。
      GameBridge.attach(world);

      // 原生通道（macOS）的接入点：开一个回环端口，让宿主侧的 kirby_mcp 连进来。
      // Web 下这是空实现——那边靠上面那句 attach。
      final listening = await _mcpHost.start();
      if (!listening) {
        // 端口被占用不影响游戏本身，只是 MCP 连不上，记一行便于排查。
        debugPrint(
          'KirbyScene：MCP 回环端口 $kKirbyInprocPort 未能监听（可能已被占用），游戏不受影响。',
        );
      }

      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() => _initError = e.toString());
    }
  }

  @override
  void dispose() {
    unawaited(_mcpHost.dispose());
    // 音频播放器持有平台资源，必须显式释放（world 本身没有 dispose ——
    // 它是随页面一起消失的，之前没有需要回收的东西）。
    if (world.isReady) unawaited(world.audio.dispose());
    _hudTick.dispose();
    _keyboardFocus.dispose();
    super.dispose();
  }

  /// 抓取 3D 视口为 PNG，供原生通道的 MCP `screenshot` 使用。
  ///
  /// 走 `RepaintBoundary.toImage`：拿到的是**渲染后的图层**，
  /// 所以 flutter_scene / Flutter GPU 画出来的内容也在里面。
  Future<Uint8List?> _captureViewport() async {
    final boundary = _viewportKey.currentContext?.findRenderObject()
        as RenderRepaintBoundary?;
    if (boundary == null) return null;
    try {
      final image = await boundary.toImage(pixelRatio: 2.0);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return data?.buffer.asUint8List();
    } catch (e) {
      debugPrint('KirbyScene：视口截图失败 $e');
      return null;
    }
  }

  void _onTick(Duration elapsed, double deltaSeconds) {
    // 把 dt 夹住：切标签页回来时 delta 会很大，直接喂给物理会让角色瞬移穿地。
    final dt = deltaSeconds.clamp(0.0, 0.05);

    // 自动演示的驾驶逻辑在世界内部（由 demoDriving 开关控制），这里不再插手。
    world.tick(elapsed, dt);

    _hudAccumulator += dt;
    // 演示模式下逐帧刷新：无头抓帧里帧数少，节流会让 HUD 停在初始值上，
    // 看起来像"逻辑没跑"，实际只是没重绘。
    if (_demoMode || _hudAccumulator >= 0.2) {
      _hudAccumulator = 0;
      _hudTick.value++;
    }
  }

  void _onKeyEvent(KeyEvent event) {
    world.input.handleKeyEvent(event);
    if (event is! KeyDownEvent) return;

    // 第一次按键就解锁音频（浏览器要求音频由用户手势触发）。
    world.notifyUserGesture();

    switch (event.logicalKey) {
      case LogicalKeyboardKey.digit1:
        world.setWeather(WeatherKind.clear);
      case LogicalKeyboardKey.digit2:
        world.setWeather(WeatherKind.cloudy);
      case LogicalKeyboardKey.digit3:
        world.setWeather(WeatherKind.rain);
      case LogicalKeyboardKey.digit4:
        world.setWeather(WeatherKind.night);
      case LogicalKeyboardKey.keyT:
        world.cycleWeather();
      case LogicalKeyboardKey.keyR:
        world.restart();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: KeyboardListener(
        focusNode: _keyboardFocus,
        autofocus: true,
        onKeyEvent: _onKeyEvent,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_initError != null) {
      return _centered(
        icon: Icons.error_outline,
        color: const Color(0xFFFF8A80),
        title: '场景初始化失败',
        detail: _initError!,
      );
    }
    if (!world.isReady) {
      return _centered(
        icon: Icons.auto_awesome,
        color: const Color(0xFFFF9EC4),
        title: '正在生成草原…',
        detail: '程序化地形 · 草地 · 天空盒',
      );
    }

    return Stack(
      children: [
        Positioned.fill(
          child: Listener(
            // 指针按下也算用户手势：有人习惯先点一下画面再操作。
            onPointerDown: (_) => world.notifyUserGesture(),
            // 按住左键拖拽转视角；滚轮缩放。
            onPointerMove: (event) {
              if (event.buttons != 0) {
                world.orbitCamera(event.delta.dx, event.delta.dy);
              }
            },
            onPointerSignal: (event) {
              if (event is PointerScrollEvent) {
                world.zoomCamera(event.scrollDelta.dy);
              }
            },
            child: RepaintBoundary(
              key: _viewportKey,
              child: SceneView(
                world.scene,
                cameraBuilder: (_) => world.buildCamera(),
                onTick: _onTick,
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: ValueListenableBuilder<int>(
              valueListenable: _hudTick,
              builder: (context, _, _) =>
                  GameHud(world: world, demoMode: _demoMode),
            ),
          ),
        ),
      ],
    );
  }

  Widget _centered({
    required IconData icon,
    required Color color,
    required String title,
    required String detail,
  }) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 40),
          const SizedBox(height: 14),
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54, fontSize: 12, height: 1.6),
          ),
        ],
      ),
    );
  }
}
