/// 程序化卡比角色：全部由内置几何体拼装，不依赖任何美术资产。
///
/// 造型拆解（都挂在同一个根节点下，根节点的 transform 由控制器驱动）：
///   - 身体        : 一个大球
///   - 脚 ×2       : 压扁的球，深红色（卡比标志性的圆脚）
///   - 手 ×2       : 小球，粉色
///   - 眼睛 ×2     : 竖直拉长的椭球 + 高光小点，朝 +Z（角色正面）
///   - 腮红 ×2     : 压扁的小球
///
/// 朝向约定：角色正面朝 **+Z**。若接入控制器后发现模型背对前进方向，
/// 只需调整 [buildKirbyNode] 里各部件的 z 符号，不要改控制器。

library;
import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// 卡比的配色（sRGB）。
/// 注意：`vector_math` 的向量类型不是 const 构造，所以这里是顶层 final 而非 const。
final _pink = vm.Vector4(1.00, 0.62, 0.77, 1.0);
final _pinkDeep = vm.Vector4(0.96, 0.48, 0.66, 1.0);
final _red = vm.Vector4(0.86, 0.24, 0.33, 1.0);
final _dark = vm.Vector4(0.07, 0.07, 0.11, 1.0);
final _white = vm.Vector4(1.0, 1.0, 1.0, 1.0);

PhysicallyBasedMaterial _mat(vm.Vector4 color, {double roughness = 0.55, double emissive = 0}) {
  final m = PhysicallyBasedMaterial()
    ..baseColorFactor = color
    ..roughnessFactor = roughness
    ..metallicFactor = 0.0;
  if (emissive > 0) {
    m.emissiveFactor =
        vm.Vector4(color.r * emissive, color.g * emissive, color.b * emissive, 1.0);
  }
  return m;
}

/// 拼出一个卡比节点。返回的根节点带有 `body` 名称，便于后续做动画。
Node buildKirbyNode() {
  final root = Node(name: 'kirby');

  final bodyMat = _mat(_pink, roughness: 0.45);

  // ---- 身体 ----
  root.add(Node(
    name: 'body',
    mesh: Mesh(SphereGeometry(radius: 0.55, segments: 28, rings: 20), bodyMat),
  ));

  // ---- 脚 ----
  final footGeo = SphereGeometry(radius: 0.21, segments: 18, rings: 12);
  final footMat = _mat(_red, roughness: 0.5);
  for (final side in [-1.0, 1.0]) {
    final foot = Node(
      name: side < 0 ? 'foot_l' : 'foot_r',
      mesh: Mesh(footGeo, footMat),
    );
    foot.position = vm.Vector3(0.26 * side, -0.44, 0.05);
    foot.scale = vm.Vector3(1.0, 0.62, 1.35); // 压扁拉长 → 圆脚
    root.add(foot);
  }

  // ---- 手 ----
  final handGeo = SphereGeometry(radius: 0.18, segments: 16, rings: 12);
  for (final side in [-1.0, 1.0]) {
    final hand = Node(
      name: side < 0 ? 'hand_l' : 'hand_r',
      mesh: Mesh(handGeo, bodyMat),
    );
    hand.position = vm.Vector3(0.54 * side, -0.02, 0.10);
    hand.scale = vm.Vector3(1.0, 0.9, 1.0);
    root.add(hand);
  }

  // ---- 眼睛（朝 +Z）----
  final eyeGeo = SphereGeometry(radius: 0.105, segments: 16, rings: 12);
  final eyeMat = _mat(_dark, roughness: 0.25, emissive: 0.05);
  final glintGeo = SphereGeometry(radius: 0.038, segments: 10, rings: 8);
  final glintMat = _mat(_white, roughness: 0.1, emissive: 0.6);
  for (final side in [-1.0, 1.0]) {
    final eye = Node(
      name: side < 0 ? 'eye_l' : 'eye_r',
      mesh: Mesh(eyeGeo, eyeMat),
    );
    eye.position = vm.Vector3(0.185 * side, 0.16, 0.44);
    eye.scale = vm.Vector3(1.0, 1.6, 0.75); // 竖直拉长
    root.add(eye);

    final glint = Node(mesh: Mesh(glintGeo, glintMat));
    glint.position = vm.Vector3(0.19 * side + 0.03 * side, 0.24, 0.55);
    root.add(glint);
  }

  // ---- 腮红 ----
  final cheekGeo = SphereGeometry(radius: 0.085, segments: 14, rings: 10);
  final cheekMat = _mat(_pinkDeep, roughness: 0.6, emissive: 0.15);
  for (final side in [-1.0, 1.0]) {
    final cheek = Node(mesh: Mesh(cheekGeo, cheekMat));
    cheek.position = vm.Vector3(0.30 * side, -0.06, 0.40);
    cheek.scale = vm.Vector3(1.3, 0.8, 0.4);
    root.add(cheek);
  }

  return root;
}

/// 收集物：一颗会自转、上下浮动的金色发光星核。
Node buildPickupNode({required int index}) {
  final node = Node(name: 'pickup_$index');
  final core = Node(
    mesh: Mesh(
      IcosphereGeometry(radius: 0.32, subdivisions: 1),
      // 刻意不加自发光：在没有泛光后端的平台上，emissive 只会把颜色推到纯白，
      // 反而丢掉"金色"这个关键识别信息。靠饱和的基色 + ACES 调色来突出。
      _mat(vm.Vector4(1.0, 0.76, 0.16, 1.0), roughness: 0.3),
    ),
  );
  node.add(core);

  // 外圈光环，增加可读性（远远就能看到）。
  final ring = Node(
    mesh: Mesh(
      TorusGeometry(radius: 0.5, tubeRadius: 0.045, radialSegments: 8, tubularSegments: 24),
      _mat(vm.Vector4(0.98, 0.70, 0.12, 1.0), roughness: 0.35),
    ),
  );
  ring.scale = vm.Vector3(1.0, 1.0, 1.0);
  node.add(ring);

  return node;
}

/// 把收集物的自转/浮动写进节点（在每帧 tick 里调用）。
void animatePickup(Node node, double time, double baseHeight, {double phase = 0}) {
  final bob = math.sin(time * 1.8 + phase) * 0.22;
  node.position = vm.Vector3(node.position.x, baseHeight + bob, node.position.z);
  node.rotation = vm.Quaternion.euler(0, time * 1.1 + phase, 0);
}
