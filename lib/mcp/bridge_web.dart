/// 桥接层的 **Web 实现**：在页面里挂出 `window.kirbyMcp`。
///
/// 形状刻意保持最小：
///   - `window.kirbyMcp.state` —— 一个 JSON **字符串属性**，每帧刷新。
///     宿主用 `Runtime.evaluate("window.kirbyMcp.state")` 读它。
///     做成属性而不是回调，是因为读状态是高频操作，
///     属性求值不需要注册/注销回调，也不怕宿主中途重连。
///   - `window.kirbyMcp.cmd(json)` —— 一个**同步**函数，入参出参都是 JSON 字符串。
///     做成同步是因为 CDP 的 `Runtime.evaluate` 支持 `awaitPromise`，
///     但同步返回少一次跨边界往返，在帧数稀少的无头环境里更可靠。
///
/// 这里只做「透传」，所有命令语义都在 [BridgeTarget] 的实现里
/// （即 `KirbyWorld.bridgeCommand`），这样命令集可以随玩法扩展而不用动这层。
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'bridge.dart';

@JS('window')
external JSObject get _window;

/// 挂在 `window` 上的全局对象名（宿主脚本按这个名字找）。
const String kBridgeGlobalName = 'kirbyMcp';

BridgeTarget? _target;

class GameBridge {
  /// 把 [target] 挂到 `window.kirbyMcp`。重复调用会覆盖旧目标（热重载友好）。
  static void attach(BridgeTarget target) {
    _target = target;

    final api = JSObject();
    api['state'] = '{}'.toJS;
    api['cmd'] = _handleCommand.toJS;
    _window[kBridgeGlobalName] = api;
  }

  /// 刷新状态快照。每帧调用；[stateJson] 必须是一个 JSON 对象字符串。
  static void publish(String stateJson) {
    final api = _window[kBridgeGlobalName];
    if (api == null) return;
    (api as JSObject)['state'] = stateJson.toJS;
  }

  /// 命令入口：JS 侧调用 `window.kirbyMcp.cmd('{"cmd":"..."}')`。
  ///
  /// 全程不抛异常——跨 JS 边界抛出会变成控制台里一条难定位的静默失败，
  /// 所以异常在这里就地转成 `{"ok": false, "error": ...}`。
  static JSString _handleCommand(JSString raw) {
    final target = _target;
    if (target == null) {
      return jsonEncode({'ok': false, 'error': 'bridge not attached'}).toJS;
    }

    String result;
    try {
      result = target.bridgeCommand(raw.toDart);
    } catch (e) {
      result = jsonEncode({'ok': false, 'error': 'command threw: $e'});
    }
    return result.toJS;
  }
}
