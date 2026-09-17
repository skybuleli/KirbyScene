/// 程序化地形：噪声高度场 → 三角网格，并提供 [heightAt] 供角色、草与道具共用同一份地形。
///
/// 关键约定：**所有东西都必须用同一个 [heightAt] 决定 y 坐标**。地形网格、草叶落点、
/// 收集物高度、角色地面吸附如果各自算一遍，就会出现悬空或陷地的经典 bug。
///
/// 顶点色（`GeometryBuilder.color` 是 sticky 的）承担"按高度分层配色"，
/// `PhysicallyBasedMaterial.vertexColorWeight` 默认为 1.0，因此顶点色会被自动采用。

library;
import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'noise.dart';
import 'river.dart';

class Terrain {
  Terrain({
    this.halfExtent = 75.0,
    this.cols = 120,
    this.rows = 120,
    River? river,
    this.carveRiver = true,
    int seed = 20260914,
  })  : noise = ValueNoise(seed: seed),
        river = river ?? const River();

  /// 地形从 -halfExtent 延伸到 +halfExtent（正方形）。
  final double halfExtent;
  final int cols;
  final int rows;
  final ValueNoise noise;

  /// 河道。所有地形查询都会经过它（河谷雕刻），因此草/石/树的落点与
  /// 水面用的是同一个高度场，不会出现"水里有草""岸上悬空"这类错位。
  final River river;

  /// 是否雕刻河谷。
  ///
  /// 关掉它得到"没有河的高度场"——测试里用它做对照（注意：只把
  /// [River.valleyRadius] 调小是**不能**关掉雕刻的，河心照样会被切平，
  /// 这个坑实测踩过）。将来做"无河流关卡"时也用得上。
  final bool carveRiver;

  /// 河床相对两侧地形的下切深度（米）。
  ///
  /// 4.2m 配 0.8m 水深、15m 河谷半径 → 水面大约覆盖河道两侧各 5–7m，
  /// 整条河约 10–14m 宽。下切过浅会让水面漫出十几米（读成湖而不是河），
  /// 这是实测调出来的组合（3.4m + 19m 时最宽处水面有 14m 半宽）。
  static const double channelIncise = 4.2;

  /// 中央保留的平缓玩法区半径；这里是关卡的主战场。
  /// 不宜过大：太大会让玩家在视野里看不到任何起伏，草原会显得像一块平板。
  static const double playRadius = 17.0;

  /// 从平缓区过渡到自然地形的宽度。
  static const double flatFalloff = 22.0;

  /// 网格间距。
  double get spacing => (halfExtent * 2) / (cols - 1);

  /// 采样任意世界坐标的地形高度。
  ///
  /// 分层依次是：大尺度起伏 → 侵蚀冲沟 → 细部土块 → 中央压平 → 河谷雕刻。
  /// 顺序有意义：中央压平必须吃掉前面所有高频，否则玩法区会变得坑洼；
  /// 河谷雕刻放最后，保证河道不被别的步骤填回去。
  double heightAt(double x, double z) {
    // 偏移避免噪声在原点对称（值噪声在整数格点上有规律）。
    final nx = x * 0.018 + 137.0;
    final nz = z * 0.018 + 311.0;

    // 大尺度缓坡 + 脊状噪声做山脊/崖壁。
    final rolling = noise.fbm2(nx, nz, octaves: 5) * 5.5;
    final ridges = noise.ridged2(nx * 0.55, nz * 0.55, octaves: 4) * 9.0;
    var h = rolling + ridges * 0.55;

    // 侵蚀冲沟：高频脊状噪声只加在"起伏大"的地方。
    // 平地上（|h| 小）权重为 0 —— 否则整片草原会变成搓板；
    // 这是廉价但有效的侵蚀近似（真侵蚀要迭代水流模拟，这里没必要）。
    final roughness = ((h.abs() - 1.5) / 6.0).clamp(0.0, 1.0);
    final gullies = noise.ridged2(nx * 3.1 + 5.0, nz * 3.1 - 7.0, octaves: 3);
    h += gullies * 0.85 * roughness;

    // 细部起伏：让近处地面有土块感，而不是光滑的噪声曲面。
    h += noise.fbm2(nx * 7.5, nz * 7.5, octaves: 2) * 0.22;

    // 中央压平：给玩法一个舒服的场地，外围保留起伏与山峰。
    final d = math.sqrt(x * x + z * z);
    final t = ((d - playRadius) / flatFalloff).clamp(0.0, 1.0);
    final eased = t * t * (3.0 - 2.0 * t); // smoothstep，避免出现硬边台阶
    h *= eased;

    // 河谷雕刻：把河床"按下去"，再向外用 smootherstep 平滑抬升回原地形。
    // 河床取「坡降基准」与「局部地形 − 下切深度」的较小值 →
    // 两侧地形低时下切浅、高时下切深，河道深浅自然变化，
    // 同时保证水面永远低于两岸（不会出现"河在山脊上悬空流"的笑话）。
    if (!carveRiver) return h;

    final riverDist = river.distanceToCenter(x, z);
    if (riverDist < river.valleyRadius * 1.25) {
      // 河谷宽度与下切深度用低频噪声扰动：真实的河不会是等宽的槽 ——
      // 一侧缓（凸岸、沉积、浅滩），另一侧陡（凹岸、侵蚀、深潭）。
      // 这一步是"河岸不对称"的来源，也是避免人工感的 cheapest 手段。
      final wobble = noise.fbm2(x * 0.035 + 3.3, z * 0.055 - 1.7, octaves: 2);
      final wobble01 = wobble * 0.5 + 0.5;
      final valleyR = river.valleyRadius * (0.9 + 0.35 * wobble01);
      final incise = channelIncise * (0.95 + 0.3 * wobble01);

      if (riverDist < valleyR) {
        final bed = math.min(river.bedRamp(z), h - incise);
        final carved = bed + (h - bed) * river.valleyWeightAt(riverDist / valleyR);

        // **玩法区保护**：离原点近的地方按 smoothstep 减弱雕刻。
        // 河谷影响半径可达 22m，而河道最近处离原点 23m —— 不保护的话，
        // 场地边缘会被河谷的平滑抬升"啃"出一圈缓坡，玩法区不再是平地。
        // 保护带从 13m 渐入、20m 成全，正好在河道最内侧岸线之外。
        final g = ((d - 13.0) / 7.0).clamp(0.0, 1.0);
        final guard = g * g * (3.0 - 2.0 * g);
        h += (carved - h) * guard;
      }
    }

    return h;
  }

  /// 地形法线（由高度场差分得到），用于把草叶/石块贴合坡面。
  ///
  /// eps 默认 0.8m（比细部噪声的波长略大）：eps 太小会把土块级的高频
  /// 也算进法线，草叶会东倒西歪；太大则贴不准坡。
  vm.Vector3 normalAt(double x, double z, {double eps = 0.8}) {
    final hL = heightAt(x - eps, z);
    final hR = heightAt(x + eps, z);
    final hD = heightAt(x, z - eps);
    final hU = heightAt(x, z + eps);
    return vm.Vector3(hL - hR, 2.0 * eps, hD - hU).normalized();
  }

  /// 坡度（0 = 水平，1 = 垂直）。植被与石块的分布规则都用它。
  double slopeAt(double x, double z) {
    final n = normalAt(x, z);
    return math.sqrt(1.0 - n.y * n.y).clamp(0.0, 1.0);
  }

  /// 坡向（弧度）：坡面朝向的水平方向角，0 = +Z，绕 Y 增加。
  ///
  /// 生态上用它区分阳坡/阴坡：本关卡约定 **−Z 为北**（背阴）。
  double aspectAt(double x, double z) {
    final n = normalAt(x, z);
    return math.atan2(n.x, n.z);
  }

  /// 阴坡权重（0 = 朝南/向阳，1 = 朝北/背阴）。
  double shadeAt(double x, double z) {
    final a = aspectAt(x, z);
    return (1.0 - math.cos(a - math.pi)) * 0.5;
  }

  /// 水面高程。水面 = 雕刻后的河床 + 水深，与 [heightAt] 同源。
  double waterSurfaceAt(double x, double z) =>
      heightAt(river.centerX(z), z) + river.waterDepth;

  /// 到河道中心线的距离（米），供植被的"离水规则"使用。
  double riverDistanceAt(double x, double z) => river.distanceToCenter(x, z);

  /// 该点是否在水面以下（用于剔除水里的草/树/石）。
  bool isUnderwater(double x, double z) => heightAt(x, z) < waterSurfaceAt(x, z);

  /// 生成地形网格。每个格点一个顶点，每格两个三角形，
  /// 绕序为 CCW 使正面朝向 +Y（与引擎约定一致）。
  MeshGeometry buildGeometry() {
    final builder = GeometryBuilder();
    final s = spacing;
    final h = halfExtent;

    for (var r = 0; r < rows; r++) {
      final z = -h + r * s;
      for (var c = 0; c < cols; c++) {
        final x = -h + c * s;
        final y = heightAt(x, z);
        // 大尺度色斑：整片草地一个颜色会读成塑料感，这里让深浅随时间/位置变化。
        final patch =
            noise.fbm2(x * 0.075 + 11.0, z * 0.075 + 29.0, octaves: 2) * 0.055;
        builder
          ..color(_shoreBlend(x, z, y, _colorForHeight(y, patch)))
          ..addVertex(vm.Vector3(x, y, z));
      }
    }

    for (var r = 0; r < rows - 1; r++) {
      for (var c = 0; c < cols - 1; c++) {
        final v00 = r * cols + c;
        final v10 = v00 + 1;
        final v01 = v00 + cols;
        final v11 = v01 + 1;
        builder
          ..addTriangle(v00, v01, v10)
          ..addTriangle(v10, v01, v11);
      }
    }

    return builder.build();
  }

  /// 岸边过渡带配色：靠近水面处把地面色往湿沙/卵石上拉。
  ///
  /// 没有这一步的话，水面与草地之间是一条硬边（绿色直接切到蓝），
  /// 无论草怎么分布都会读成"贴上去的"。这里按"离水面的高度差"做渐变：
  ///   * 水下 → 深色河床（卵石/淤泥）；
  ///   * 水位以上 ~1.2m → 湿沙 → 干沙 → 逐渐回到原地表色。
  /// 同时按坡度把陡岸染成裸岩色，避免所有岸线都长得一样。
  vm.Vector4 _shoreBlend(double x, double z, double y, vm.Vector4 base) {
    final dist = river.distanceToCenter(x, z);
    if (dist > river.valleyRadius) return base;

    final waterY = waterSurfaceAt(x, z);
    final aboveWater = y - waterY;

    // 沙色不能太亮：明亮天光下 0.6 的沙会渲染成接近纯白，
    // 岸边会出现一条刺眼的"白带"（实测）。压到 0.4 附近才像河滩。
    final wetSand = vm.Vector4(0.38, 0.33, 0.25, 1.0);
    final drySand = vm.Vector4(0.48, 0.43, 0.33, 1.0);
    final riverBed = vm.Vector4(0.30, 0.28, 0.24, 1.0);
    final bareRock = vm.Vector4(0.50, 0.49, 0.47, 1.0);

    if (aboveWater <= 0) {
      // 水下：越深越暗（视觉上也会被水面遮住，主要防止岸边透出绿草色）。
      final t = (-aboveWater / 2.0).clamp(0.0, 1.0);
      return _mixColor(_mixColor(base, riverBed, 0.75), riverBed, t * 0.6);
    }

    // 岸上 0–0.8m 是湿沙→干沙→原地表色；再叠加坡度带来的裸岩。
    // 带宽从 1.2m 收到 0.8m：太宽会形成一条"沙滩公路"，
    // 河岸应该是窄窄一条湿边，草地紧跟着就上来了。
    final t = (aboveWater / 0.8).clamp(0.0, 1.0);
    final sandColor = _mixColor(wetSand, drySand, t);
    final blended = _mixColor(sandColor, base, t * t);

    final slope = slopeAt(x, z);
    final rockT = ((slope - 0.32) / 0.35).clamp(0.0, 1.0) * (1.0 - t) * 0.7;
    return _mixColor(blended, bareRock, rockT);
  }

  /// 按高度分层的配色 + 大尺度色斑。
  vm.Vector4 _colorForHeight(double y, [double patch = 0.0]) {
    final base = _baseColorForHeight(y);
    // patch 主要落在绿色通道，形成深浅不一的草斑。
    return vm.Vector4(
      (base.r + patch * 0.6).clamp(0.0, 1.0),
      (base.g + patch * 1.5).clamp(0.0, 1.0),
      (base.b + patch * 0.4).clamp(0.0, 1.0),
      base.a,
    );
  }

  vm.Vector4 _baseColorForHeight(double y) {
    final grassDark = vm.Vector4(0.16, 0.40, 0.14, 1.0);
    final grassMid = vm.Vector4(0.28, 0.60, 0.21, 1.0);
    final soil = vm.Vector4(0.46, 0.40, 0.28, 1.0);
    final rock = vm.Vector4(0.56, 0.55, 0.52, 1.0);

    if (y <= 0.5) return grassDark;
    if (y <= 4.0) return _mixColor(grassDark, grassMid, (y - 0.5) / 3.5);
    if (y <= 8.0) return _mixColor(grassMid, soil, (y - 4.0) / 4.0);
    return _mixColor(soil, rock, ((y - 8.0) / 6.0).clamp(0.0, 1.0));
  }

  static vm.Vector4 _mixColor(vm.Vector4 a, vm.Vector4 b, double t) => vm.Vector4(
        a.r + (b.r - a.r) * t,
        a.g + (b.g - a.g) * t,
        a.b + (b.b - a.b) * t,
        a.a + (b.a - a.a) * t,
      );

  /// 组装成可直接 add 到场景的节点。
  Node buildNode() {
    final material = PhysicallyBasedMaterial()
      ..baseColorFactor = vm.Vector4(1, 1, 1, 1) // 交由顶点色决定实际颜色
      ..roughnessFactor = 0.95
      ..metallicFactor = 0.0;
    return Node(mesh: Mesh(buildGeometry(), material));
  }
}
