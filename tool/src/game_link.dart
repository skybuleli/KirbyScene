/// 两条通道共同的「游戏连接」接口。
///
/// 传输层差异很大，但对上层工具来说是同一件事：
///
/// | | Web 通道 | macOS 通道 |
/// |---|---|---|
/// | 承载 | Chrome DevTools Protocol | App 内回环 TCP（新行分隔 JSON） |
/// | 读状态 | `Runtime.evaluate("window.kirbyMcp.state")` | `{"op":"state"}` |
/// | 发命令 | `Runtime.evaluate("window.kirbyMcp.cmd(...)")` | `{"op":"cmd","command":{...}}` |
/// | 推进帧 | `await requestAnimationFrame` | 等 App 自己的帧计数前进 |
/// | 抓图 | `Page.captureScreenshot` | `{"op":"screenshot"}`（App 内 RepaintBoundary） |
/// | 控制台 | `Runtime.consoleAPICalled` 事件 | `flutter run` 进程的 stdout |
///
/// 把它抽象出来的收益很直接：**13 个 MCP 工具不需要知道自己在哪条通道上**，
/// 加通道只是多一个实现，不是多一套工具。
library;

import 'dart:typed_data';

/// 一条控制台/异常记录。
class ConsoleEntry {
  ConsoleEntry(this.level, this.text);

  final String level;
  final String text;

  String get line => '[$level] $text';

  /// 从 `flutter run` 的一行原始输出推断级别（原生通道用）。
  factory ConsoleEntry.fromRawLine(String raw) {
    final lower = raw.toLowerCase();
    if (lower.contains('error') || lower.contains('exception')) {
      return ConsoleEntry('error', raw);
    }
    if (lower.contains('warning') || lower.contains('warn')) {
      return ConsoleEntry('warning', raw);
    }
    return ConsoleEntry('log', raw);
  }
}

abstract class GameLink {
  /// 连接是否仍然可用。
  bool get isOpen;

  /// 读一次游戏状态快照；游戏还没就绪时返回 null。
  Future<Map<String, dynamic>?> readState();

  /// 下发一条游戏命令，返回桥接的应答（形如 `{"ok":true,...}`）。
  Future<Map<String, dynamic>> sendCommand(Map<String, dynamic> command);

  /// 推进/等待 [count] 帧。
  ///
  /// 这条不能省：Web 上无头/被遮挡窗口里 rAF 可能一帧都不触发，
  /// 原生上窗口最小化时同理——「工具调了但没反应」多半是帧没推进。
  Future<void> pumpFrames(int count);

  /// 抓取当前视口为 PNG。
  Future<Uint8List> captureScreenshot();

  /// 视口尺寸（宽 / 高 / 设备像素比）。
  Future<Map<String, dynamic>> viewportSize();

  /// 目前缓冲的控制台记录。
  List<ConsoleEntry> get consoleEntries;

  void clearConsole();

  Future<void> dispose();

  /// 给用户看的一句话描述（出现在工具回包里）。
  String describe();
}
