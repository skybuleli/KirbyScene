/// App 进程内的桥接端点（macOS / Windows / Linux 走这里）。
///
/// ## 为什么 macOS 不用 Web 那套 CDP
///
/// 原生进程有 `dart:io`，可以直接开监听端口，比"从外部驱动浏览器"更直接也更稳；
/// 而且拿得到真正的截图与帧计数，不需要靠 `Runtime.evaluate` 绕。
///
/// ## 协议刻意保持最小
///
/// 换行分隔的 JSON，请求四种：
/// ```
/// {"op":"state"}                          → {"ok":true,"state":{...}}
/// {"op":"cmd","command":{"cmd":"..."}}    → {"ok":true,"result":{...}}
/// {"op":"screenshot"}                     → {"ok":true,"png":"<base64>"}
/// {"op":"ping"}                           → {"ok":true}
/// ```
///
/// 形状与页面里 `window.kirbyMcp` 的 `state` / `cmd` 一一对应，
/// 这样**宿主侧的 MCP 工具不需要区分通道**——换的只是传输层。
///
/// 端口用 [kKirbyInprocPort]（7008，避开 CellScene 用的 7007），
/// 端口被占用时返回 false 而不抛异常，不影响 App 启动。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'bridge.dart';

/// 回环监听端口。刻意与 CellScene 的 7007 错开，两者可以同时跑。
const int kKirbyInprocPort = 7008;

/// 截图回调：返回 PNG 字节；无法截图时返回 null。
typedef ScreenshotProvider = Future<Uint8List?> Function();

class InprocMcpHost {
  InprocMcpHost(this.target, {this.screenshotProvider});

  final BridgeTarget target;
  final ScreenshotProvider? screenshotProvider;

  ServerSocket? _server;
  final List<Socket> _clients = [];

  bool get isRunning => _server != null;
  int? get boundPort => _server?.port;
  int get clientCount => _clients.length;

  /// 绑定并开始监听。端口被占用时返回 false（不抛异常、不影响 App 启动）。
  Future<bool> start({int port = kKirbyInprocPort}) async {
    if (_server != null) return true;
    try {
      final server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
        shared: true,
      );
      _server = server;
      server.listen(_handleConnection, onError: (Object _) {});
      return true;
    } on SocketException {
      return false;
    }
  }

  void _handleConnection(Socket socket) {
    socket.setOption(SocketOption.tcpNoDelay, true);
    _clients.add(socket);

    // add() 只入队：对端在传输途中断开时，写错误异步到达 done，
    // 不会被 _handleLine 的同步 try/catch 或读取流的 onError 接住。
    // 接受连接时就监听写流，避免错误先发生后注册处理器。
    unawaited(socket.done.then<void>(
      (_) => _clients.remove(socket),
      onError: (Object error, StackTrace stack) {
        _clients.remove(socket);
        socket.destroy();
      },
    ));

    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) => unawaited(_handleLine(socket, line)),
          onDone: () => _clients.remove(socket),
          onError: (Object _) => _clients.remove(socket),
          cancelOnError: true,
        );
  }

  Future<void> _handleLine(Socket socket, String line) async {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;

    Map<String, dynamic> reply;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map<String, dynamic>) {
        reply = {'ok': false, 'error': 'request must be a JSON object'};
      } else {
        reply = await _dispatch(decoded);
      }
    } catch (e) {
      reply = {'ok': false, 'error': 'request failed: $e'};
    }

    try {
      socket.add(utf8.encode('${jsonEncode(reply)}\n'));
    } catch (_) {
      // 客户端可能已断开，忽略。
      _clients.remove(socket);
    }
  }

  Future<Map<String, dynamic>> _dispatch(Map<String, dynamic> request) async {
    switch (request['op']) {
      case 'state':
        return {
          'ok': true,
          'state': _decodeOrNull(target.bridgeStateJson()),
        };

      case 'cmd':
        final command = request['command'];
        if (command is! Map) {
          return {'ok': false, 'error': '"command" must be an object'};
        }
        return {
          'ok': true,
          'result': _decodeOrNull(target.bridgeCommand(jsonEncode(command))),
        };

      case 'screenshot':
        final provider = screenshotProvider;
        if (provider == null) {
          return {'ok': false, 'error': '本实例未注册截图回调'};
        }
        final bytes = await provider();
        if (bytes == null) {
          return {'ok': false, 'error': '截图失败（视口不可用）'};
        }
        return {'ok': true, 'png': base64Encode(bytes)};

      case 'ping':
        return {'ok': true};

      default:
        return {
          'ok': false,
          'error': 'unknown op "${request['op']}"',
          'allowed': ['state', 'cmd', 'screenshot', 'ping'],
        };
    }
  }

  /// 桥接层保证返回合法 JSON，但这里仍兜一道：
  /// 解码失败不该让整条连接挂掉。
  static Object? _decodeOrNull(String json) {
    try {
      return jsonDecode(json);
    } catch (_) {
      return null;
    }
  }

  Future<void> dispose() async {
    for (final client in List<Socket>.of(_clients)) {
      try {
        await client.close();
      } catch (_) {}
    }
    _clients.clear();
    await _server?.close();
    _server = null;
  }
}
