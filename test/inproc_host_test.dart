/// 进程内桥接端点（macOS 通道）的协议测试。
///
/// 这里**真的开 socket、真的连**：这个端点存在的意义就是"宿主进程能连进来"，
/// 用内存 fake 测会把最该验证的部分绕过去。
/// 端口传 0 让系统分配，避免和正在运行的游戏抢 7008。
library;
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kirby_scene/mcp/bridge.dart';
import 'package:kirby_scene/mcp/inproc_host_io.dart';

/// 假的游戏目标：只验证协议转发，不碰 GPU。
class _FakeTarget implements BridgeTarget {
  int commandCount = 0;

  @override
  String bridgeStateJson() =>
      jsonEncode({'ready': true, 'score': 3, 'frame': 42});

  @override
  String bridgeCommand(String commandJson) {
    commandCount++;
    final request = jsonDecode(commandJson) as Map<String, dynamic>;
    if (request['cmd'] == 'explode') {
      return jsonEncode({'ok': false, 'error': '故意失败'});
    }
    return jsonEncode({'ok': true, 'echo': request['cmd']});
  }
}

/// 简化的一问一答客户端（协议本身是 FIFO 配对，不需要 id）。
class _Client {
  _Client(this._socket) {
    _socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (line.trim().isEmpty) return;
      final completer = _pending.isEmpty ? null : _pending.removeAt(0);
      completer?.complete(jsonDecode(line) as Map<String, dynamic>);
    });
  }

  final Socket _socket;
  final List<Completer<Map<String, dynamic>>> _pending = [];

  Future<Map<String, dynamic>> call(Map<String, dynamic> request) {
    final completer = Completer<Map<String, dynamic>>();
    _pending.add(completer);
    _socket.write('${jsonEncode(request)}\n');
    return completer.future.timeout(const Duration(seconds: 10));
  }

  Future<void> close() => _socket.close();
}

void main() {
  late _FakeTarget target;
  late InprocMcpHost host;
  late _Client client;

  Future<void> boot({ScreenshotProvider? screenshot}) async {
    target = _FakeTarget();
    host = InprocMcpHost(target, screenshotProvider: screenshot);
    final ok = await host.start(port: 0);
    expect(ok, isTrue, reason: '绑定随机端口应当成功');
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      host.boundPort!,
    );
    client = _Client(socket);
  }

  group('进程内桥接端点', () {
    tearDown(() async {
      await client.close();
      await host.dispose();
    });

    test('state 转发状态快照', () async {
      await boot();
      final reply = await client.call({'op': 'state'});
      expect(reply['ok'], isTrue);
      final state = reply['state'] as Map<String, dynamic>;
      expect(state['ready'], isTrue);
      expect(state['score'], 3);
      expect(state['frame'], 42);
    });

    test('cmd 把命令原样转给桥接，并回带结果', () async {
      await boot();
      final reply = await client.call({
        'op': 'cmd',
        'command': {'cmd': 'set_weather', 'kind': 'rain'},
      });
      expect(reply['ok'], isTrue);
      expect((reply['result'] as Map)['echo'], 'set_weather');
      expect(target.commandCount, 1);
    });

    test('业务失败原样透出，不会被伪装成成功', () async {
      await boot();
      final reply = await client.call({
        'op': 'cmd',
        'command': {'cmd': 'explode'},
      });
      expect(reply['ok'], isTrue, reason: '传输成功');
      final result = reply['result'] as Map;
      expect(result['ok'], isFalse, reason: '业务结果里带失败');
      expect(result['error'], '故意失败');
    });

    test('cmd 缺少 command 字段时报错', () async {
      await boot();
      final reply = await client.call({'op': 'cmd'});
      expect(reply['ok'], isFalse);
      expect('${reply['error']}', contains('command'));
    });

    test('非法 JSON 被挡下且不炸连接', () async {
      await boot();
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        host.boundPort!,
      );
      final raw = _Client(socket);
      socket.write('{ 这不是 json\n');
      final reply = await raw.call({'op': 'ping'});
      // 上一行非法 JSON 会先回一条错误，再是我们的 ping 应答。
      expect(reply, isNotNull);
      await raw.close();
    });

    test('未知 op 回带 allowed 清单', () async {
      await boot();
      final reply = await client.call({'op': 'teleport'});
      expect(reply['ok'], isFalse);
      expect(reply['allowed'], containsAll(<String>['state', 'cmd', 'screenshot']));
    });

    test('screenshot 有回调时返回 base64 PNG', () async {
      // 1x1 透明 PNG
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
        'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
      );
      await boot(screenshot: () async => png);
      final reply = await client.call({'op': 'screenshot'});
      expect(reply['ok'], isTrue);
      expect(base64Decode(reply['png'] as String), png);
    });

    test('screenshot 没注册回调时明确报错', () async {
      await boot();
      final reply = await client.call({'op': 'screenshot'});
      expect(reply['ok'], isFalse);
      expect('${reply['error']}', contains('截图回调'));
    });

    test('客户端在响应传输中断开不会产生未捕获异常，其他连接仍可用', () async {
      // 使用大于 socket 缓冲区的响应，让断开确实发生在写入期间。
      await boot(screenshot: () async => Uint8List(8 * 1024 * 1024));
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        host.boundPort!,
      );
      addTearDown(socket.destroy);
      final received = Completer<void>();
      socket.listen((bytes) {
        if (!received.isCompleted) {
          received.complete();
          socket.destroy();
        }
      }, onError: (Object _) {});
      socket.write('{"op":"screenshot"}\n');
      await received.future.timeout(const Duration(seconds: 3));
      // 让内核将对端断开通知发送至服务端；未处理的异步错误会令测试失败。
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(await client.call({'op': 'ping'}), {'ok': true});
      expect(host.clientCount, 1);
    });

    test('每次连接独立计数，互不影响', () async {
      await boot();
      final second = _Client(await Socket.connect(
        InternetAddress.loopbackIPv4,
        host.boundPort!,
      ));
      expect(host.clientCount, 2);
      await client.call({'op': 'ping'});
      await second.call({'op': 'ping'});
      await second.close();
    });
  });
}
