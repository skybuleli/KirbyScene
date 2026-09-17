/// macOS 通道传输层的**对通测试**：真实的 App 侧端点 ↔ 真实的宿主侧客户端。
///
/// 为什么要有这个：macOS 通道的两半分别写在 `lib/mcp/inproc_host_io.dart`（App 内）
/// 和 `tool/src/native_session.dart`（宿主侧）。它们只有在真的 App 跑起来时才会见面，
/// 而 App 启动依赖完整 Xcode + 不受限的环境。与其"等下次手测才发现协议对不上"，
/// 不如让这两半直接在网上对通——协议错了这里就会红。
///
/// 唯一测不到的只剩「拉起 flutter run -d macos」这一步，那部分由环境负责。
library;
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kirby_scene/mcp/bridge.dart';
import 'package:kirby_scene/mcp/inproc_host_io.dart';

import '../tool/src/native_session.dart';

/// 假游戏目标：帧计数每次被读就前进，模拟"游戏正在跑"。
class _TickingTarget implements BridgeTarget {
  int _frames = 100;
  int commandCount = 0;

  int get frames => _frames;

  @override
  String bridgeStateJson() => jsonEncode({
        'ready': true,
        'score': 1,
        'frame': _frames++,
        'weather': 'clear',
      });

  @override
  String bridgeCommand(String commandJson) {
    commandCount++;
    final request = jsonDecode(commandJson) as Map<String, dynamic>;
    if (request['cmd'] == 'bad') {
      return jsonEncode({'ok': false, 'error': '不支持的命令'});
    }
    return jsonEncode({'ok': true, 'handled': request['cmd']});
  }
}

/// 1x1 透明 PNG，用来验证截图往返。
final Uint8List _kOnePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
  'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

void main() {
  late _TickingTarget target;
  late InprocMcpHost host;
  late NativeLink link;

  setUp(() async {
    target = _TickingTarget();
    host = InprocMcpHost(target, screenshotProvider: () async => _kOnePixelPng);
    // 端口传 0：由系统分配，绝不和真正在跑的游戏抢 7008。
    expect(await host.start(port: 0), isTrue);
    link = await NativeLink.connect(port: host.boundPort!);
  });

  tearDown(() async {
    await link.dispose();
    await host.dispose();
  });

  group('macOS 传输层对通', () {
    test('readState 穿透两层拿到状态', () async {
      final state = await link.readState();
      expect(state, isNotNull);
      expect(state!['ready'], isTrue);
      expect(state['weather'], 'clear');
    });

    test('sendCommand 往返并保留业务结果', () async {
      final result = await link.sendCommand({'cmd': 'set_weather'});
      expect(result['ok'], isTrue);
      expect(result['handled'], 'set_weather');
      expect(target.commandCount, 1);
    });

    test('业务失败以 ok:false 返回，而不是抛异常', () async {
      // 这条很关键：桥接把业务失败编码在结果里，
      // 客户端要原样透出给工具层，不能当成传输错误。
      final result = await link.sendCommand({'cmd': 'bad'});
      expect(result['ok'], isFalse);
      expect('${result['error']}', contains('不支持的命令'));
    });

    test('captureScreenshot 拿到与 App 侧一致的 PNG 字节', () async {
      final bytes = await link.captureScreenshot();
      expect(bytes, _kOnePixelPng);
    });

    test('pngSize 能从真实 PNG 解出宽高', () async {
      final size = pngSize(_kOnePixelPng);
      expect(size['w'], 1);
      expect(size['h'], 1);
    });

    test('pumpFrames 等到帧计数前进', () async {
      final before = target.frames;
      await link.pumpFrames(5);
      expect(target.frames, greaterThanOrEqualTo(before + 5));
    });

    test('并发请求不会串台（FIFO 配对）', () async {
      // 协议没有 id，靠顺序配对。并发下如果配对错了，这里的数量会明显不符。
      final results = await Future.wait([
        link.sendCommand({'cmd': 'a'}),
        link.sendCommand({'cmd': 'b'}),
        link.sendCommand({'cmd': 'c'}),
      ]);
      expect(results.map((r) => r['handled']).toList(), ['a', 'b', 'c']);
    });

    test('isOpen / describe 反映连接状态', () async {
      expect(link.isOpen, isTrue);
      expect(link.describe(), contains('原生通道'));
    });

    test('连不上不存在的端口时给出可读错误', () async {
      // 用 1 号端口：特权端口，必然没人监听，连接会被立刻拒绝。
      await expectLater(
        NativeLink.connect(port: 1, timeout: const Duration(seconds: 2)),
        throwsA(isA<StateError>()),
      );
    });
  });
}
