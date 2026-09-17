/// KirbyScene MCP 服务器的浏览器侧基础设施：**纯 `dart:io`，零 package 依赖**。
///
/// 三件事：
///   1. [StaticWebServer] —— 用 `HttpServer` 直接伺服 `build/web`，
///      这样不必依赖 python / npx，也保证 `.wasm` 拿到 `application/wasm`。
///   2. [BrowserSession] —— 找 Chrome、带调试端口拉起、等端口就绪、导航到应用。
///   3. [CdpClient] —— 手写 Chrome DevTools Protocol 客户端。
///      `dart:io` 自带 `WebSocket.connect`，所以 CDP 不需要任何第三方库。
///
/// 关键设计：不要指望"浏览器自然会推进帧"。
/// 无头环境（以及被遮挡/最小化的窗口）里 rAF 几乎不跑，
/// 于是游戏逻辑看起来"没执行"。所以这里提供 [CdpClient.pumpFrames]，
/// 用 `await requestAnimationFrame(...)` 显式推进 N 帧，让时序变得确定。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'game_link.dart';

// ---------------------------------------------------------------------------
// 静态文件服务
// ---------------------------------------------------------------------------

/// 扩展名 → MIME。`.wasm` 必须是 `application/wasm`，
/// 否则 `WebAssembly.instantiateStreaming` 会拒绝加载 CanvasKit。
const Map<String, String> _kMimeTypes = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.map': 'application/json; charset=utf-8',
  '.wasm': 'application/wasm',
  '.css': 'text/css; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.bin': 'application/octet-stream',
  '.symbols': 'text/plain; charset=utf-8',
};

/// 伺服一个静态目录。绑定在随机空闲端口（loopback），避免固定端口冲突。
class StaticWebServer {
  HttpServer? _server;
  String _root = '';

  bool get isRunning => _server != null;
  int get port => _server?.port ?? 0;
  String get root => _root;

  Future<int> start(String root) async {
    final existing = _server;
    if (existing != null) return existing.port;

    if (!Directory(root).existsSync()) {
      throw StateError('静态目录不存在：$root（先跑 build_project）');
    }
    _root = root;

    // 端口传 0 让系统分配，避免和用户自己开的预览服务撞车。
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(_handle, onError: (Object _) {});
    return server.port;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      var path = Uri.decodeComponent(request.uri.path);
      if (path.isEmpty || path == '/') path = '/index.html';

      var file = File('$_root$path');
      if (!file.existsSync()) {
        // Flutter Web 是单页应用：未知路径回落到 index.html。
        final fallback = File('$_root/index.html');
        if (!fallback.existsSync()) {
          response.statusCode = HttpStatus.notFound;
          await response.close();
          return;
        }
        file = fallback;
      }

      final dot = file.path.lastIndexOf('.');
      final ext = dot < 0 ? '' : file.path.substring(dot).toLowerCase();
      response.headers.contentType =
          ContentType.parse(_kMimeTypes[ext] ?? 'application/octet-stream');
      // 开发期必须禁缓存，否则 reload 拿到的还是旧构建。
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      await response.addStream(file.openRead());
      await response.close();
    } catch (_) {
      // 客户端提前断开属正常路径，静默收尾即可。
      try {
        await response.close();
      } catch (_) {}
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }
}

// ---------------------------------------------------------------------------
// CDP 客户端
// ---------------------------------------------------------------------------

/// Web 通道的 [GameLink] 实现：通过 CDP 驱动页面里的 `window.kirbyMcp`。
class CdpClient implements GameLink {
  CdpClient._(this._socket) {
    _subscription = _socket.listen(
      _handleRaw,
      onDone: () => _close('对端关闭连接'),
      onError: (Object error) => _close('$error'),
      cancelOnError: false,
    );
  }

  static Future<CdpClient> connect(String webSocketUrl) async {
    final socket = await WebSocket.connect(webSocketUrl);
    return CdpClient._(socket);
  }

  final WebSocket _socket;
  late final StreamSubscription<dynamic> _subscription;

  int _nextId = 0;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  final List<ConsoleEntry> _console = [];
  static const int _consoleLimit = 500;

  bool _closed = false;
  String? _closeReason;

  @override
  bool get isOpen => !_closed;
  String? get closeReason => _closeReason;

  /// 收到的控制台与异常日志（最新的在末尾）。
  @override
  List<ConsoleEntry> get consoleEntries => List.unmodifiable(_console);

  @override
  void clearConsole() => _console.clear();

  Future<Map<String, dynamic>> send(
    String method, [
    Map<String, dynamic>? params,
  ]) {
    if (_closed) {
      throw StateError('CDP 连接已关闭：${_closeReason ?? '未知原因'}');
    }
    final id = ++_nextId;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;

    _socket.add(jsonEncode({
      'id': id,
      'method': method,
      'params': ?params,
    }));

    return completer.future.timeout(
      const Duration(seconds: 90),
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException('CDP 调用超时：$method');
      },
    );
  }

  void _close(String reason) {
    if (_closed) return;
    _closed = true;
    _closeReason = reason;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('CDP 连接关闭：$reason'));
      }
    }
    _pending.clear();
  }

  @override
  Future<void> dispose() async {
    await _subscription.cancel();
    try {
      await _socket.close();
    } catch (_) {}
    _close('主动关闭');
  }

  void _handleRaw(dynamic raw) {
    final String text;
    try {
      text = raw is String ? raw : utf8.decode(raw as List<int>);
    } catch (_) {
      return;
    }

    final Object? decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) return;

    final id = decoded['id'];
    if (id is int) {
      final completer = _pending.remove(id);
      if (completer == null || completer.isCompleted) return;
      final error = decoded['error'];
      if (error != null) {
        completer.completeError(StateError('CDP 返回错误：${jsonEncode(error)}'));
      } else {
        completer.complete((decoded['result'] as Map<String, dynamic>?) ?? const {});
      }
      return;
    }

    _handleEvent(decoded);
  }

  void _handleEvent(Map<String, dynamic> message) {
    final params = message['params'];
    if (params is! Map<String, dynamic>) return;

    switch (message['method']) {
      case 'Runtime.consoleAPICalled':
        _pushConsole('${params['type']}', _renderArgs(params['args']));

      case 'Runtime.exceptionThrown':
        final details = params['exceptionDetails'];
        if (details is Map) {
          final description =
              (details['exception'] as Map?)?['description'] ??
                  details['text'] ??
                  details['exceptionDescription'] ??
                  '未知异常';
          _pushConsole('exception', '$description');
        }

      case 'Log.entryAdded':
        final entry = params['entry'];
        if (entry is Map) {
          _pushConsole('${entry['level']}', '${entry['text']}');
        }
    }
  }

  void _pushConsole(String level, String text) {
    _console.add(ConsoleEntry(level, text.trim()));
    if (_console.length > _consoleLimit) {
      _console.removeRange(0, _console.length - _consoleLimit);
    }
  }

  static String _renderArgs(Object? args) {
    if (args is! List) return '';
    return args.map(_renderArg).join(' ');
  }

  static String _renderArg(Object? arg) {
    if (arg is! Map) return '$arg';
    // RemoteObject：能直接取值就取 value，否则退回 description / type。
    final value = arg['value'];
    if (value != null) return '$value';
    final description = arg['description'];
    if (description != null) return '$description';
    final preview = arg['preview'];
    if (preview is Map && preview['properties'] is List) {
      return (preview['properties'] as List)
          .whereType<Map>()
          .map((p) => '${p['name']}: ${p['value']}')
          .join(', ');
    }
    return '${arg['type']}';
  }

  /// 打开工具需要的域。`Runtime` 负责求值与异常，`Log` 收网络/安全等条目。
  Future<void> enableDomains() async {
    await send('Page.enable');
    await send('Runtime.enable');
    try {
      await send('Log.enable');
    } catch (_) {
      // 个别版本/构建没有 Log 域，不影响主流程。
    }
  }

  /// 在页面里求值并把结果按值取回。
  Future<dynamic> evaluate(String expression, {bool awaitPromise = false}) async {
    final result = await send('Runtime.evaluate', {
      'expression': expression,
      'returnByValue': true,
      'awaitPromise': awaitPromise,
      'userGesture': true,
    });

    final exception = result['exceptionDetails'];
    if (exception is Map) {
      final text = (exception['exception'] as Map?)?['description'] ??
          exception['text'] ??
          '未知错误';
      throw StateError('页面内求值失败：$text');
    }
    return (result['result'] as Map?)?['value'];
  }

  /// 显式推进 [count] 帧。
  ///
  /// 这是整套方案里最关键的一个动作：不能假设浏览器会自己跑帧。
  /// 无头模式、被遮挡的窗口、以及"刚导航完还没开始合成"的情况下，
  /// rAF 可能一帧都不触发，游戏逻辑就完全不动——表现为"工具调了但没反应"。
  /// 这里靠 `await requestAnimationFrame` 把帧一张张要回来，时序就确定了。
  @override
  Future<void> pumpFrames(int count) async {
    if (count <= 0) return;
    await evaluate(
      'new Promise((resolve) => {'
      '  let left = $count;'
      '  const step = () => (--left <= 0 ? resolve(true) : requestAnimationFrame(step));'
      '  requestAnimationFrame(step);'
      '})',
      awaitPromise: true,
    );
  }

  @override
  Future<Uint8List> captureScreenshot({String format = 'png'}) async {
    final result = await send('Page.captureScreenshot', {
      'format': format,
      'captureBeyondViewport': false,
    });
    return base64Decode(result['data'] as String);
  }

  Future<void> navigate(String url) async {
    await send('Page.navigate', {'url': url});
  }

  Future<void> reload({bool ignoreCache = true}) async {
    await send('Page.reload', {'ignoreCache': ignoreCache});
  }

  /// 取视口尺寸，用于在截图信息里回报分辨率。
  @override
  Future<Map<String, dynamic>> viewportSize() async {
    final value = await evaluate(
      'JSON.stringify({w: window.innerWidth, h: window.innerHeight,'
      ' dpr: window.devicePixelRatio || 1})',
    );
    if (value is String) {
      final decoded = jsonDecode(value);
      if (decoded is Map<String, dynamic>) return decoded;
    }
    return const {};
  }

  /// 读一次游戏状态快照；页面还没挂桥接时返回 null。
  @override
  Future<Map<String, dynamic>?> readState() async {
    final raw = await evaluate(
      'window.kirbyMcp && typeof window.kirbyMcp.state === "string"'
      ' ? window.kirbyMcp.state : null',
    );
    if (raw is! String) return null;
    final decoded = jsonDecode(raw);
    return decoded is Map<String, dynamic> ? decoded : null;
  }

  /// 下发一条游戏命令（走页面里的 `window.kirbyMcp.cmd`）。
  @override
  Future<Map<String, dynamic>> sendCommand(Map<String, dynamic> command) async {
    final raw = await evaluate(
      'window.kirbyMcp.cmd(${jsonEncode(jsonEncode(command))})',
    );
    if (raw is! String) {
      throw StateError('桥接返回了非字符串结果：$raw');
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('桥接返回了非法 JSON：$raw');
    }
    return decoded;
  }

  @override
  String describe() => 'Web 通道（Chrome DevTools Protocol）';
}

// ---------------------------------------------------------------------------
// 浏览器会话
// ---------------------------------------------------------------------------

/// 找本机可用的 Chromium 系浏览器。
String? findChromeBinary() {
  final fromEnv = Platform.environment['KIRBY_CHROME'];
  if (fromEnv != null && fromEnv.isNotEmpty && File(fromEnv).existsSync()) {
    return fromEnv;
  }

  const candidates = [
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/Applications/Chromium.app/Contents/MacOS/Chromium',
    '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
    '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
    '/Applications/Vivaldi.app/Contents/MacOS/Vivaldi',
  ];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

/// 管理「静态服务 + Chrome 进程 + CDP 连接」这三件套的生命周期。
class BrowserSession {
  StaticWebServer? _server;
  Process? _chrome;
  CdpClient? _client;
  int _debugPort = 0;
  bool _headless = false;
  String _appUrl = '';

  bool get hasClient => _client != null && _client!.isOpen;
  CdpClient get client {
    final value = _client;
    if (value == null || !value.isOpen) {
      throw StateError(
        '尚未连接浏览器。先调用 run_project 拉起并接入。'
        '${value?.closeReason == null ? '' : '（上次断开原因：${value!.closeReason}）'}',
      );
    }
    return value;
  }

  int get debugPort => _debugPort;
  String get appUrl => _appUrl;
  bool get launchedByUs => _chrome != null;

  /// 确保「构建产物已伺服 + 浏览器已起 + 已导航 + 桥接已就绪」。
  ///
  /// 已经就绪时是幂等的：重复调用只会刷新一次导航。
  ///
  /// [attachOnly] 为 true 时**只接管已经在跑的浏览器**：不启静态服务、
  /// 不拉起新进程、不导航。用途是把 MCP 接到 `flutter run -d chrome` 的调试会话上——
  /// 这样「改代码 → 热重载 → 用工具观察/驱动」可以共用同一个浏览器，
  /// 而不是被 MCP 抢过去换成静态服务器的页面（那样就丢掉热重载连接了）。
  Future<String> ensureRunning({
    required String projectRoot,
    int debugPort = 9333,
    bool headless = false,
    String query = '',
    bool attachOnly = false,
    Duration readyTimeout = const Duration(seconds: 60),
  }) async {
    if (attachOnly) {
      if (!hasClient || _debugPort != debugPort) {
        await _client?.dispose();
        _client = await _tryAttach(debugPort);
        if (_client == null) {
          throw StateError(
            '接管失败：127.0.0.1:$debugPort 上没有可用的调试端口。'
            '请先用 tool/dev.sh 起一个带 --web-browser-debug-port=$debugPort 的 flutter run。',
          );
        }
        _debugPort = debugPort;
      }
      await _client!.enableDomains();
      await waitForBridge(readyTimeout);
      _appUrl = await currentPageUrl();
      return _appUrl;
    }

    final webDir = '$projectRoot/build/web';
    if (!File('$webDir/index.html').existsSync()) {
      throw StateError('找不到 $webDir/index.html —— 先调用 build_project');
    }

    // 1) 静态服务
    _server ??= StaticWebServer();
    final port = await _server!.start(webDir);
    _appUrl = 'http://localhost:$port/$query';

    // 2) 浏览器。已连上且仍是同一个调试端口时直接复用。
    if (hasClient && _debugPort == debugPort) {
      await client.enableDomains();
      await client.navigate(_appUrl);
    } else {
      await _client?.dispose();
      _client = null;

      // 先看用户是不是已经自己开了一个带调试端口的浏览器，能复用就复用。
      _client = await _tryAttach(debugPort);
      if (_client == null) {
        await _launchChrome(
          debugPort: debugPort,
          headless: headless,
          url: _appUrl,
        );
        _client = await _waitForBrowser(debugPort);
      } else {
        await _client!.navigate(_appUrl);
      }
      _debugPort = debugPort;
      _headless = headless;
      await _client!.enableDomains();
    }

    await waitForBridge(readyTimeout);
    return _appUrl;
  }

  Future<CdpClient?> _tryAttach(int port) async {
    try {
      final version = await _httpGetJson('http://127.0.0.1:$port/json/version');
      if (version is! Map) return null;
      return await _connectToPageTarget(port);
    } catch (_) {
      return null;
    }
  }

  Future<CdpClient> _waitForBrowser(int port) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      try {
        await _httpGetJson('http://127.0.0.1:$port/json/version');
        return await _connectToPageTarget(port);
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    throw StateError(
      '等不到浏览器的调试端口 $port。'
      '${_chrome == null ? '' : '（进程仍在跑，可能是启动参数被拒）'}',
    );
  }

  Future<CdpClient> _connectToPageTarget(int port) async {
    var targets = await _httpGetJson('http://127.0.0.1:$port/json/list');
    var page = _pickPage(targets);

    if (page == null) {
      // 没有页面目标（例如浏览器刚起只有 about:blank 的 UI 目标），自己开一个。
      await _httpRequest(
        'PUT',
        'http://127.0.0.1:$port/json/new?about:blank',
      );
      targets = await _httpGetJson('http://127.0.0.1:$port/json/list');
      page = _pickPage(targets);
    }

    final url = page?['webSocketDebuggerUrl'];
    if (url is! String) {
      throw StateError('找不到可用的页面目标（/json/list 里没有 type=page 的项）');
    }
    return CdpClient.connect(url);
  }

  static Map<dynamic, dynamic>? _pickPage(dynamic targets) {
    if (targets is! List) return null;
    final pages = targets.whereType<Map>().where((t) => t['type'] == 'page');
    if (pages.isEmpty) return null;
    // 优先挑已经是我们应用的页面，其次才是任意页面。
    for (final page in pages) {
      final url = '${page['url']}';
      if (url.contains('localhost') || url.contains('127.0.0.1')) return page;
    }
    return pages.first;
  }

  Future<void> _launchChrome({
    required int debugPort,
    required bool headless,
    required String url,
  }) async {
    final binary = findChromeBinary();
    if (binary == null) {
      throw StateError(
        '找不到 Chrome / Chromium。'
        '可设置环境变量 KIRBY_CHROME 指向浏览器可执行文件。',
      );
    }

    // 上一个由我们拉起的进程要先收掉，否则它会占着调试端口导致新进程起不来。
    if (_chrome != null) {
      _chrome!.kill();
      _chrome = null;
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }

    final profile = '${Directory.systemTemp.path}/kirby_mcp_chrome_$debugPort';
    final args = <String>[
      '--remote-debugging-port=$debugPort',
      '--user-data-dir=$profile',
      '--no-first-run',
      '--no-default-browser-check',
      '--no-proxy-server',
      // 这三个关掉后台节流：窗口被遮挡/最小化时 rAF 会被暂停，
      // 那 pumpFrames 就会一直等不到帧而超时。
      '--disable-background-timer-throttling',
      '--disable-backgrounding-occluded-windows',
      '--disable-renderer-backgrounding',
      '--window-size=1440,900',
      if (headless) ...const [
        '--headless=new',
        '--no-sandbox',
        '--disable-gpu-sandbox',
        '--enable-unsafe-swiftshader',
        '--hide-scrollbars',
      ],
      url,
    ];

    _chrome = await Process.start(
      binary,
      args,
      mode: ProcessStartMode.detachedWithStdio,
    );
    // 不 drain 的话，子进程写满管道后会卡住。
    unawaited(_chrome!.stdout.drain<void>());
    unawaited(_chrome!.stderr.drain<void>());
  }

  /// 等页面里的桥接对象出现且报告 `ready: true`。
  Future<bool> waitForBridge(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        // 先确认桥接对象已挂出，再推帧。
        // 顺序反过来的话，导航刚完成时页面可能还是空的执行上下文，
        // pumpFrames 会一直等不到 rAF 而把整轮轮询卡住。
        final attached = await client.evaluate(
          'typeof window.kirbyMcp !== "undefined"',
        );
        if (attached == true) {
          await client.pumpFrames(2);
          final state = await readState();
          if (state != null && state['ready'] == true) return true;
        }
      } catch (_) {
        // 页面还没就绪（执行上下文正在替换等），继续等。
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw StateError(
      '等不到游戏桥接就绪（window.kirbyMcp.state 未返回 ready:true）。'
      '用 get_console 看看页面里有没有报错。',
    );
  }

  /// 统一的连接接口 —— 工具层只认这个，不关心下面是 CDP 还是回环 TCP。
  GameLink get link => client;

  Future<Map<String, dynamic>?> readState() => client.readState();

  Future<Map<String, dynamic>> sendCommand(Map<String, dynamic> command) =>
      client.sendCommand(command);

  /// 当前页面地址（接管已有浏览器时，地址由对方的 flutter run 决定）。
  Future<String> currentPageUrl() async {
    try {
      final url = await client.evaluate('location.href');
      return url is String ? url : '';
    } catch (_) {
      return '';
    }
  }

  Future<void> dispose() async {
    await _client?.dispose();
    _client = null;
    if (_chrome != null) {
      _chrome!.kill();
      _chrome = null;
    }
    await _server?.stop();
    _server = null;
  }

  bool get isHeadless => _headless;

  // ---- HTTP 小工具 ----

  static Future<dynamic> _httpGetJson(String url) => _httpRequest('GET', url);

  static Future<dynamic> _httpRequest(String method, String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final request = await client.openUrl(method, Uri.parse(url));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode >= 400) {
        throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
      }
      if (body.isEmpty) return null;
      return jsonDecode(body);
    } finally {
      client.close(force: true);
    }
  }
}
