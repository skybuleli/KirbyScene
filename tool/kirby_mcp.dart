/// KirbyScene 的宿主侧 MCP 服务器 —— **零 package 依赖**，纯 `dart:io`。
///
/// ## 为什么是这个方向
///
/// Web 构建的浏览器里没有 `dart:io`，App 自己开不了监听端口
/// （CellScene 的 macOS 通道才能在 App 进程内监听 127.0.0.1）。
/// 所以反过来 —— 由宿主进程主动连上浏览器：
///
/// ```
/// MCP 客户端 ──stdio──▶ 本进程 ──CDP/WebSocket──▶ Chrome ──JS──▶ KirbyWorld
/// ```
///
/// ## 为什么工具名要和官方一致
///
/// 官方的编辑器 MCP（`flutter_scene_mcp`，提供 build_project / run_project /
/// hot_reload / get_console / screenshot_viewport）**不是 pub 包**，
/// 而是随 Flutter Scene Editor 桌面应用一起分发，且标注 "In active development"。
/// 也就是说即便补齐了 Xcode，要拿到"官方那套"还得再装一个编辑器。
/// 所以这里自建一套并**对齐官方工具名** —— 两条通道下都通用，
/// 将来真接上官方 MCP 时调用侧也不用改。
///
/// ## 用法
///
/// 由 `.mcp.json` 以 stdio 启动：
/// ```
/// /Users/liliang/flutter/bin/dart /Users/liliang/KirbyScene/tool/kirby_mcp.dart
/// ```
///
/// 环境变量：
///   - `KIRBY_PROJECT_DIR`  覆盖项目根目录（默认由脚本位置推导）
///   - `KIRBY_FLUTTER`       flutter 可执行文件路径
///   - `KIRBY_CHROME`        Chrome 可执行文件路径
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'src/cdp_session.dart';
import 'src/game_link.dart';
import 'src/native_session.dart';

// ---------------------------------------------------------------------------
// 协议常量
// ---------------------------------------------------------------------------

const String kServerName = 'kirby-mcp';
const String kServerVersion = '1.0.0';
const String kProtocolVersion = '2025-06-18';
const int kDefaultDebugPort = 9333;

// ---------------------------------------------------------------------------
// 工具定义
// ---------------------------------------------------------------------------

typedef ToolHandler = Future<Map<String, dynamic>> Function(
  Map<String, dynamic> args,
);

class ToolSpec {
  ToolSpec({
    required this.name,
    required this.description,
    required this.schema,
    required this.handler,
  });

  final String name;
  final String description;
  final Map<String, dynamic> schema;
  final ToolHandler handler;

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'inputSchema': schema,
      };
}

/// 构造一个 object 型 inputSchema。
///
/// 显式写出 `properties`（哪怕是空的）很重要：部分 MCP 客户端在没有
/// `properties` 字段时会拒绝这个工具。
Map<String, dynamic> _objectSchema(
  Map<String, dynamic> properties, [
  List<String> required = const [],
]) =>
    {
      'type': 'object',
      'properties': properties,
      if (required.isNotEmpty) 'required': required,
    };

Map<String, dynamic> _strProp(String description) => {
      'type': 'string',
      'description': description,
    };

Map<String, dynamic> _numProp(String description) => {
      'type': 'number',
      'description': description,
    };

Map<String, dynamic> _intProp(String description, {int? min, int? max}) => {
      'type': 'integer',
      'description': description,
      'minimum': ?min,
      'maximum': ?max,
    };

Map<String, dynamic> _boolProp(String description) => {
      'type': 'boolean',
      'description': description,
    };

Map<String, dynamic> _enumProp(String description, List<String> values) => {
      'type': 'string',
      'description': description,
      'enum': values,
    };

Map<String, dynamic> _textResult(String text, {bool isError = false}) => {
      'content': [
        {'type': 'text', 'text': text},
      ],
      if (isError) 'isError': true,
    };

// ---------------------------------------------------------------------------
// 路径与参数工具
// ---------------------------------------------------------------------------

String _resolveProjectRoot() {
  final fromEnv = Platform.environment['KIRBY_PROJECT_DIR'];
  if (fromEnv != null && fromEnv.isNotEmpty) {
    return Directory(fromEnv).absolute.path;
  }
  // 本文件位于 <root>/tool/kirby_mcp.dart
  final script = Platform.script;
  if (script.scheme == 'file') {
    final dir = File.fromUri(script).parent.parent;
    if (File('${dir.path}/pubspec.yaml').existsSync()) return dir.path;
  }
  return Directory.current.absolute.path;
}

String _resolveFlutter() {
  final fromEnv = Platform.environment['KIRBY_FLUTTER'];
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
  const candidates = [
    '/Users/liliang/flutter/bin/flutter',
    '/opt/homebrew/bin/flutter',
    '/usr/local/bin/flutter',
  ];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) return candidate;
  }
  return 'flutter';
}

int _intArg(Map<String, dynamic> args, String key, int fallback) {
  final value = args[key];
  return value is num ? value.toInt() : fallback;
}

bool _boolArg(Map<String, dynamic> args, String key, bool fallback) {
  final value = args[key];
  return value is bool ? value : fallback;
}

String? _strArg(Map<String, dynamic> args, String key) {
  final value = args[key];
  if (value is! String || value.isEmpty) return null;
  return value;
}

List<String> _strListArg(Map<String, dynamic> args, String key) {
  final value = args[key];
  if (value is! List) return const [];
  return value.whereType<String>().toList();
}

/// 人类可读的状态摘要，多个工具共用。
String _describeState(Map<String, dynamic>? state) {
  if (state == null) return '（读不到状态：桥接未挂出）';
  if (state['ready'] != true) return '（场景尚未就绪）';

  final position = state['position'];
  final x = position is List && position.length >= 3
      ? '${(position[0] as num).toStringAsFixed(1)}, '
          '${(position[2] as num).toStringAsFixed(1)}'
      : '?';
  return '分数 ${state['score']}/${state['pickupsTotal']}'
      '｜天气 ${state['weatherLabel']}'
      '｜位置 ($x)'
      '｜${state['airborne'] == true ? '腾空中' : '已落地'}'
      '｜游戏内 ${(state['elapsed'] as num?)?.toStringAsFixed(1) ?? '?'}s'
      '｜帧 ${state['frame']}'
      '${state['demo'] == true ? '｜自动演示中' : ''}';
}

// ---------------------------------------------------------------------------
// 服务器
// ---------------------------------------------------------------------------

class KirbyMcpServer {
  KirbyMcpServer()
      : projectRoot = _resolveProjectRoot(),
        flutterBinary = _resolveFlutter();

  final String projectRoot;
  final String flutterBinary;

  /// Web 通道：CDP 驱动浏览器里的页面。
  final BrowserSession _session = BrowserSession();

  /// macOS 通道：连 App 进程内的回环端口，并代管 `flutter run -d macos`。
  final NativeSession _native = NativeSession();

  /// 当前活跃通道。
  ///
  /// 工具层只认 [GameLink]——换通道只是换实现，13 个工具的定义与分发不变。
  GameLink get _link {
    if (_native.isConnected) return _native.link;
    if (_session.hasClient) return _session.link;
    throw StateError('尚未连接游戏。先调用 run_project（device 默认 web，macOS 传 "macos"）。');
  }

  String get _webDir => '$projectRoot/build/web';
  String get _screenshotDir => '$projectRoot/docs/screenshots';

  // ------------------------------------------------------------------
  // 工具注册表
  // ------------------------------------------------------------------

  late final List<ToolSpec> tools = [
    ToolSpec(
      name: 'build_project',
      description:
          '编译 Web 构建（相当于 flutter build web --no-tree-shake-icons）。'
          '这就是「用 MCP 调用引擎自带编译器」的入口：会触发 flutter_scene 的'
          '资产与着色器管线（hook/build.dart）。',
      schema: _objectSchema({
        'timeout_seconds': _intProp('编译超时（秒），默认 600', min: 30, max: 3600),
      }),
      handler: _buildProject,
    ),
    ToolSpec(
      name: 'run_project',
      description:
          '启动游戏并接上桥接，等就绪后推进若干帧。'
          'device="web"（默认）会拉起浏览器、伺服 build/web 并导航；'
          'device="macos" 会拉起（或接管）flutter run -d macos 并连 App 内的回环端口。'
          '两条通道幂等：重复调用只会重新接一次。',
      schema: _objectSchema({
        'device': _enumProp(
          '目标通道。web = 浏览器（无需 Xcode）；macos = 桌面原生（需完整 Xcode，'
          '但拿得到 SSAO/泛光/景深与真热重载）',
          ['web', 'macos'],
        ),
        'debug_port': _intProp('Web 通道的 Chrome 调试端口，默认 $kDefaultDebugPort', min: 1024, max: 65535),
        'attach_only': _boolProp(
          '只接管已经在跑的实例，不自己拉起。'
          'Web：接管 flutter run -d chrome 的调试会话；'
          'macOS：接管已在运行的 App（默认 true，避免撞构建目录）。',
        ),
        'headless': _boolProp(
          'Web 通道专用：是否无头运行。默认 false —— 无头下 rAF 节流严重，'
          '虽然本服务器会用显式推帧兜底，但有头更接近真实观感。',
        ),
        'query': _strProp('Web 通道专用：附加查询串，例如 demo=1&weather=rain'),
        'frames': _intProp('就绪后推进的帧数，默认 60（≈1 秒游戏时间）', min: 0, max: 6000),
      }),
      handler: _runProject,
    ),
    ToolSpec(
      name: 'hot_reload',
      description:
          '热重载。**两条通道行为不同**：macOS 通道是真热重载——给 flutter run 发 '
          'SIGUSR1，不重编译、状态保留（restart:true 则发 SIGUSR2 做热重启）；'
          'Web 通道没有真热重载，等价于「重编译 + Page.reload + 重新等桥接」。',
      schema: _objectSchema({
        'restart': _boolProp(
          '仅 macOS 通道：改为热重启（SIGUSR2，重置状态并重跑 main）。'
          '改动涉及 initialize() 里的几何/节点组装时用这个。',
        ),
        'timeout_seconds': _intProp('Web 通道的编译超时（秒），默认 600', min: 30, max: 3600),
        'frames': _intProp('之后推进的帧数，默认 60', min: 0, max: 6000),
      }),
      handler: _hotReload,
    ),
    ToolSpec(
      name: 'get_console',
      description: '读取页面控制台与未捕获异常（缓冲最近 500 条）。排查渲染失败必用。',
      schema: _objectSchema({
        'limit': _intProp('返回最近多少条，默认 50', min: 1, max: 500),
        'clear': _boolProp('读取后是否清空缓冲，默认 false'),
        'level': _strProp('按级别过滤，例如 error / warning / log / exception'),
      }),
      handler: _getConsole,
    ),
    ToolSpec(
      name: 'screenshot_viewport',
      description: '抓取当前视口为 PNG 并落盘，同时内联返回图片。',
      schema: _objectSchema({
        'path': _strProp('输出路径（相对项目根或绝对路径）。默认写入 docs/screenshots/'),
        'frames': _intProp('抓图前先推进的帧数，默认 2', min: 0, max: 6000),
        'inline': _boolProp('是否把图片内联进返回内容，默认 true'),
      }),
      handler: _screenshotViewport,
    ),
    ToolSpec(
      name: 'get_game_state',
      description: '读取游戏运行态：分数、位置、天气、是否腾空、相机参数、累计时间与帧数。',
      schema: _objectSchema({
        'frames': _intProp('读取前先推进的帧数，默认 0', min: 0, max: 6000),
      }),
      handler: _getGameState,
    ),
    ToolSpec(
      name: 'wait_frames',
      description:
          '显式推进 N 帧。用于时序敏感的验证：无头/被遮挡窗口里 rAF 可能不跑，'
          '「调了没反应」多半是帧没推进，而不是逻辑没执行。',
      schema: _objectSchema({
        'frames': _intProp('推进的帧数', min: 1, max: 6000),
      }, ['frames']),
      handler: _waitFrames,
    ),
    ToolSpec(
      name: 'set_weather',
      description: '切换天气（晴天 / 阴天 / 雨天），会实时改变天空、光照、雾与雨幕。',
      schema: _objectSchema({
        'kind': _enumProp('天气类型', ['clear', 'cloudy', 'rain']),
        'frames': _intProp('切换后推进的帧数，默认 60（走完天气过渡）', min: 0, max: 6000),
      }, ['kind']),
      handler: _setWeather,
    ),
    ToolSpec(
      name: 'restart_level',
      description: '重开本关：清空收集进度并把角色放回场地中心。',
      schema: _objectSchema({
        'frames': _intProp('重开后推进的帧数，默认 30', min: 0, max: 6000),
      }),
      handler: _restartLevel,
    ),
    ToolSpec(
      name: 'set_camera',
      description: '直接设置第三人称相机参数（偏航 / 俯仰 / 距离）。',
      schema: _objectSchema({
        'yaw': _numProp('偏航角（弧度）'),
        'pitch': _numProp('俯仰角（弧度），会被夹到 -0.15 ~ 1.25'),
        'distance': _numProp('相机距离，会被夹到 4 ~ 22'),
        'frames': _intProp('设置后推进的帧数，默认 30', min: 0, max: 6000),
      }),
      handler: _setCamera,
    ),
    ToolSpec(
      name: 'teleport_player',
      description: '把角色瞬移到指定平面坐标（自动贴合地形高度），相机同步跟过去。',
      schema: _objectSchema({
        'x': _numProp('世界坐标 x'),
        'z': _numProp('世界坐标 z'),
        'frames': _intProp('瞬移后推进的帧数，默认 30', min: 0, max: 6000),
      }, ['x', 'z']),
      handler: _teleportPlayer,
    ),
    ToolSpec(
      name: 'press_keys',
      description:
          '注入虚拟按键（与真实键盘走同一条游戏逻辑路径）。'
          '可按住方向键让角色移动、触发跳跃。'
          '注意：这是持续状态，用完记得 release。',
      schema: _objectSchema({
        'hold': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': '要按住的键，例如 ["KeyW","ShiftLeft"]。'
              '可用键：KeyW/KeyA/KeyS/KeyD、Arrow*、ShiftLeft、Space',
        },
        'release': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': '要松开的键',
        },
        'release_all': _boolProp('是否松开全部虚拟键'),
        'jump': _boolProp('是否注入一次跳跃'),
        'frames': _intProp('按键后推进的帧数（按住方向键时用来产生位移），默认 0', min: 0, max: 6000),
      }),
      handler: _pressKeys,
    ),
    ToolSpec(
      name: 'describe_project',
      description: '报告项目位置、工具链、Web 构建状态、浏览器会话状态与工具清单。',
      schema: _objectSchema({}),
      handler: _describeProject,
    ),
  ];

  // ------------------------------------------------------------------
  // 工具实现
  // ------------------------------------------------------------------

  Future<Map<String, dynamic>> _buildProject(Map<String, dynamic> args) async {
    final timeout = Duration(seconds: _intArg(args, 'timeout_seconds', 600));
    final stopwatch = Stopwatch()..start();

    final result = await _runFlutter(
      const ['build', 'web', '--no-tree-shake-icons'],
      timeout: timeout,
    );
    stopwatch.stop();

    final ok = result.exitCode == 0;
    final output = '${result.stdout}\n${result.stderr}';
    final tail = _tailLines(output, ok ? 12 : 40);

    final buffer = StringBuffer()
      ..writeln(ok ? '✅ 构建成功' : '❌ 构建失败（exit ${result.exitCode}）')
      ..writeln('耗时 ${(stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1)}s')
      ..writeln('产物目录：$_webDir');

    final indexFile = File('$_webDir/index.html');
    if (indexFile.existsSync()) {
      final stat = indexFile.statSync();
      buffer.writeln(
        'index.html 时间戳：${stat.modified.toIso8601String()}'
        '（${stat.size} 字节）',
      );
    }
    buffer
      ..writeln()
      ..writeln(tail.isEmpty ? '（无输出）' : tail);

    return _textResult(buffer.toString(), isError: !ok);
  }

  Future<Map<String, dynamic>> _runProject(Map<String, dynamic> args) async {
    final device = (_strArg(args, 'device') ?? 'web').toLowerCase();
    if (device == 'macos' || device == 'native') return _runMacos(args);
    return _runWeb(args);
  }

  Future<Map<String, dynamic>> _runWeb(Map<String, dynamic> args) async {
    final port = _intArg(args, 'debug_port', kDefaultDebugPort);
    final headless = _boolArg(args, 'headless', false);
    final attachOnly = _boolArg(args, 'attach_only', false);
    final query = _strArg(args, 'query') ?? '';
    // 接管模式不导航、不等初始化，所以不必默认推帧（推了也无害）。
    final frames = _intArg(args, 'frames', attachOnly ? 0 : 60);

    final url = await _session.ensureRunning(
      projectRoot: projectRoot,
      debugPort: port,
      headless: headless,
      query: query.isEmpty ? '' : '?$query',
      attachOnly: attachOnly,
    );

    if (frames > 0) await _link.pumpFrames(frames);
    final state = await _link.readState();

    final mode = attachOnly
        ? '接管已有浏览器（flutter run 热重载会话）'
        : headless
            ? '无头'
            : '有头';
    return _textResult(
      '✅ 已运行（Web 通道）\n'
      '地址：$url\n'
      '浏览器：$mode，调试端口 ${_session.debugPort}'
      '${attachOnly || !_session.launchedByUs ? '' : '（本服务器拉起）'}\n'
      '状态：${_describeState(state)}',
    );
  }

  /// macOS 通道：拉起（或接管）`flutter run -d macos`，连 App 内的回环端口。
  Future<Map<String, dynamic>> _runMacos(Map<String, dynamic> args) async {
    final reuse = _boolArg(args, 'attach_only', true);
    final frames = _intArg(args, 'frames', 60);

    final endpoint = await _native.ensureRunning(
      projectRoot: projectRoot,
      flutterBinary: flutterBinary,
      extraEnv: _macosEnv(),
      reuse: reuse,
    );

    if (frames > 0) await _link.pumpFrames(frames);
    final state = await _link.readState();

    return _textResult(
      '✅ 已运行（macOS 通道）\n'
      '端点：$endpoint\n'
      'App 进程：${_native.appPid ?? '已存在（接管，不用我拉起）'}\n'
      '状态：${_describeState(state)}',
    );
  }

  /// 当前活跃通道的描述（`describe_project` 与错误消息共用）。
  String _activeTransportLabel() {
    if (_native.isConnected) return _native.link.describe();
    if (_session.hasClient) return _session.link.describe();
    return '无（尚未连接游戏）';
  }

  /// macOS 构建需要完整 Xcode。本机的 Xcode 可能不在标准位置
  /// （`~/Downloads/Xcode.app` 这种），所以主动解析并放进 `DEVELOPER_DIR` ——
  /// 否则 `flutter run -d macos` 会直接报 "Xcode not installed"。
  Map<String, String> _macosEnv() {
    final env = <String, String>{};

    final existing = Platform.environment['DEVELOPER_DIR'];
    if (existing != null && existing.isNotEmpty) {
      env['DEVELOPER_DIR'] = existing;
      return env;
    }

    final home = Platform.environment['HOME'] ?? '';
    final candidates = <String>[
      '/Applications/Xcode.app',
      if (home.isNotEmpty) '$home/Applications/Xcode.app',
      if (home.isNotEmpty) '$home/Downloads/Xcode.app',
    ];
    for (final app in candidates) {
      final developer = '$app/Contents/Developer';
      if (File('$developer/usr/bin/xcodebuild').existsSync()) {
        env['DEVELOPER_DIR'] = developer;
        return env;
      }
    }
    return env;
  }

  Future<Map<String, dynamic>> _hotReload(Map<String, dynamic> args) async {
    // macOS 通道是**真热重载**：给 flutter run 发信号即可，不用重编译。
    if (_native.isConnected) {
      final restart = _boolArg(args, 'restart', false);
      final ok = restart
          ? await _native.app.hotRestart()
          : await _native.app.hotReload();

      final frames = _intArg(args, 'frames', 60);
      if (frames > 0) await _link.pumpFrames(frames);
      final state = await _link.readState();

      if (ok) {
        return _textResult(
          '✅ 已${restart ? '热重启' : '热重载'}'
          '（SIGUSR${restart ? '2' : '1'}${restart ? '，状态重置' : '，状态保留'}）\n'
          '状态：${_describeState(state)}',
        );
      }
      return _textResult(
        '⚠️ 信号已发出，但没等到「${restart ? 'Restarted' : 'Reloaded'} application」。'
        '改动涉及初始化逻辑时用 restart:true；若失败原因是编译错误，看 get_console。\n'
        '状态：${_describeState(state)}',
        isError: true,
      );
    }

    // Web 通道没有真热重载，只能重编译 + 刷新页面。
    final buildResult = await _buildProject(args);
    if (buildResult['isError'] == true) return buildResult;

    await _session.client.reload();
    // 刷新后执行上下文会被替换，等桥接重新挂上。
    await _session.waitForBridge(const Duration(seconds: 60));

    final frames = _intArg(args, 'frames', 60);
    if (frames > 0) await _link.pumpFrames(frames);

    final state = await _link.readState();
    return _textResult('✅ 已重编译并刷新页面\n状态：${_describeState(state)}');
  }

  Future<Map<String, dynamic>> _getConsole(Map<String, dynamic> args) async {
    final limit = _intArg(args, 'limit', 50);
    final clear = _boolArg(args, 'clear', false);
    final level = _strArg(args, 'level');

    var entries = _link.consoleEntries;
    if (level != null) {
      entries = entries.where((e) => e.level == level).toList();
    }
    final selected = entries.length > limit
        ? entries.sublist(entries.length - limit)
        : entries;

    if (clear) _link.clearConsole();

    if (selected.isEmpty) {
      return _textResult(
        '（无控制台输出${level == null ? '' : '（级别 $level）'}，'
        '共缓冲 ${entries.length} 条）',
      );
    }

    return _textResult(
      '最近 ${selected.length} 条（共缓冲 ${entries.length} 条）：\n'
      '${selected.map((e) => e.line).join('\n')}',
    );
  }

  Future<Map<String, dynamic>> _screenshotViewport(
    Map<String, dynamic> args,
  ) async {
    final frames = _intArg(args, 'frames', 2);
    if (frames > 0) await _link.pumpFrames(frames);

    final bytes = await _link.captureScreenshot();
    // 原生端没有 DOM 可问，尺寸直接从刚抓的帧里解 —— 比再问一次更准。
    var viewport = await _link.viewportSize();
    if (viewport['w'] == null) viewport = pngSize(bytes);

    final target = _resolveScreenshotPath(_strArg(args, 'path'));
    final file = File(target);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);

    final state = await _link.readState();
    final summary = '✅ 已抓图\n'
        '文件：$target\n'
        '大小：${(bytes.length / 1024).toStringAsFixed(1)} KB'
        '｜视口 ${viewport['w']}x${viewport['h']}'
        '（dpr ${viewport['dpr']}）\n'
        '状态：${_describeState(state)}';

    if (!_boolArg(args, 'inline', true)) return _textResult(summary);

    return {
      'content': [
        {
          'type': 'image',
          'data': base64Encode(bytes),
          'mimeType': 'image/png',
        },
        {'type': 'text', 'text': summary},
      ],
    };
  }

  String _resolveScreenshotPath(String? requested) {
    if (requested != null) {
      final file = File(requested);
      return file.isAbsolute ? file.path : '$projectRoot/$requested';
    }
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '')
        .replaceAll('-', '')
        .split('.')
        .first;
    return '$_screenshotDir/capture-$stamp.png';
  }

  Future<Map<String, dynamic>> _getGameState(Map<String, dynamic> args) async {
    final frames = _intArg(args, 'frames', 0);
    if (frames > 0) await _link.pumpFrames(frames);

    final state = await _link.readState();
    if (state == null) {
      return _textResult('读不到状态：页面里没有 window.kirbyMcp', isError: true);
    }
    return _textResult(
      '${_describeState(state)}\n\n'
      '${const JsonEncoder.withIndent('  ').convert(state)}',
    );
  }

  Future<Map<String, dynamic>> _waitFrames(Map<String, dynamic> args) async {
    final frames = _intArg(args, 'frames', 0);
    if (frames <= 0) return _textResult('frames 必须大于 0', isError: true);

    await _link.pumpFrames(frames);
    final state = await _link.readState();
    return _textResult(
      '✅ 已推进 $frames 帧\n状态：${_describeState(state)}',
    );
  }

  Future<Map<String, dynamic>> _setWeather(Map<String, dynamic> args) async {
    final kind = _strArg(args, 'kind');
    if (kind == null) return _textResult('缺少 kind', isError: true);

    final result = await _link.sendCommand({'cmd': 'set_weather', 'kind': kind});
    if (result['ok'] != true) {
      return _textResult('设置天气失败：${jsonEncode(result)}', isError: true);
    }

    final frames = _intArg(args, 'frames', 60);
    if (frames > 0) await _link.pumpFrames(frames);

    final state = await _link.readState();
    return _textResult('✅ 天气 → $kind\n状态：${_describeState(state)}');
  }

  Future<Map<String, dynamic>> _restartLevel(Map<String, dynamic> args) async {
    final result = await _link.sendCommand({'cmd': 'restart'});
    final frames = _intArg(args, 'frames', 30);
    if (frames > 0) await _link.pumpFrames(frames);

    final state = await _link.readState();
    return _textResult(
      result['ok'] == true ? '✅ 已重开\n状态：${_describeState(state)}' : '重开失败：${jsonEncode(result)}',
      isError: result['ok'] != true,
    );
  }

  Future<Map<String, dynamic>> _setCamera(Map<String, dynamic> args) async {
    final command = <String, dynamic>{'cmd': 'set_camera'};
    for (final key in const ['yaw', 'pitch', 'distance']) {
      final value = args[key];
      if (value is num) command[key] = value;
    }

    final result = await _link.sendCommand(command);
    final frames = _intArg(args, 'frames', 30);
    if (frames > 0) await _link.pumpFrames(frames);

    return _textResult(
      result['ok'] == true
          ? '✅ 相机已更新：${jsonEncode(result['camera'])}'
          : '设置相机失败：${jsonEncode(result)}',
      isError: result['ok'] != true,
    );
  }

  Future<Map<String, dynamic>> _teleportPlayer(Map<String, dynamic> args) async {
    final x = args['x'];
    final z = args['z'];
    if (x is! num || z is! num) {
      return _textResult('teleport_player 需要数值型 x 与 z', isError: true);
    }

    final result = await _link.sendCommand({'cmd': 'teleport', 'x': x, 'z': z});
    final frames = _intArg(args, 'frames', 30);
    if (frames > 0) await _link.pumpFrames(frames);

    final state = await _link.readState();
    return _textResult(
      result['ok'] == true
          ? '✅ 已瞬移\n状态：${_describeState(state)}'
          : '瞬移失败：${jsonEncode(result)}',
      isError: result['ok'] != true,
    );
  }

  Future<Map<String, dynamic>> _pressKeys(Map<String, dynamic> args) async {
    final lines = <String>[];

    if (_boolArg(args, 'release_all', false)) {
      final result = await _link.sendCommand(
        {'cmd': 'release_keys', 'all': true},
      );
      lines.add(result['ok'] == true ? '已松开全部虚拟键' : '松开全部失败：${jsonEncode(result)}');
    }

    final hold = _strListArg(args, 'hold');
    if (hold.isNotEmpty) {
      final result = await _link.sendCommand({'cmd': 'hold_keys', 'keys': hold});
      lines.add(result['ok'] == true
          ? '按住：${hold.join(', ')}'
          : '按住失败：${jsonEncode(result)}');
      if (result['ok'] != true) return _textResult(lines.join('\n'), isError: true);
    }

    final release = _strListArg(args, 'release');
    if (release.isNotEmpty) {
      final result =
          await _link.sendCommand({'cmd': 'release_keys', 'keys': release});
      lines.add(result['ok'] == true
          ? '松开：${release.join(', ')}'
          : '松开失败：${jsonEncode(result)}');
      if (result['ok'] != true) return _textResult(lines.join('\n'), isError: true);
    }

    if (_boolArg(args, 'jump', false)) {
      await _link.sendCommand({'cmd': 'jump'});
      lines.add('已注入跳跃');
    }

    if (lines.isEmpty) {
      return _textResult(
        '没有可执行的动作：请给出 hold / release / release_all / jump 中的至少一项',
        isError: true,
      );
    }

    final frames = _intArg(args, 'frames', 0);
    if (frames > 0) await _link.pumpFrames(frames);

    final state = await _link.readState();
    return _textResult('${lines.join('\n')}\n状态：${_describeState(state)}');
  }

  Future<Map<String, dynamic>> _describeProject(
    Map<String, dynamic> args,
  ) async {
    final indexFile = File('$_webDir/index.html');
    final hasBuild = indexFile.existsSync();

    final buffer = StringBuffer()
      ..writeln('KirbyScene MCP（$kServerName v$kServerVersion）')
      ..writeln()
      ..writeln('项目根目录：$projectRoot')
      ..writeln('flutter：$flutterBinary')
      ..writeln('浏览器：${findChromeBinary() ?? '未找到（可用 KIRBY_CHROME 指定）'}')
      ..writeln('Web 构建：${hasBuild ? '已有（${indexFile.statSync().modified.toIso8601String()}）' : '缺失，先跑 build_project'}')
      ..writeln('截图目录：$_screenshotDir')
      ..writeln('macOS 工具链：${_macosEnv()['DEVELOPER_DIR'] ?? '未找到（macos 通道会失败）'}')
      ..writeln('Web 会话：${_session.hasClient ? '已连接（调试端口 ${_session.debugPort}${_session.isHeadless ? '，无头' : ''}）' : '未连接'}')
      ..writeln('macOS 会话：${_native.isConnected ? '已连接（端点 $kKirbyInprocPort'
          '${_native.appPid == null ? '，接管已有 App' : '，App pid ${_native.appPid}'}）' : '未连接'}')
      ..writeln('当前活跃通道：${_activeTransportLabel()}')
      ..writeln()
      ..writeln('工具（${tools.length} 个）：')
      ..writeAll(tools.map((t) => '  - ${t.name}'), '\n')
      ..writeln()
      ..writeln()
      ..writeln('已知边界（诚实说明）：')
      ..writeln('  · Web 后端是 flutter_scene 的实验性 WebGL2 shim，')
      ..writeln('    拿不到 SSAO / 泛光 / 景深 —— 要看完整效果走 device="macos"。')
      ..writeln('  · hot_reload 只有 macOS 通道是真热重载；Web 上是「重编译 + 刷新页面」。')
      ..writeln('  · 帧推进不靠引擎自觉：用 wait_frames 显式推进，时序才确定。');

    return _textResult(buffer.toString());
  }

  // ------------------------------------------------------------------
  // flutter 调用
  // ------------------------------------------------------------------

  Future<ProcessResult> _runFlutter(
    List<String> args, {
    required Duration timeout,
  }) async {
    try {
      return await Process.run(
        flutterBinary,
        args,
        workingDirectory: projectRoot,
      ).timeout(timeout);
    } on TimeoutException {
      return ProcessResult(0, -1, '', '编译超时（${timeout.inSeconds}s）');
    }
  }

  static String _tailLines(String text, int count) {
    final lines = text
        .split('\n')
        .map((l) => l.trimRight())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.length <= count) return lines.join('\n');
    return lines.sublist(lines.length - count).join('\n');
  }

  // ------------------------------------------------------------------
  // MCP stdio 循环
  // ------------------------------------------------------------------

  final Map<String, ToolSpec> _byName = {};

  Future<void> run() async {
    for (final tool in tools) {
      _byName[tool.name] = tool;
    }

    stderr.writeln('[$kServerName] 已启动，项目根目录 $projectRoot');
    stderr.writeln('[$kServerName] 共注册 ${tools.length} 个工具');

    final lines = stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      // 不 await：慢工具（编译）不能把后续请求堵在管道里。
      unawaited(_handleLine(trimmed));
    }

    await _session.dispose();
    await _native.dispose();
    stderr.writeln('[$kServerName] stdin 关闭，已退出');
  }

  Future<void> _handleLine(String line) async {
    Map<String, dynamic> message;
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map<String, dynamic>) {
        stderr.writeln('[$kServerName] 非对象消息，已忽略');
        return;
      }
      message = decoded;
    } catch (e) {
      stderr.writeln('[$kServerName] JSON 解析失败：$e');
      return;
    }

    final id = message['id'];
    final method = message['method'];

    // 通知（没有 id）不需要回包。
    if (id == null) return;

    try {
      final result = await _dispatch(method, message['params']);
      _reply({'jsonrpc': '2.0', 'id': id, 'result': result});
    } catch (e) {
      _reply({
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': -32603, 'message': '$e'},
      });
    }
  }

  Future<Map<String, dynamic>> _dispatch(String? method, Object? params) async {
    switch (method) {
      case 'initialize':
        final requested = params is Map ? params['protocolVersion'] : null;
        return {
          // 客户端给不认识的版本也没关系，回我们自己支持的版本即可。
          'protocolVersion': requested is String ? requested : kProtocolVersion,
          'capabilities': {
            'tools': {'listChanged': false},
            'resources': {'listChanged': false},
          },
          'serverInfo': {
            'name': kServerName,
            'version': kServerVersion,
          },
        };

      case 'ping':
        return const {};

      case 'tools/list':
        return {
          'tools': tools.map((t) => t.toJson()).toList(),
        };

      case 'tools/call':
        return _callTool(params);

      case 'resources/list':
        return const {'resources': []};

      case 'prompts/list':
        return const {'prompts': []};

      default:
        throw StateError('不支持的方法：$method');
    }
  }

  Future<Map<String, dynamic>> _callTool(Object? params) async {
    if (params is! Map) {
      return _textResult('tools/call 缺少 params', isError: true);
    }
    final name = params['name'];
    if (name is! String) {
      return _textResult('tools/call 缺少 name', isError: true);
    }

    final tool = _byName[name];
    if (tool == null) {
      return _textResult(
        '未知工具 "$name"。可用：${_byName.keys.join(', ')}',
        isError: true,
      );
    }

    final rawArgs = params['arguments'];
    final args = rawArgs is Map<String, dynamic>
        ? rawArgs
        : rawArgs is Map
            ? rawArgs.map((k, v) => MapEntry('$k', v))
            : <String, dynamic>{};

    try {
      return await tool.handler(args);
    } catch (e) {
      // 工具内部异常不该杀掉服务器——转成可读错误返回给客户端。
      return _textResult('工具 $name 执行失败：$e', isError: true);
    }
  }

  void _reply(Map<String, dynamic> payload) {
    try {
      stdout.write('${jsonEncode(payload)}\n');
      // 必须 flush：stdout 是管道时会被缓冲，不刷则客户端永远收不到回包。
      unawaited(stdout.flush());
    } catch (e) {
      stderr.writeln('[$kServerName] 回包写入失败：$e');
    }
  }
}

Future<void> main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln(
      'KirbyScene 宿主侧 MCP 服务器（stdio 传输）。\n'
      '通常由 .mcp.json 启动，不需要手动运行：\n'
      '  dart <项目根>/tool/kirby_mcp.dart\n\n'
      '环境变量：KIRBY_PROJECT_DIR / KIRBY_FLUTTER / KIRBY_CHROME\n',
    );
    exit(0);
  }

  final server = KirbyMcpServer();
  await server.run();
}
