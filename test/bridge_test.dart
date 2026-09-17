/// 桥接层与 MCP 工具表的测试。
///
/// 分两组：
///   - **游戏侧**：`KirbyWorld` 作为 [BridgeTarget] 的命令分发行为。
///     不需要 GPU——只测「未就绪 / 参数非法 / 未知命令」这些纯逻辑路径，
///     因为 `world.initialize()` 要 Flutter GPU 上下文，测试环境跑不了。
///   - **宿主侧**：MCP 工具表的 schema 形状。这类问题一旦漏掉，
///     表现是「客户端连上但看不到工具」，很难从日志里看出来。
library;
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kirby_scene/game/world.dart';

import '../tool/kirby_mcp.dart' as mcp;

void main() {
  group('游戏侧桥接（KirbyWorld implements BridgeTarget）', () {
    late KirbyWorld world;

    setUp(() => world = KirbyWorld());

    test('未就绪时状态快照只报告 ready:false', () {
      final state = _call(world, '{"cmd":"capabilities"}');
      expect(state['ok'], isTrue);
      expect(state['ready'], isFalse);

      final snapshot = _snapshot(world);
      expect(snapshot['ready'], isFalse);
      // 未就绪时不能去读 player / controller（late final 会抛），
      // 所以这些字段根本不该出现。
      expect(snapshot.containsKey('position'), isFalse);
    });

    test('非法 JSON 被挡下，而不是抛异常', () {
      final result = _call(world, '{ 这不是 json');
      expect(result['ok'], isFalse);
      expect('${result['error']}', contains('invalid JSON'));
    });

    test('顶层不是对象时报错', () {
      final result = _call(world, '"set_weather"');
      expect(result['ok'], isFalse);
      expect('${result['error']}', contains('JSON object'));
    });

    test('缺少 cmd 时报错', () {
      final result = _call(world, '{"kind":"rain"}');
      expect(result['ok'], isFalse);
      expect('${result['error']}', contains('cmd'));
    });

    test('未知命令会回带可用命令清单', () {
      final result = _call(world, '{"cmd":"launch_missiles"}');
      expect(result['ok'], isFalse);
      expect(result['allowed'], contains('set_weather'));
    });

    test('未就绪时业务命令被拒绝', () {
      final result = _call(world, '{"cmd":"set_weather","kind":"rain"}');
      expect(result['ok'], isFalse);
      expect('${result['error']}', contains('not ready'));
    });

    test('capabilities 在未就绪时也可用（供宿主自检）', () {
      final result = _call(world, '{"cmd":"capabilities"}');
      expect(result['ok'], isTrue);
      expect(result['commands'], contains('teleport'));
      expect(result['keys'], contains('KeyW'));
      expect(
        result['weathers'],
        containsAll(<String>['clear', 'cloudy', 'rain']),
      );
    });

    test('命令清单覆盖全部玩法开关', () {
      // 漏一个就意味着 MCP 少一个能力入口。
      expect(
        KirbyWorld.bridgeCommands,
        containsAll(<String>[
          'set_weather',
          'restart',
          'set_camera',
          'teleport',
          'hold_keys',
          'release_keys',
          'jump',
          'set_demo',
        ]),
      );
    });
  });

  group('宿主侧 MCP 工具表', () {
    late List<mcp.ToolSpec> tools;

    setUpAll(() => tools = mcp.KirbyMcpServer().tools);

    test('工具名唯一且非空', () {
      final names = tools.map((t) => t.name).toList();
      expect(names.toSet().length, names.length);
      expect(names.every((n) => n.isNotEmpty), isTrue);
    });

    test('每个工具都有描述（客户端靠它决定要不要调）', () {
      for (final tool in tools) {
        expect(tool.description.trim(), isNotEmpty, reason: tool.name);
      }
    });

    test('每个工具的 inputSchema 都是带 properties 的 object', () {
      // 缺 properties 的 schema 会被部分客户端直接拒绝，这条不能省。
      for (final tool in tools) {
        expect(tool.schema['type'], 'object', reason: tool.name);
        expect(tool.schema['properties'], isA<Map>(), reason: tool.name);
      }
    });

    test('required 里的字段都真实存在于 properties', () {
      for (final tool in tools) {
        final required = tool.schema['required'];
        if (required is! List) continue;
        final properties = tool.schema['properties'] as Map;
        for (final key in required) {
          expect(
            properties.containsKey(key),
            isTrue,
            reason: '${tool.name} 的 required 里出现了未声明的 "$key"',
          );
        }
      }
    });

    test('覆盖官方 flutter_scene_mcp 的五个工具名', () {
      // 对齐官方命名的意义：将来真接上官方编辑器 MCP 时，调用侧不用改。
      final names = tools.map((t) => t.name).toSet();
      expect(
        names,
        containsAll(<String>[
          'build_project',
          'run_project',
          'hot_reload',
          'get_console',
          'screenshot_viewport',
        ]),
      );
    });

    test('每个工具都能序列化成 MCP 要求的形状', () {
      for (final tool in tools) {
        final json = tool.toJson();
        expect(json['name'], tool.name);
        expect(json['description'], isA<String>());
        expect(json['inputSchema'], isA<Map>());
      }
    });
  });
}

/// 把 JSON 字符串喂给桥接并解回 Map，断言里读起来干净些。
Map<String, dynamic> _call(KirbyWorld world, String commandJson) =>
    jsonDecode(world.bridgeCommand(commandJson)) as Map<String, dynamic>;

Map<String, dynamic> _snapshot(KirbyWorld world) =>
    jsonDecode(world.bridgeStateJson()) as Map<String, dynamic>;
