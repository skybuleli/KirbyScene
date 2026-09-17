/// 分层植被：花草、灌木、乔木。与草地（`grass.dart`）共享同一套地形查询，
/// 但各自有不同的分布规则与几何。
///
/// ## 分布怎么做到"自然"而不是"随机撒"
///
/// 单一噪声密度场撒出来的东西会读成"均匀的点阵"。这里叠了四层规则：
///
///   1. **场地因子**（[Site]）：坡度、坡向（阴坡/阳坡）、海拔、离水距离 —— 
///      决定"这种植物能不能长在这"；
///   2. **成丛噪声**：低频 fbm，让同类植物在空间上成片出现（林窗、花丛），
///      而不是处处稀稀拉拉；
///   3. **互相抑制**：乔木在林窗内会互相排开（网格 + 每格 1 株 + 抖动），
///      灌木避开乔木落点，花草避开灌木根部 —— 层次之间不打架；
///   4. **个体差异**：每株的朝向、尺寸、颜色、形态（阔叶/针叶、
///      双球冠/三层锥冠）都随机，因此 300 棵树的林子在近处也找不到两棵一样的。
///
/// ## 为什么全部走 InstancedMesh
///
/// 每一类植被 = 一个几何 + 一次 draw call；形态多样性靠"每株放多个实例"
/// （比如阔叶树 = 1 个树干实例 + 2 个树冠实例）而不是多份网格。
/// 这样实例数上去了，draw call 数不变。
///
/// ## 预算
///
/// 花草约 1.5 万、灌木约 1.5 千、树约 300 棵、石块约 300 块。
/// 全部静态（不做每帧矩阵更新）—— 每帧更新实例矩阵会让引擎重打包整块实例
/// 缓冲，草的风摆已经占了那份预算（见 world.dart 的说明）。
library;
import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'noise.dart';
import 'terrain.dart';

/// 一个落点的场地信息（各层植被共用，避免重复算地形导数）。
class Site {
  Site({
    required this.x,
    required this.z,
    required this.y,
    required this.slope,
    required this.shade,
    required this.riverDist,
    required this.aboveWater,
    required this.clump,
    required this.patch,
  });

  final double x;
  final double z;
  final double y;

  /// 坡度 0–1（1 = 垂直）。
  final double slope;

  /// 阴坡权重 0（向阳）–1（背阴）。
  final double shade;

  /// 到河道中心线的距离（米）。
  final double riverDist;

  /// 高出水面的高度（米），负值表示在水下。
  final double aboveWater;

  /// 成丛噪声 −1–1：同类植被在此处的聚集倾向。
  final double clump;

  /// 地表色斑（−1–1），与地形配色/草密度同源。
  final double patch;
}

class FloraSystem {
  FloraSystem({
    required this.terrain,
    this.flowerBudget = 15000,
    this.shrubBudget = 950,
    this.treeBudget = 420,
    this.rockBudget = 420,
    this.reedBudget = 2600,
    int seed = 777,
  })  : _rng = math.Random(seed),
        _noise = ValueNoise(seed: seed ^ 0x1f10a);

  final Terrain terrain;
  final int flowerBudget;
  final int shrubBudget;
  final int treeBudget;
  final int rockBudget;

  /// 岸边水生植物（芦苇/水草）的预算：填满"水 → 湿沙 → 草"之间的过渡带。
  final int reedBudget;

  final math.Random _rng;
  final ValueNoise _noise;

  /// 玩法区外围多少米内不种树。收集物最远在 19.5m，树从 24m 起，
  /// 既不挡收集路线，也不会让玩家在场地中心看到"树林贴脸"。
  static const double treeInnerRadius = 21.0;

  /// 场地外沿。比草地的 70m 略近：树和石块是个体大的物体，
  /// 太远只看得见几个像素，浪费预算；草的"纹理层"负责更远的山。
  static const double outerRadius = 68.0;

  final Map<String, int> counts = {};

  // ------------------------------------------------------------------
  // 场地查询
  // ------------------------------------------------------------------

  Site siteAt(double x, double z) {
    final y = terrain.heightAt(x, z);
    // 法线只算一次：坡度和坡向都由它导出（各算一次等于多花 4 次 heightAt，
    // 这里要被调用几万次，省下来的是实打实的启动时间）。
    final n = terrain.normalAt(x, z);
    final aspect = math.atan2(n.x, n.z);
    return Site(
      x: x,
      z: z,
      y: y,
      slope: math.sqrt(1.0 - n.y * n.y).clamp(0.0, 1.0),
      shade: (1.0 - math.cos(aspect - math.pi)) * 0.5,
      riverDist: terrain.riverDistanceAt(x, z),
      aboveWater: y - terrain.waterSurfaceAt(x, z),
      clump: _noise.fbm2(x * 0.042 + 7.1, z * 0.042 - 2.3, octaves: 3),
      patch: _noise.fbm2(x * 0.075 + 11.0, z * 0.075 + 29.0, octaves: 2),
    );
  }

  /// 通用的分层抖动撒点。
  ///
  /// * `cell`：网格边长 —— 也就是"同类个体之间的最小平均间距"；
  /// * `perCell`：每格放几个（泊松化的期望值，<1 表示稀疏）；
  /// * `jitter`：格内抖动半径比例（1 = 铺满整格）；
  /// * `density`：返回该点的期望个数修正（0 = 此处不生长）。
  ///
  /// **格子按"抖动距离"排序**：预算不够时先裁远景（与草地同一策略）。
  List<Site> scatter({
    required int budget,
    required double cell,
    required double perCell,
    required double Function(Site) density,
    double jitter = 0.5,
  }) {
    final result = <Site>[];
    final span = (outerRadius / cell).ceil();
    final cells = <({double x, double z, double key})>[];
    for (var gz = -span; gz <= span; gz++) {
      for (var gx = -span; gx <= span; gx++) {
        final cx = (gx + 0.5) * cell;
        final cz = (gz + 0.5) * cell;
        final d = math.sqrt(cx * cx + cz * cz);
        if (d > outerRadius + cell * 0.71) continue;
        cells.add((x: cx, z: cz, key: d + _rng.nextDouble() * cell * 2.0));
      }
    }
    cells.sort((a, b) => a.key.compareTo(b.key));

    for (final c in cells) {
      if (result.length >= budget) break;
      var expected = perCell;
      final center = siteAt(c.x, c.z);
      expected *= density(center);
      var count = expected.floor();
      if (_rng.nextDouble() < expected - count) count++;
      if (count <= 0) continue;

      for (var i = 0; i < count; i++) {
        var x = c.x + (_rng.nextDouble() - 0.5) * cell * 2.0 * jitter;
        var z = c.z + (_rng.nextDouble() - 0.5) * cell * 2.0 * jitter;

        // **域扭曲**：用低频噪声把落点整体推移。分层网格天生带"点阵感"
        // （俯视尤其明显——实测灌木/草丛排成整齐的格子），抖动只能打断
        // 格内对齐，打断不了"每格都有"的周期性；域扭曲是相干位移，
        // 相邻落点一起被推移，网格感消失但分布依然均匀。
        x += _noise.fbm2(x * 0.11 + 23.0, z * 0.11 - 8.0, octaves: 2) * 1.1;
        z += _noise.fbm2(x * 0.11 - 15.0, z * 0.11 + 41.0, octaves: 2) * 1.1;

        final d = math.sqrt(x * x + z * z);
        if (d > outerRadius || d < 1.5) continue;
        result.add(siteAt(x, z));
        if (result.length >= budget) break;
      }
    }
    return result;
  }

  // ------------------------------------------------------------------
  // 几何
  // ------------------------------------------------------------------

  /// 花朵：一小簇花瓣（3 个交叉面片）——比"一根细杆"在远处更容易看出颜色。
  MeshGeometry _flowerGeometry() {
    final b = GeometryBuilder();
    // 花瓣面：四个互相交叉的四边形，从任意角度看都有花。
    // 花本身比草矮的话，在草地里等于不存在（实测 0.1m 的花被 0.6m 的草
    // 完全遮住），所以花茎给到 0.32m，花头再往上 0.07m。
    //
    // 顶点色在这里派上用场：**花瓣留白、花茎压成绿色**。两者共用同一个
    // 实例色（花色），如果都是白的，远看就是插了一地"白色 T 字"（实测较丑）。
    const petalW = 0.095;
    const petalH = 0.32;
    const petalTop = 0.39;

    // 花茎（深绿）：顶点色 × 实例色 → 花色只会轻微影响茎的色调。
    b.color(vm.Vector4(0.30, 0.62, 0.24, 1.0));
    final stemBase = b.vertexCount;
    b
      ..addVertex(vm.Vector3(-0.014, 0.0, 0.0))
      ..addVertex(vm.Vector3(0.014, 0.0, 0.0))
      ..addVertex(vm.Vector3(0.011, petalH, 0.0))
      ..addVertex(vm.Vector3(-0.011, petalH, 0.0));
    b
      ..addTriangle(stemBase, stemBase + 1, stemBase + 2)
      ..addTriangle(stemBase, stemBase + 2, stemBase + 3);

    // 花瓣（近白，让实例色决定花色）
    b.color(vm.Vector4(1.0, 1.0, 1.0, 1.0));
    for (var k = 0; k < 4; k++) {
      final a = k * math.pi / 4.0;
      final dx = math.cos(a) * petalW;
      final dz = math.sin(a) * petalW;
      final base = b.vertexCount;
      b.addVertex(vm.Vector3(-dx, petalH, -dz));
      b.addVertex(vm.Vector3(dx, petalH, dz));
      b.addVertex(vm.Vector3(dx, petalTop, dz));
      b.addVertex(vm.Vector3(-dx, petalTop, -dz));
      // 只放正面：材质是 doubleSided，没必要再来一组反向三角形
      // （15k 朵花 × 多出的 6 个三角形 = 白送的 9 万个三角形）。
      b
        ..addTriangle(base, base + 1, base + 2)
        ..addTriangle(base, base + 2, base + 3);
    }
    return b.build();
  }

  /// 灌木：压扁的二十面体（多球感靠实例色渐变与随机缩放制造）。
  MeshGeometry _shrubGeometry() =>
      IcosphereGeometry(radius: 0.5, subdivisions: 1);

  /// 树干：下粗上细的锥柱。
  MeshGeometry _trunkGeometry() => CylinderGeometry(
        topRadius: 0.07,
        bottomRadius: 0.13,
        height: 1.0,
        radialSegments: 6,
        heightSegments: 1,
      );

  /// 阔叶树冠：一个球。
  MeshGeometry _broadleafGeometry() =>
      IcosphereGeometry(radius: 0.5, subdivisions: 1);

  /// 针叶树冠：一个圆锥（每棵树叠 3 个不同尺寸的实例 → 塔形）。
  MeshGeometry _coniferGeometry() => CylinderGeometry(
        topRadius: 0.0,
        bottomRadius: 0.5,
        height: 1.0,
        radialSegments: 7,
        heightSegments: 1,
      );

  /// 芦苇/水草：细长的锥叶（比草高、比草挺），用来填水线附近的过渡带。
  MeshGeometry _reedGeometry() => CylinderGeometry(
        topRadius: 0.0,
        bottomRadius: 0.055,
        height: 1.0,
        radialSegments: 3,
        heightSegments: 1,
      );

  /// 石块：二十面体（随机缩放/旋转后就是很不一样的石头）。
  MeshGeometry _rockGeometry() => IcosphereGeometry(radius: 0.5, subdivisions: 1);

  PhysicallyBasedMaterial _plantMaterial({double roughness = 0.85}) =>
      PhysicallyBasedMaterial()
        ..baseColorFactor = vm.Vector4(1, 1, 1, 1) // 颜色交给实例色
        ..roughnessFactor = roughness
        ..metallicFactor = 0.0
        ..doubleSided = true;

  // ------------------------------------------------------------------
  // 各层构建
  // ------------------------------------------------------------------

  /// 花草：只长在草地密、坡度缓、离水有距离的地方；成丛分布。
  InstancedMesh _buildFlowers() {
    final mesh = InstancedMesh(
      geometry: _flowerGeometry(),
      material: _plantMaterial(roughness: 0.75),
    );

    final sites = scatter(
      budget: flowerBudget,
      cell: 1.2,
      perCell: 3.2,
      jitter: 0.62,
      density: (s) {
        if (s.aboveWater < 0.6) return 0; // 水边不长花
        final slopeOk = ((0.50 - s.slope) / 0.26).clamp(0.0, 1.0);
        if (slopeOk <= 0) return 0;
        // 花丛：成丛噪声高的地方开成片，其余地方零星（但别零星到看不见）。
        final clumpiness = ((s.clump + 0.35) / 0.7).clamp(0.0, 1.0);
        final patchOk = ((s.patch + 0.06) / 0.11).clamp(0.0, 1.0);
        final altitude = (1.0 - (s.y - 6.0) / 3.5).clamp(0.0, 1.0);
        return slopeOk *
            (0.35 + 0.65 * clumpiness) *
            (0.55 + 0.45 * patchOk) *
            altitude;
      },
    );

    // 花色：白 / 黄 / 粉 / 紫 / 淡蓝。用"每片花色不同"制造花丛的层次。
    const palette = <(double r, double g, double b)>[
      (0.94, 0.94, 0.88), // 白
      (0.96, 0.84, 0.32), // 黄
      (0.92, 0.55, 0.68), // 粉
      (0.66, 0.50, 0.86), // 紫
      (0.62, 0.76, 0.94), // 淡蓝
    ];

    for (final s in sites) {
      final scale = 0.75 + _rng.nextDouble() * 0.7;
      final c = palette[_rng.nextInt(palette.length)];
      // 同类花色的深浅也随机一点，避免"一片塑料花"。
      final tone = 0.88 + _rng.nextDouble() * 0.24;
      mesh.addInstance(
        vm.Matrix4.compose(
          vm.Vector3(s.x, s.y - 0.02, s.z),
          vm.Quaternion.axisAngle(vm.Vector3(0.0, 1.0, 0.0),
              _rng.nextDouble() * math.pi * 2),
          vm.Vector3(scale, scale, scale),
        ),
        color: vm.Vector4(
          (c.$1 * tone).clamp(0.0, 1.0),
          (c.$2 * tone).clamp(0.0, 1.0),
          (c.$3 * tone).clamp(0.0, 1.0),
          1.0,
        ),
      );
    }
    counts['flowers'] = sites.length;
    return mesh;
  }

  /// 灌木：喜欢坡地与洼地、河边也能长；成丛（现实里灌木是成片灌丛）。
  ///
  /// 返回 (网格, 落点)：落点交给乔木做避让，避免树根扎进灌丛中心。
  (InstancedMesh, List<Site>) _buildShrubs() {
    final mesh = InstancedMesh(
      geometry: _shrubGeometry(),
      material: _plantMaterial(roughness: 0.9),
    );

    final sites = scatter(
      budget: shrubBudget,
      cell: 3.0,
      perCell: 1.2,
      jitter: 0.72,
      density: (s) {
        // 水边 1.5–8m 是"岸边灌丛带"，再往上是坡地灌丛。
        final riparian = s.riverDist < 9.0
            ? ((s.aboveWater - 0.7) / 1.2).clamp(0.0, 1.0) *
                (1.0 - (s.riverDist / 9.0)) *
                1.4
            : 0.0;
        if (s.aboveWater < 0.7) return 0;
        final slopeOk = ((0.66 - s.slope) / 0.32).clamp(0.0, 1.0);
        if (slopeOk <= 0) return 0;
        final clumpiness = ((s.clump + 0.4) / 0.6).clamp(0.0, 1.0);
        final altitude = (1.0 - (s.y - 8.0) / 4.5).clamp(0.0, 1.0);
        // 灌丛要么成片、要么没有：指数 2 让"稀疏区"真正稀疏，
        // 否则每平方米都冒一两丛，草地就被挤没了。
        return slopeOk * altitude *
            (0.12 + 0.88 * clumpiness * clumpiness) *
            (1.0 + riparian * 1.6);
      },
    );

    for (final s in sites) {
      // 一丛灌木 = 2–4 个球，尺寸与位置都不同 → 轮廓不重复。
      final blobs = 2 + _rng.nextInt(3);
      final base = 0.45 + _rng.nextDouble() * 0.65;
      // 背阴处偏深绿、向阳处偏黄绿。
      final shadeTint = 0.55 + 0.45 * (1.0 - s.shade);
      for (var i = 0; i < blobs; i++) {
        final r = base * (0.75 + _rng.nextDouble() * 0.5);
        final ox = (_rng.nextDouble() - 0.5) * 0.7 * base;
        final oz = (_rng.nextDouble() - 0.5) * 0.7 * base;
        mesh.addInstance(
          vm.Matrix4.compose(
            vm.Vector3(s.x + ox, s.y - 0.12 * r + r * 0.42, s.z + oz),
            vm.Quaternion.axisAngle(
                vm.Vector3(0.0, 1.0, 0.0), _rng.nextDouble() * math.pi * 2),
            vm.Vector3(r * 1.15, r * 0.85, r * 1.15),
          ),
          // 灌木色：深绿到橄榄绿，背阴更暗。与石块（灰）必须区分得开。
          color: vm.Vector4(
            0.08 + 0.11 * shadeTint + _rng.nextDouble() * 0.04,
            0.20 + 0.22 * shadeTint + _rng.nextDouble() * 0.05,
            0.06 + 0.07 * shadeTint,
            1.0,
          ),
        );
      }
    }
    counts['shrubBlobs'] = mesh.instanceCount;
    counts['shrubSites'] = sites.length;
    return (mesh, sites);
  }

  /// 乔木：分阔叶与针叶两类，各按海拔/坡向/离水距离分区。
  ///
  /// 返回 (树干, 阔叶冠, 针叶冠)。
  (InstancedMesh trunk, InstancedMesh broadleaf, InstancedMesh conifer)
      _buildTrees(List<Site> reserved) {
    final trunk = InstancedMesh(
      geometry: _trunkGeometry(),
      material: _plantMaterial(roughness: 0.95),
    );
    final broadleaf = InstancedMesh(
      geometry: _broadleafGeometry(),
      material: _plantMaterial(roughness: 0.88),
    );
    final conifer = InstancedMesh(
      geometry: _coniferGeometry(),
      material: _plantMaterial(roughness: 0.9),
    );

    final sites = scatter(
      budget: treeBudget,
      cell: 4.6,
      perCell: 1.05,
      jitter: 0.42,
      density: (s) {
        final d = math.sqrt(s.x * s.x + s.z * s.z);
        if (d < treeInnerRadius) return 0; // 玩法区不种树
        if (s.aboveWater < 0.7) return 0; // 不泡在水里
        if (s.slope > 0.62) return 0; // 陡崖长不住
        // 河岸林：离水近的地方阔叶更密（柳树/杨树的生态位）。
        final riparianBoost =
            s.riverDist < 16.0 ? 1.0 + 0.8 * (1.0 - s.riverDist / 16.0) : 1.0;
        // 成林：低频噪声高处长成林，低处留出林间空地。
        // forest^1.6：让"林地/林间空地"的对比拉开。指数是 1 的时候
        // 全场都是中等密度，读起来像果园（等距种植）；指数拉高之后
        // 就会出现成片的林子和成片的草甸。
        final forest = ((s.clump + 0.3) / 0.7).clamp(0.0, 1.0);
        final forested = math.pow(forest, 1.15).toDouble();
        final edgeFade = ((d - treeInnerRadius) / 5.0).clamp(0.0, 1.0);
        return (0.15 + 0.85 * forested) * riparianBoost * edgeFade;
      },
    );

    var treeCount = 0;
    for (final s in sites) {
      // 与灌木太近就不种（避免树根埋在灌木丛里）。
      var tooClose = false;
      for (final r in reserved) {
        final dx = r.x - s.x, dz = r.z - s.z;
        if (dx * dx + dz * dz < 0.9) {
          tooClose = true;
          break;
        }
      }
      if (tooClose) continue;

      // 阔叶/针叶的生态分区：
      //   * 低海拔 + 河岸 → 阔叶为主；
      //   * 高海拔 + 阴坡 → 针叶为主；
      //   * 中间地带混合，避免出现"一条界线"。
      final coniferChance =
          ((s.y - 1.0) / 5.5).clamp(0.0, 1.0) * 0.45 + s.shade * 0.50;
      final isConifer = _rng.nextDouble() < coniferChance;

      final height = (isConifer ? 3.4 : 2.8) + _rng.nextDouble() * (isConifer ? 3.4 : 2.6);
      final girth = 0.7 + _rng.nextDouble() * 0.6;
      final lean = (_rng.nextDouble() - 0.5) * 0.07; // 轻微倾斜，不是杆子
      final leanDir = _rng.nextDouble() * math.pi * 2;
      final yaw = _rng.nextDouble() * math.pi * 2;

      final rotation = vm.Quaternion.axisAngle(vm.Vector3(0.0, 1.0, 0.0), yaw) *
          vm.Quaternion.axisAngle(
              vm.Vector3(math.cos(leanDir), 0.0, math.sin(leanDir)), lean);

      final baseY = s.y - 0.25;
      // 树干
      trunk.addInstance(
        vm.Matrix4.compose(
          vm.Vector3(s.x, baseY + height * 0.5, s.z),
          rotation,
          vm.Vector3(girth, height, girth),
        ),
        color: vm.Vector4(
          0.22 + _rng.nextDouble() * 0.11,
          0.17 + _rng.nextDouble() * 0.09,
          0.11 + _rng.nextDouble() * 0.06,
          1.0,
        ),
      );

      if (isConifer) {
        // 塔形：3 层圆锥，越往上层越小，整体轮廓是针叶树。
        final crownBase = baseY + height * 0.22;
        final crownH = height * 0.86;
        for (var k = 0; k < 3; k++) {
          final t = k / 3.0;
          final layerR = (1.0 - t * 0.5) * height * 0.21;
          final layerH = crownH * 0.52;
          conifer.addInstance(
            vm.Matrix4.compose(
              vm.Vector3(s.x, crownBase + crownH * t * 0.62 + layerH * 0.5, s.z),
              rotation,
              vm.Vector3(layerR * 2.0, layerH, layerR * 2.0),
            ),
            // 针叶：更暗、更蓝的绿，与阔叶拉开材质差异。
            color: vm.Vector4(
              0.06 + _rng.nextDouble() * 0.04,
              0.16 + _rng.nextDouble() * 0.08 + t * 0.04,
              0.10 + _rng.nextDouble() * 0.04,
              1.0,
            ),
          );
        }
      } else {
        // 阔叶：2 个球冠错开（主冠 + 侧冠），轮廓不规整。
        final crownR = height * 0.50;
        final mainY = baseY + height * 0.92;
        broadleaf.addInstance(
          vm.Matrix4.compose(
            vm.Vector3(s.x, mainY, s.z),
            vm.Quaternion.axisAngle(
                vm.Vector3(0.0, 1.0, 0.0), _rng.nextDouble() * math.pi * 2),
            vm.Vector3(crownR * 1.25, crownR * 1.0, crownR * 1.25),
          ),
          color: vm.Vector4(
            0.13 + _rng.nextDouble() * 0.09,
            0.29 + _rng.nextDouble() * 0.14,
            0.09 + _rng.nextDouble() * 0.06,
            1.0,
          ),
        );
        final sideDir = _rng.nextDouble() * math.pi * 2;
        final sideR = crownR * (0.55 + _rng.nextDouble() * 0.3);
        broadleaf.addInstance(
          vm.Matrix4.compose(
            vm.Vector3(s.x + math.cos(sideDir) * crownR * 0.5,
                mainY - crownR * 0.35, s.z + math.sin(sideDir) * crownR * 0.5),
            vm.Quaternion.axisAngle(
                vm.Vector3(0.0, 1.0, 0.0), _rng.nextDouble() * math.pi * 2),
            vm.Vector3(sideR * 1.15, sideR * 0.95, sideR * 1.15),
          ),
          color: vm.Vector4(
            0.11 + _rng.nextDouble() * 0.08,
            0.26 + _rng.nextDouble() * 0.13,
            0.08 + _rng.nextDouble() * 0.05,
            1.0,
          ),
        );
      }
      treeCount++;
    }

    counts['trees'] = treeCount;
    counts['broadleafCrowns'] = broadleaf.instanceCount;
    counts['coniferCrowns'] = conifer.instanceCount;
    return (trunk, broadleaf, conifer);
  }

  /// 岸边水生植物带：只长在水线上下 0.9m 以内。
  ///
  /// 这一层是"水 → 湿沙 → 草"三段的黏合剂：没有它，水面和草地之间会剩下
  /// 一条光秃秃的沙带；有了它，岸线就有了生态层次（现实中也是芦苇/水草
  /// 长在水位附近，而不是均匀铺满整个滩地）。
  InstancedMesh _buildReeds() {
    final mesh = InstancedMesh(
      geometry: _reedGeometry(),
      material: _plantMaterial(roughness: 0.85),
    );

    final sites = scatter(
      budget: reedBudget,
      cell: 1.5,
      perCell: 3.0,
      density: (s) {
        if (s.riverDist > 14.0) return 0; // 只在水边
        // 水位以下 0.3m 到以上 0.9m 是芦苇带；再高就交给草了。
        if (s.aboveWater < -0.4 || s.aboveWater > 0.85) return 0;
        final band = 1.0 - ((s.aboveWater - 0.2).abs() / 0.65).clamp(0.0, 1.0);
        final clumpiness = ((s.clump + 0.4) / 0.6).clamp(0.0, 1.0);
        final shoreFade = 1.0 - (s.riverDist / 13.0);
        return (0.35 + 0.65 * clumpiness) * (0.45 + 0.55 * band) * (0.3 + 0.7 * shoreFade);
      },
    );

    for (final s in sites) {
      // 一撮芦苇 2–5 根，高矮不一（被风吹成一小片丛）。
      final stalks = 2 + _rng.nextInt(4);
      for (var i = 0; i < stalks; i++) {
        final h = 0.55 + _rng.nextDouble() * 0.85;
        final lean = (_rng.nextDouble() - 0.5) * 0.22;
        final dir = _rng.nextDouble() * math.pi * 2;
        mesh.addInstance(
          vm.Matrix4.compose(
            vm.Vector3(
              s.x + (_rng.nextDouble() - 0.5) * 0.4,
              s.y - 0.04 + h * 0.5,
              s.z + (_rng.nextDouble() - 0.5) * 0.4,
            ),
            vm.Quaternion.axisAngle(vm.Vector3(0.0, 1.0, 0.0),
                _rng.nextDouble() * math.pi * 2) *
                vm.Quaternion.axisAngle(
                    vm.Vector3(math.cos(dir), 0.0, math.sin(dir)), lean),
            vm.Vector3(1.0, h, 1.0),
          ),
          color: vm.Vector4(
            0.24 + _rng.nextDouble() * 0.10,
            0.34 + _rng.nextDouble() * 0.14,
            0.12 + _rng.nextDouble() * 0.08,
            1.0,
          ),
        );
      }
    }
    counts['reeds'] = mesh.instanceCount;
    return mesh;
  }

  /// 石块：大小跨度大（0.4–3.2m）、朝向随机、按坡度与岸边聚集、半埋入地。
  InstancedMesh _buildRocks() {
    final mesh = InstancedMesh(
      geometry: _rockGeometry(),
      material: PhysicallyBasedMaterial()
        ..baseColorFactor = vm.Vector4(1, 1, 1, 1)
        ..roughnessFactor = 0.95
        ..metallicFactor = 0.0,
    );

    final sites = scatter(
      budget: rockBudget,
      cell: 5.0,
      perCell: 1.2,
      jitter: 0.45,
      density: (s) {
        if (s.aboveWater < -0.4) return 0; // 完全沉在水底的不放
        // 陡坡与河床（离水很近）石头多 —— 侵蚀搬运的现实。
        final slopeBoost = 0.35 + 1.2 * s.slope;
        final riverBoost = s.riverDist < 8.0
            ? 1.0 + 1.2 * (1.0 - s.riverDist / 8.0)
            : 1.0;
        final clumpiness = ((s.clump + 0.4) / 0.6).clamp(0.0, 1.0);
        return slopeBoost * riverBoost * (0.25 + 0.75 * clumpiness);
      },
    );

    for (final s in sites) {
      // 尺寸：以中小石头为主，偶尔来一块大的（幂律分布 → 自然）。
      final big = _rng.nextDouble();
      final scale = big > 0.9
          ? 1.7 + _rng.nextDouble() * 1.5
          : 0.35 + math.pow(_rng.nextDouble(), 1.6).toDouble() * 1.3;
      // 朝向随机：三分量独立，得到真正"随机躺姿"的石头。
      final rot = vm.Quaternion.euler(
        _rng.nextDouble() * math.pi * 2,
        _rng.nextDouble() * math.pi * 2,
        _rng.nextDouble() * math.pi * 2,
      );
      // 半埋：下沉 25%–55%，石头才像"长在地里"而不是摆件。
      final sink = 0.25 + _rng.nextDouble() * 0.3;
      // 形状：XZ 与 Y 独立缩放 → 有的扁平、有的墩实。
      final flat = 0.55 + _rng.nextDouble() * 0.6;
      // 石色：灰到灰褐，明度 0.30–0.58。之前的写法把两个系数相乘，
      // 偶尔会乘出接近白色的石头（截图里那块"白瓷盘"）。
      final tone = 0.30 + _rng.nextDouble() * 0.28;
      mesh.addInstance(
        vm.Matrix4.compose(
          vm.Vector3(s.x, s.y - scale * sink, s.z),
          rot,
          vm.Vector3(scale * (0.85 + _rng.nextDouble() * 0.4), scale * flat,
              scale * (0.85 + _rng.nextDouble() * 0.4)),
        ),
        color: vm.Vector4(
          tone * (1.02 + _rng.nextDouble() * 0.06),
          tone * (0.98 + _rng.nextDouble() * 0.05),
          tone * (0.94 + _rng.nextDouble() * 0.05),
          1.0,
        ),
      );
    }
    counts['rocks'] = sites.length;
    return mesh;
  }

  /// 组装全部植被层，返回可 add 到场景的节点。
  List<Node> buildNodes() {
    // 先灌木、后乔木：灌木落点作为乔木的避让点（树根不扎进灌丛里）。
    final (shrubMesh, shrubSites) = _buildShrubs();
    final flowerMesh = _buildFlowers();
    final (trunk, broadleaf, conifer) = _buildTrees(shrubSites);
    final reeds = _buildReeds();
    final rocks = _buildRocks();

    return [
      Node(name: 'rocks')..addComponent(InstancedMeshComponent(rocks)),
      Node(name: 'reeds')..addComponent(InstancedMeshComponent(reeds)),
      Node(name: 'flowers')..addComponent(InstancedMeshComponent(flowerMesh)),
      Node(name: 'shrubs')..addComponent(InstancedMeshComponent(shrubMesh)),
      Node(name: 'treeTrunks')..addComponent(InstancedMeshComponent(trunk)),
      Node(name: 'treeBroadleaf')..addComponent(InstancedMeshComponent(broadleaf)),
      Node(name: 'treeConifer')..addComponent(InstancedMeshComponent(conifer)),
    ];
  }
}
