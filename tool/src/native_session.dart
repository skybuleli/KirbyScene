/// macOS 通道：连到 **App 进程内**的回环端口，并代管 `flutter run -d macos` 进程。
///
/// 与 Web 通道的分工：
///   - 进程由本模块拉起（因此拿得到 pid）→ `hot_reload` 可以真的发 `SIGUSR1`，
///     `get_console` 直接读它的输出。这比 Web 通道那边"重编译 + 刷新页面"要真。
///   - 状态与命令走 App 内回环 TCP（见 `lib/mcp/inproc_host_io.dart`），
///     协议是极简的新行分隔 JSON，四种 op：state / cmd / screenshot / ping。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'game_link.dart';

/// 与 `lib/mcp/inproc_host_io.dart` 里的常量保持一致（避开 CellScene 的 7007）。
const int kKirbyInprocPort = 7008;

// ---------------------------------------------------------------------------
// flutter run -d macos 进程
// ---------------------------------------------------------------------------

class MacAppProcess {
  Process? _process;
  final List<ConsoleEntry> _log = [];
  static const int _logLimit = 500;
  int _reloadMarks = 0;

  bool get isRunning => _process != null;
  int? get pid => _process?.pid;

  /// flutter run 的输出，供 MCP 的 `get_console` 使用。
  List<ConsoleEntry> get log => List.unmodifiable(_log);

  /// 已经观察到多少次「Reloaded application」——用来确认热重载真的生效，
  /// 而不是只看命令有没有发出去。
  int get reloadMarks => _reloadMarks;

  void clearLog() => _log.clear();

  /// 拉起 `flutter run -d macos`。
  ///
  /// 需要完整的 Xcode 工具链；调用方负责把 `DEVELOPER_DIR` 放进 [extraEnv]
  /// （本机 Xcode 可能不在标准位置，见 `dev.sh` 里的说明）。
  Future<void> launch({
    required String flutterBinary,
    required String projectRoot,
    Map<String, String>? extraEnv,
  }) async {
    if (_process != null) await stop();

    _process = await Process.start(
      flutterBinary,
      const ['run', '-d', 'macos'],
      workingDirectory: projectRoot,
      environment: extraEnv,
    );

    _drain(_process!.stdout);
    _drain(_process!.stderr);
    unawaited(_process!.exitCode.then((code) {
      _push('flutter run 退出（code $code）');
      _process = null;
    }));
  }

  void _drain(Stream<List<int>> stream) {
    stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _push,
          onError: (Object _) {},
          cancelOnError: false,
        );
  }

  void _push(String rawLine) {
    final line = rawLine.trimRight();
    if (line.isEmpty) return;
    if (line.contains('Reloaded application') ||
        line.contains('Restarted application')) {
      _reloadMarks++;
    }
    _log.add(ConsoleEntry.fromRawLine(line));
    if (_log.length > _logLimit) {
      _log.removeRange(0, _log.length - _logLimit);
    }
  }

  /// 等 flutter run 打出调试服务就绪的标志。
  Future<bool> waitForDebugService(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_process == null) return false;
      if (_log.any((e) => e.text.contains('Flutter run key commands'))) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return false;
  }

  /// 发 `SIGUSR1` 触发热重载，并等到日志里出现新的「Reloaded application」。
  ///
  /// 只回报"信号发出去了"是不够的——那会出现"看着成功其实没生效"。
  Future<bool> hotReload({Duration timeout = const Duration(seconds: 40)}) {
    return _signal(ProcessSignal.sigusr1, timeout, startsWith: 'Reload');
  }

  /// 发 `SIGUSR2` 触发热重启（改到初始化逻辑时用）。
  Future<bool> hotRestart({Duration timeout = const Duration(seconds: 60)}) {
    return _signal(ProcessSignal.sigusr2, timeout, startsWith: 'Restart');
  }

  Future<bool> _signal(
    ProcessSignal signal,
    Duration timeout, {
    required String startsWith,
  }) async {
    final process = _process;
    if (process == null) return false;

    final before = _reloadMarks;
    process.kill(signal);

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (_reloadMarks > before) return true;
      // 日志里出现明确失败就早退，不必等满超时。
      final tail = _log.length > 6 ? _log.sublist(_log.length - 6) : _log;
      if (tail.any((e) => e.text.contains('Failed to hot'))) return false;
    }
    return false;
  }

  Future<void> stop() async {
    final process = _process;
    if (process == null) return;
    process.kill(ProcessSignal.sigterm);
    // 给它一点时间自己退，退不掉再强杀。
    await Future<void>.delayed(const Duration(milliseconds: 600));
    try {
      process.kill(ProcessSignal.sigkill);
    } catch (_) {}
    _process = null;
  }
}

// ---------------------------------------------------------------------------
// 回环 TCP 连接
// ---------------------------------------------------------------------------

class NativeLink implements GameLink {
  NativeLink._(this._socket, this._app) {
    _subscription = _socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _handleLine,
          onDone: () => _close('对端关闭连接'),
          onError: (Object e) => _close('$e'),
          cancelOnError: false,
        );
  }

  static Future<NativeLink> connect({
    int port = kKirbyInprocPort,
    MacAppProcess? app,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final deadline = DateTime.now().add(timeout);
    Object? lastError;
    while (DateTime.now().isBefore(deadline)) {
      try {
        final socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          port,
          timeout: const Duration(seconds: 2),
        );
        socket.setOption(SocketOption.tcpNoDelay, true);
        return NativeLink._(socket, app);
      } catch (e) {
        lastError = e;
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
    throw StateError(
      '连不上 App 的回环端口 $port（$lastError）。'
      'App 起来了吗？端口被别的进程占用了吗？',
    );
  }

  final Socket _socket;
  final MacAppProcess? _app;
  late final StreamSubscription<String> _subscription;

  /// 协议是严格的一问一答，所以按 FIFO 配对，不需要 id。
  final Queue<Completer<Map<String, dynamic>>> _waiting = Queue();

  bool _closed = false;
  String? _closeReason;

  @override
  bool get isOpen => !_closed;

  String? get closeReason => _closeReason;

  void _close(String reason) {
    if (_closed) return;
    _closed = true;
    _closeReason = reason;
    for (final completer in _waiting) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('回环连接关闭：$reason'));
      }
    }
    _waiting.clear();
  }

  void _handleLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;

    if (_waiting.isEmpty) {
      // 没有对应的请求：说明协议错位了，记到 stderr 便于排查，不要静默吞掉。
      stderr.writeln('[native] 收到无对应请求的应答：${trimmed.substring(0, trimmed.length.clamp(0, 120))}');
      return;
    }

    final completer = _waiting.removeFirst();
    if (completer.isCompleted) return;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) {
        completer.complete(decoded);
      } else {
        completer.completeError(StateError('应答不是 JSON 对象：$trimmed'));
      }
    } catch (e) {
      completer.completeError(StateError('应答解析失败：$e'));
    }
  }

  Future<Map<String, dynamic>> _request(
    String op, [
    Map<String, dynamic>? extra,
  ]) async {
    if (_closed) {
      throw StateError('回环连接已关闭：${_closeReason ?? '未知原因'}');
    }
    final completer = Completer<Map<String, dynamic>>();
    _waiting.add(completer);
    // 换行符不能省：另一端是 LineSplitter 分帧，缺了它请求会一直留在缓冲区里，
    // 表现为"写成功了但永远等不到回应"。
    _socket.write('${jsonEncode({'op': op, ...?extra})}\n');

    return completer.future.timeout(
      // 15 秒而不是 60 秒：桥接卡住时应当快速暴露，而不是让上层干等。
      const Duration(seconds: 15),
      onTimeout: () {
        _waiting.remove(completer);
        throw TimeoutException('桥接请求超时：$op');
      },
    );
  }

  @override
  Future<Map<String, dynamic>?> readState() async {
    try {
      final reply = await _request('state');
      if (reply['ok'] != true) return null;
      final state = reply['state'];
      return state is Map<String, dynamic> ? state : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Map<String, dynamic>> sendCommand(Map<String, dynamic> command) async {
    final reply = await _request('cmd', {'command': command});
    if (reply['ok'] != true) {
      return {'ok': false, 'error': '${reply['error']}'};
    }
    final result = reply['result'];
    return result is Map<String, dynamic>
        ? result
        : {'ok': false, 'error': '桥接返回了非对象结果'};
  }

  /// 等 App 自己的帧计数前进 [count] 帧。
  ///
  /// 这里**不是**去驱动帧——原生窗口有自己的 vsync 循环，
  /// 我们只是等它走够。超时不抛异常：调用方从状态里能看到实际帧数，
  /// 而"窗口被最小化导致 rAF 停了"这种情况该让它自然暴露，而不是伪装成失败。
  @override
  Future<void> pumpFrames(int count) async {
    if (count <= 0) return;

    final start = await readState();
    final startFrame = (start?['frame'] as num?)?.toInt();
    if (startFrame == null) {
      await Future<void>.delayed(_estimate(count));
      return;
    }

    final deadline = DateTime.now().add(_estimate(count) + const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 40));
      final now = (await readState())?['frame'] as num?;
      if (now != null && now.toInt() >= startFrame + count) return;
    }
  }

  static Duration _estimate(int frames) =>
      Duration(milliseconds: (frames * 1000 / 60).round());

  @override
  Future<Uint8List> captureScreenshot() async {
    final reply = await _request('screenshot');
    if (reply['ok'] != true) {
      throw StateError('${reply['error'] ?? '截图失败'}');
    }
    final data = reply['png'];
    if (data is! String) throw StateError('截图应答里没有 png 字段');
    return base64Decode(data);
  }

  @override
  Future<Map<String, dynamic>> viewportSize() async => _unknownSize;

  /// 原生端没有 DOM 可问。截图工具会在拿到 PNG 后用它自行解出真实尺寸
  /// （见 [pngSize]），所以这里只需要表明"我不知道"。
  static const Map<String, dynamic> _unknownSize = {'source': 'native'};

  @override
  List<ConsoleEntry> get consoleEntries =>
      _app?.log ?? const <ConsoleEntry>[];

  @override
  void clearConsole() => _app?.clearLog();

  @override
  String describe() => '原生通道（App 内回环端口 $kKirbyInprocPort）';

  @override
  Future<void> dispose() async {
    await _subscription.cancel();
    try {
      await _socket.close();
    } catch (_) {}
    _close('主动关闭');
  }
}

// ---------------------------------------------------------------------------
// 会话
// ---------------------------------------------------------------------------

/// 负责「拉起 App → 连上回环端口 → 等桥接就绪」。
class NativeSession {
  NativeSession();

  final MacAppProcess app = MacAppProcess();
  NativeLink? _link;

  bool get isConnected => _link != null && _link!.isOpen;
  NativeLink get link {
    final value = _link;
    if (value == null || !value.isOpen) {
      throw StateError(
        '尚未连接 macOS App。先调用 run_project {device:"macos"}。'
        '${value?.closeReason == null ? '' : '（上次断开：${value!.closeReason}）'}',
      );
    }
    return value;
  }

  bool get launchedByUs => app.isRunning;
  int? get appPid => app.pid;

  /// 拉起 App（若需要）并连上它的回环端口。
  ///
  /// [reuse] 为 true 时先试着直连——这样能接管一个**已经在跑**的
  /// `flutter run -d macos` 会话，而不是另起一个（会撞构建目录）。
  Future<String> ensureRunning({
    required String projectRoot,
    required String flutterBinary,
    Map<String, String>? extraEnv,
    int port = kKirbyInprocPort,
    bool reuse = true,
    Duration readyTimeout = const Duration(seconds: 90),
  }) async {
    if (isConnected) {
      await _waitForBridge(readyTimeout);
      return describeEndpoint(port);
    }

    if (reuse) {
      try {
        _link = await NativeLink.connect(
          port: port,
          timeout: const Duration(seconds: 3),
        );
        await _waitForBridge(readyTimeout);
        return describeEndpoint(port);
      } catch (_) {
        // 没有现成的 App，自己拉一个。
      }
    }

    await app.launch(
      flutterBinary: flutterBinary,
      projectRoot: projectRoot,
      extraEnv: extraEnv,
    );

    final ready = await app.waitForDebugService(const Duration(seconds: 120));
    if (!ready) {
      final tail = app.log.length > 12
          ? app.log.sublist(app.log.length - 12).map((e) => e.line).join('\n')
          : app.log.map((e) => e.line).join('\n');
      throw StateError('flutter run -d macos 没起来。日志末尾：\n$tail');
    }

    _link = await NativeLink.connect(
      port: port,
      app: app,
      timeout: const Duration(seconds: 60),
    );
    await _waitForBridge(readyTimeout);
    return describeEndpoint(port);
  }

  static String describeEndpoint(int port) => 'tcp://127.0.0.1:$port';

  Future<void> _waitForBridge(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final state = await link.readState();
      if (state != null && state['ready'] == true) return;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw StateError(
      '连上了回环端口，但游戏桥接没报告 ready。'
      'App 可能还在初始化，或初始化时抛了异常——看 flutter run 的输出。',
    );
  }

  Future<void> dispose() async {
    await _link?.dispose();
    _link = null;
    await app.stop();
  }
}

/// 从 PNG 头部解出宽高（IHDR 固定在第 16..24 字节）。
///
/// 原生端没有 DOM 可问，直接读自己刚抓的帧最省事也最准。
Map<String, dynamic> pngSize(Uint8List bytes) {
  if (bytes.length < 24) return const {'source': 'native'};
  final data = ByteData.sublistView(bytes, 16, 24);
  return {
    'w': data.getUint32(0),
    'h': data.getUint32(4),
    'dpr': 2.0,
    'source': 'native',
  };
}
