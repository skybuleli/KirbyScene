/// 桥接层的**原生占位实现**（macOS / Windows / Linux 构建走这里）。
///
/// 桌面通道下 MCP 服务器跑在 App 进程内（见 CellScene 的 cell_mcp_host 做法），
/// 不需要经由 JS，所以这里全是空操作——保留同名 API 只是为了让
/// `world.dart` / `main.dart` 不必写条件导入。
library;

import 'bridge.dart';

class GameBridge {
  /// 原生通道下无需挂接；保留参数是为了签名一致。
  static void attach(BridgeTarget target) {}

  /// 发布状态快照——原生通道由 MCP 服务器直接读内存，这里什么都不做。
  static void publish(String stateJson) {}
}
