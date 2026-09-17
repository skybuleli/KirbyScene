/// 轻量第三人称角色控制器。
///
/// 为什么不用 `kit` 的 `ThirdPersonControllerComponent`：
///  1. 它的地面检测走**场景射线**，需要 mesh 的 raycast 支持；
///  2. 它必须处于引擎的 mounted/loaded 时序里才会被驱动
///     （`addComponent` 时节点必须已经在 RenderScene 中），
///     这条时序在 Web / 无头抓帧环境下不可靠。
///
/// 实测这两点在 Web 上表现为"角色能转向、但位置原地不动"。
///
/// 而本关卡的地形本来就是**解析高度场**（`Terrain.heightAt`），
/// 直接采样地形高度比射线更快、更确定，也免掉了 collider 依赖。
/// 内置组件的其余能力（`SpringArmComponent` 防穿墙相机、`CameraShake`、
/// `Steering` 群集、`NodePool`）留待后续阶段接入，它们不依赖组件 tick 时序。

library;
import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'terrain.dart';

class PlayerController {
  PlayerController({required this.node, required this.terrain});

  final Node node;
  final Terrain terrain;

  double walkSpeed = 6.5;
  double runMultiplier = 1.8;
  double jumpVelocity = 8.5;
  double gravity = 22.0;

  /// 转身速度（弧度/秒 的比例系数，越大转得越快）。
  double turnSpeed = 12.0;

  double _verticalVelocity = 0;

  /// 当前朝向（绕 Y 轴弧度；角色正面朝 +Z）。
  double _facing = 0;

  bool _airborne = false;
  bool get isAirborne => _airborne;

  /// 当前朝向（绕 Y 轴弧度）。暴露出来供 HUD / MCP 验证转向是否生效。
  double get facing => _facing;

  /// 控制器最后写入的位置（诊断用：与 `node.position` 对照，
  /// 可判断是逻辑没跑还是写进节点后没生效）。
  double debugX = 0;
  double debugZ = 0;
  int updateCount = 0;

  /// 距地面的高度，供 HUD / 调试显示。
  double get heightAboveGround => node.position.y - terrain.heightAt(node.position.x, node.position.z);

  /// 推进一帧。
  ///
  /// [moveAxis] 是归一化平面输入（x = 右，y = 前），
  /// [cameraYaw] 让移动方向相对相机，这是第三人称的标准手感。
  void update(
    double dt, {
    required vm.Vector2 moveAxis,
    required bool running,
    required double cameraYaw,
    required bool jump,
  }) {
    final p = node.position;

    // ---- 水平移动：把输入按相机偏航角旋转到世界方向 ----
    final speed = running ? walkSpeed * runMultiplier : walkSpeed;
    final sinY = math.sin(cameraYaw);
    final cosY = math.cos(cameraYaw);

    // 相机的两个水平基向量。**依据引擎源码，不要凭图形学常识推导**：
    // 见 flutter_scene 的 `camera.dart` 里 `_matrix4LookAt`：
    //
    //   forward = (target - position).normalized()
    //   right   = up.cross(forward)          ← 注意是 up × forward
    //
    // 标准图形学写的是 `forward × up`，两者**恰好差一个负号**。
    // flutter_scene 用的是 up × forward，所以屏幕右方与直觉相反。
    //
    // 代入本工程的相机位置公式 target + (cosP*sinY, sinP, cosP*cosY)*d：
    //   forward = (-sinY, -cosY)            ← 屏幕"前"
    //   right   = up × forward = (-cosY, +sinY)  ← 屏幕"右"
    //
    // 移动方向 = 输入.x * right + 输入.y * forward：
    //   dirX = -x*cosY - y*sinY
    //   dirZ =  x*sinY - y*cosY
    //
    // ⚠️ 这里曾经反复改错（前后三次），把教训记下来：
    //  1) 初版 y 项符号反了（+y*sinY / +y*cosY）→ W/S 前后颠倒；
    //  2) 修 y 项后 A/D 左右颠倒 → 因为 x 项也需按 up×forward 取负；
    //  3) 曾用"看截图里背景往哪边移"的方法判断屏幕左右，得出"+X 是屏幕右"
    //     的错误结论（相机跟随时视差判据不可靠），又把 x 项改回去了。
    // **教训**：屏幕左右不应靠截图目测推断，直接查 `camera.dart` 的
    // `_matrix4LookAt` 即可一锤定音。
    final dirX = -moveAxis.x * cosY - moveAxis.y * sinY;
    final dirZ = moveAxis.x * sinY - moveAxis.y * cosY;

    // 限制在地形范围内，避免跑出网格边缘掉进虚空。
    final limit = terrain.halfExtent - 4.0;
    final x = (p.x + dirX * speed * dt).clamp(-limit, limit);
    final z = (p.z + dirZ * speed * dt).clamp(-limit, limit);

    // ---- 垂直：跳跃 + 重力 + 地面吸附 ----
    final groundY = terrain.heightAt(x, z);

    if (jump && !_airborne) {
      _verticalVelocity = jumpVelocity;
      _airborne = true;
    }

    _verticalVelocity -= gravity * dt;
    var y = p.y + _verticalVelocity * dt;

    if (y <= groundY) {
      // 落地：吸附到地形表面并清掉垂直速度。
      y = groundY;
      _verticalVelocity = 0;
      _airborne = false;
    }

    // ---- 朝向：平滑转向移动方向 ----
    if (moveAxis.length2 > 1e-4) {
      // 角色正面是 +Z，绕 Y 转 θ 后 +Z → (sinθ, 0, cosθ)，
      // 因此目标朝向角就是 atan2(dirX, dirZ)。
      final target = math.atan2(dirX, dirZ);
      var delta = target - _facing;
      // 取最短转向路径，避免绕远路。
      while (delta > math.pi) {
        delta -= math.pi * 2;
      }
      while (delta < -math.pi) {
        delta += math.pi * 2;
      }
      _facing += delta * math.min(1.0, turnSpeed * dt);
    }

    // ---- 位置与朝向一次性写入 localTransform ----
    //
    // 不用 `node.position = ...` / `node.rotation = ...` 两次赋值：
    // 那两次都会各自重建整条本地矩阵，等于把对方覆盖掉。整体 compose
    // 一次写入更可靠，也避免读回 position 时拿到未刷新的值。
    _facingQuaternion.setAxisAngle(_upAxis, _facing);
    node.localTransform = vm.Matrix4.compose(
      vm.Vector3(x, y, z),
      _facingQuaternion,
      _scaleOne,
    );

    debugX = x;
    debugZ = z;
    updateCount++;
  }

  final vm.Quaternion _facingQuaternion = vm.Quaternion.identity();
  final vm.Vector3 _upAxis = vm.Vector3(0, 1, 0);
  final vm.Vector3 _scaleOne = vm.Vector3.all(1.0);

  /// 放回指定平面位置并贴合地面（重开 / 传送用）。
  void placeAt(double x, double z) {
    final y = terrain.heightAt(x, z);
    node.position = vm.Vector3(x, y, z);
    _verticalVelocity = 0;
    _airborne = false;
  }
}
