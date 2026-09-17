/// 游戏侧桥接层：把 [BridgeTarget]（即 KirbyWorld）的状态与操作暴露给宿主进程。
///
/// 为什么需要它：
///   - **macOS 通道**：App 进程内可以直接开 TCP 端口跑 MCP 服务器，不需要这层。
///   - **Web 通道**：浏览器里没有 `dart:io`，宿主开不了端口。所以反过来，
///     由页面在 `window.kirbyMcp` 上暴露一个对象，宿主用 Chrome DevTools Protocol
///     的 `Runtime.evaluate` 去读写它。
///
/// 接口刻意做成「一个状态属性 + 一个命令函数」的最小形状，
/// 而不是给每个能力各开一个方法：
///   - 跨 JS 边界的调用越少越稳（尤其无头环境下帧数稀少）；
///   - 加新命令只需改 [BridgeTarget.bridgeCommand] 的分发，不用动这层。
///
/// 条件导出保证同一份代码在原生与 Web 下都能编译：
/// 原生拿到的是空实现（[GameBridge] 全是 no-op）。
library;

export 'bridge_stub.dart' if (dart.library.js_interop) 'bridge_web.dart';

/// 桥接层要求世界实现的能力。
///
/// 之所以定义成接口而不是让桥接层直接引用 `KirbyWorld`：
/// 避免「world → bridge → world」的循环导入，也方便单测里塞假实现。
abstract class BridgeTarget {
  /// 当前状态快照，返回一个 JSON **对象**字符串。
  ///
  /// 实现方必须保证 `player` 等 `late` 字段已就绪时才取值。
  String bridgeStateJson();

  /// 执行一条命令。入参与出参都是 JSON 字符串。
  ///
  /// 约定返回 `{"ok": true, ...}` 或 `{"ok": false, "error": "..."}`，
  /// 且**不要抛异常**——跨 JS 边界抛出会变成难查的静默失败。
  String bridgeCommand(String commandJson);
}
