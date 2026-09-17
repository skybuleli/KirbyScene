/// 条件导出：原生（`dart:io` 可用）拿到真实现，Web 拿到空实现。
///
/// 注意这里判的是 `dart.library.io`（原生为真），与 `bridge.dart` 判
/// `dart.library.js_interop`（Web 为真）是相反的方向——两者配合的结果是：
///
/// - **Web**：`GameBridge` 真实现（挂 `window.kirbyMcp`）+ `InprocMcpHost` 空实现
/// - **原生**：`GameBridge` 空实现 + `InprocMcpHost` 真实现（开回环端口）
///
/// 于是 `world.dart` / `main.dart` 可以无条件调用两边，不必写条件导入。
library;

export 'inproc_host_stub.dart' if (dart.library.io) 'inproc_host_io.dart';
