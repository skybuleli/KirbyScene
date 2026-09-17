/// Web 构建下的占位实现。
///
/// 浏览器里没有 `dart:io`，开不了监听端口。Web 通道改由页面内
/// `window.kirbyMcp` + Chrome DevTools Protocol 承载（见 `bridge_web.dart`）。
///
/// 这里保留同名同签名的 API，只是全部空转，这样 `main.dart` 不需要条件导入。
library;

import 'dart:typed_data';

import 'bridge.dart';

/// 与原生实现保持同一个常量（Web 下不会真的用到）。
const int kKirbyInprocPort = 7008;

/// 截图回调签名（与原生实现一致）。
typedef ScreenshotProvider = Future<Uint8List?> Function();

class InprocMcpHost {
  InprocMcpHost(this.target, {this.screenshotProvider});

  final BridgeTarget target;
  final ScreenshotProvider? screenshotProvider;

  bool get isRunning => false;
  int? get boundPort => null;
  int get clientCount => 0;

  /// Web 下永远不监听。
  Future<bool> start({int port = kKirbyInprocPort}) async => false;

  Future<void> dispose() async {}
}
