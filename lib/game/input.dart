/// 键盘输入状态。
///
/// 只做"按键 → 语义"的翻译，不碰引擎：`KirbyWorld` 每帧读取它，
/// 再喂给 `ThirdPersonControllerComponent`。
///
/// 跳跃用"本帧按下"的边沿触发（而不是按住持续跳），并且只在被消费后清除，
/// 避免高帧率下同一次按压被重复触发。

library;
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:vector_math/vector_math.dart' as vm;

class GameInput {
  final Set<LogicalKeyboardKey> _held = <LogicalKeyboardKey>{};

  /// 需要边沿触发的按键（按下的那一帧为 true）。
  final Set<LogicalKeyboardKey> _pressedThisFrame = <LogicalKeyboardKey>{};

  /// 虚拟按键：供自动演示 / 后续 MCP 远程操控注入输入，与真实键盘共用同一条路径。
  final Set<LogicalKeyboardKey> _virtual = <LogicalKeyboardKey>{};

  /// 注入或释放一个虚拟按键。
  void setVirtual(LogicalKeyboardKey key, bool down) {
    if (down) {
      _virtual.add(key);
    } else {
      _virtual.remove(key);
    }
  }

  void clearVirtual() => _virtual.clear();

  void handleKeyEvent(KeyEvent event) {
    final key = event.logicalKey;
    if (event is KeyDownEvent) {
      _pressedThisFrame.add(key);
      _held.add(key);
    } else if (event is KeyRepeatEvent) {
      // 系统的按住自动重复：保持"按住"状态，但不算作新的按下，
      // 否则按住空格会疯狂起跳。
      _held.add(key);
    } else if (event is KeyUpEvent) {
      _held.remove(key);
    }
  }

  /// 窗口失焦时清空，防止"按着键切走"导致角色一直跑。
  void clear() {
    _held.clear();
    _pressedThisFrame.clear();
    _virtual.clear();
  }

  bool _isHeld(LogicalKeyboardKey key) =>
      _held.contains(key) || _virtual.contains(key);

  bool _any(List<LogicalKeyboardKey> keys) => keys.any(_isHeld);

  bool get isForward => _any(_forwardKeys);
  bool get isBack => _any(_backKeys);
  bool get isLeft => _any(_leftKeys);
  bool get isRight => _any(_rightKeys);
  bool get isRun => _any(_runKeys);

  static const _forwardKeys = [LogicalKeyboardKey.keyW, LogicalKeyboardKey.arrowUp];
  static const _backKeys = [LogicalKeyboardKey.keyS, LogicalKeyboardKey.arrowDown];
  static const _leftKeys = [LogicalKeyboardKey.keyA, LogicalKeyboardKey.arrowLeft];
  static const _rightKeys = [LogicalKeyboardKey.keyD, LogicalKeyboardKey.arrowRight];
  static const _runKeys = [LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.shiftRight];

  /// 归一化的平面移动向量：x = 右, y = 前。符合控制器约定（+Y 为前）。
  vm.Vector2 get moveAxis {
    var x = 0.0;
    var y = 0.0;
    if (isRight) x += 1.0;
    if (isLeft) x -= 1.0;
    if (isForward) y += 1.0;
    if (isBack) y -= 1.0;

    final len = math.sqrt(x * x + y * y);
    if (len > 1.0) {
      x /= len;
      y /= len;
    }
    return vm.Vector2(x, y);
  }

  bool _virtualJumpQueued = false;

  /// 注入一次跳跃（虚拟输入 / 自动演示用；与真实按键走同一条消费路径）。
  void queueJump() => _virtualJumpQueued = true;

  /// 本帧是否有跳跃请求（读取即消费，保证一次按压只跳一次）。
  bool consumeJump() {
    final pressed =
        _pressedThisFrame.remove(LogicalKeyboardKey.space) || _virtualJumpQueued;
    _virtualJumpQueued = false;
    return pressed;
  }

  /// 本帧是否按下了某个键（不消费，用于切换类按键的边沿判断）。
  bool pressedNow(LogicalKeyboardKey key) => _pressedThisFrame.contains(key);

  /// 帧末清理：本帧的"刚按下"集合只活一帧。
  void endFrame() => _pressedThisFrame.clear();
}
