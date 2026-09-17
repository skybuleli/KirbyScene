/// 程序化草地 v2：分层密度场采样 + 蓝噪声式分层抖动 + 丛簇分布。
///
/// 相比 v1（纯随机均匀撒点）解决两个问题：
///
/// **密度过低** —— v1 把 4500 根草均匀撒在 6–68m 的整个环带上
/// （约 14400 m²，0.3 根/m²，远低于真草地 3 个数量级）。v2 改为
/// 预算制（[maxBlades]，默认 8 万根）+ 距离加权：近处密度高、远处迅速变薄，
/// 把实例预算集中花在相机真正看的地方。
///
/// **分布不正确** —— v1 与地表完全无关。v2 引入密度场（[densityAt]）：
///   * 与地形**同一张** patch 噪声（`fbm2(x*0.075+11, z*0.075+29)`，
///     见 `terrain.dart` 的顶点配色）——草密的斑块正是地表偏绿的斑块；
///   * 陡坡（法线朝上分量低）渐隐到 0 —— 那里地形本来就是土壤/岩石色；
///   * 高海拔（y > 6.5）渐隐到 0 —— 与地形"草→土→岩"的分层一致；
///   * 采样用**分层抖动网格 + 丛簇**（现代草地渲染的标准做法：
///     blue-noise 防止聚堆与空穴，clump 让"一撮一撮"的自然感可以
///     用远低于均匀密度的实例数达成）。
///
/// 草叶是自定义几何：带弯曲的锥形叶片 + 顶点色渐变（根部暗、叶尖亮，
/// 近似环境光遮蔽与透光），实例色作为乘子继续提供个体差异
/// （flutter_scene 中实例色是线性 RGBA 乘子，与顶点色相乘）。
///
/// 风摆接口（[windPhase] / [applyWind]）保持不变；[applyWind] 内部
/// 零分配（复用 scratch 矩阵），且只对 [windRadius] 内的子集生效。

library;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'noise.dart';
import 'terrain.dart';

/// 一个草叶的采样结果（布局阶段产物，纯数据、可单测）。
class GrassBlade {
  GrassBlade({
    required this.x,
    required this.z,
    required this.yaw,
    required this.height,
    required this.tint,
    required this.phase,
  });

  final double x;
  final double z;

  /// 绕竖直轴（世界 Y）的朝向角，弧度。
  final double yaw;

  /// 叶高（米）。
  final double height;

  /// 实例色乘子（RGB，alpha 恒 1）。
  final vm.Vector4 tint;

  /// 风摆相位。
  final double phase;
}

class GrassField {
  GrassField({
    required this.terrain,
    this.maxBlades = 110000,
    this.innerRadius = 2.0,
    this.outerRadius = 70.0,
    this.cellSize = 1.0,
    this.fullDensityRadius = 22.0,
    int seed = 915,
  }) : _rng = math.Random(seed),
       _noise = ValueNoise(seed: seed ^ 0x5eed);

  final Terrain terrain;
  final int maxBlades;

  /// 内圈留空半径。1.6m：既避免草穿过角色，又不让脚边出现突兀的秃圈。
  final double innerRadius;

  /// 草场外沿（此距离外不再产生草）。
  ///
  /// v2.1 从 66m 收到 58m：预算有限时**把实例花在看得见的地方**比均匀铺满
  /// 整个场地划算 —— 相机在角色身后 8.5m，30m 外的草在屏幕上只占几像素。
  final double outerRadius;

  /// 全密度半径：此半径内不做距离衰减，之外立方衰减到 0。
  final double fullDensityRadius;

  /// 分层采样的网格边长（米）。1.4m ≈ 视觉上"一撮草"的占地尺度。
  final double cellSize;

  final math.Random _rng;
  final ValueNoise _noise;
  InstancedMesh? _mesh;

  /// 每个实例的基础矩阵（位置 + 朝向 + 叶高缩放），不含距离补偿。
  ///
  /// 距离补偿（远处加宽、近处矮化）**不能烘焙**在这里：它取决于观察者位置，
  /// 而玩家会跑离原点。烘焙版本在玩家跑到 40m 外时会把脚边的草当成"远景"
  /// 放大 2.6 倍，变成挡住角色的巨型叶片（实测踩过）。
  late final List<vm.Matrix4> _baseTransforms;

  /// 叶根世界坐标（x, z 交错存放），供每帧计算到观察者的距离。
  late final Float32List _bladeXZ;

  /// 打乱后的相位，供风摆使用（避免整片草同步摆动）。
  late final List<double> windPhase;

  int get instanceCount => _mesh?.instanceCount ?? 0;

  /// 距离补偿参数：DISTANCE_START_M 之外开始加宽，最大加宽到 1+MAX_WIDEN。
  static const double kDistanceStart = 10.0;

  /// 加宽到最大值的距离（相对观察者）。
  static const double kDistanceFull = 40.0;

  /// 最大额外宽度比例（1.4 = 最宽 2.4 倍）。
  static const double kMaxWiden = 1.4;

  /// 角色脚下草的高度下限（相对全高）与恢复全高的距离（米）。
  static const double kNearHeightFactor = 0.62;
  static const double kFullHeightDistance = 10.0;

  /// 距离补偿：返回 (加宽倍率, 高度倍率)。纯函数，可单测。
  ///
  /// * 加宽以**相机距离**为准：补偿的是"叶片在屏幕上太窄被光栅化丢弃"。
  /// * 矮化以**角色距离**为准：补偿的是"草挡住角色"。
  ///   两者基准不同是刻意的，理由见 [applyWind] 的注释。
  static (double widthScale, double heightRamp) distanceCompensation({
    required double cameraDistance,
    required double playerDistance,
  }) {
    final wide =
        ((cameraDistance - kDistanceStart) / (kDistanceFull - kDistanceStart))
            .clamp(0.0, 1.0);
    return (
      1.0 + kMaxWiden * wide * wide,
      kNearHeightFactor +
          (1.0 - kNearHeightFactor) *
              (playerDistance / kFullHeightDistance).clamp(0.0, 1.0),
    );
  }

  // ------------------------------------------------------------------
  // 密度场
  // ------------------------------------------------------------------

  /// 位置 (x, z) 处的草密度（根/m²，未裁剪到预算）。
  double densityAt(double x, double z) {
    final d = math.sqrt(x * x + z * z);
    if (d < innerRadius || d > outerRadius) return 0;

    final groundY = terrain.heightAt(x, z);
    var shoreFade = 1.0;

    // 岸边过渡带：水位以下不长草，水位以上 1.6m 内密度渐入。
    // 硬切到 0 会让草地在岸边排成一条直线（和地形的沙色带也接不上），
    // 渐隐之后"草 → 湿沙 → 水"是连续过渡的。
    final waterY = terrain.waterSurfaceAt(x, z);
    final aboveWater = groundY - waterY;
    if (aboveWater < 1.1) {
      final shoreT = (aboveWater / 1.1).clamp(0.0, 1.0);
      if (shoreT <= 0) return 0;
      shoreFade = shoreT * shoreT;
    }

    // 距离 LOD：全密度到 [fullDensityRadius]，之后**立方**衰减到外沿。
    // 立方（而不是线性）让中远景迅速变薄——同样预算下"浓近景 + 薄远景"
    // 看起来比均匀分布浓密得多。
    final r =
        ((d - fullDensityRadius) / (outerRadius - fullDensityRadius)).clamp(0.0, 1.0);
    final inv = 1.0 - r;
    // 立方衰减 + 8% 下限：远山完全没草的话，62m 外是一条刺眼的"秃边"
    // （宽视角下整个背景都是裸的）；8% 的稀草刚好给远山铺一层纹理，
    // 而且预算优先给近景，多出来的部分不会挤占近处密度。
    final radial = math.max(0.08, inv * inv * inv);

    // 与地形配色同一张 patch 噪声：草密的地方正是地表偏绿的斑块。
    // terrain.dart 顶点色里 patch 的映射是 fbm2(x*0.075+11, z*0.075+29)。
    final patch = _noise.fbm2(x * 0.075 + 11.0, z * 0.075 + 29.0, octaves: 2);
    final lush = ((patch * 0.055 + 0.055) / 0.11).clamp(0.0, 1.0);

    // 坡度：法线朝上分量低于 0.70 不长草（崖壁），0.70–0.85 渐入。
    final slope = terrain.normalAt(x, z).y;
    final slopeFactor = ((slope - 0.70) / 0.15).clamp(0.0, 1.0);

    // 海拔：地形在 y≈8 起过渡为土壤/岩石色，草在 6.5–8.5 之间渐隐。
    final altitudeFactor = (1.0 - (groundY - 6.5) / 2.0).clamp(0.0, 1.0);

    // 近场增强：1.6–14m 一带密度最高提到 2.2 倍。
    // 这一圈面积很小（约 600m²），加密度非常便宜，而它正是相机近景里
    // 占屏幕最大的部分 —— "近处浓密、远处变薄"比全局均匀更容易读成草地。
    final nearBoost = 1.0 + 1.2 * (1.0 - (d / 14.0)).clamp(0.0, 1.0);

    // 近处全密度 42 根/m²（叠加近场增强后最高约 90 根/m²），
    // 单株 14cm 宽、成丛分布下这才读得出"草地"，而不是"地上点缀了几撮草"
    // （v1 只有 0.3 根/m²）。
    const base = 42.0;
    return base *
        nearBoost *
        radial *
        (0.40 + 0.60 * lush) *
        slopeFactor *
        altitudeFactor *
        shoreFade;
  }

  // ------------------------------------------------------------------
  // 布局采样（纯逻辑，可单测）
  // ------------------------------------------------------------------

  /// 分层抖动网格 + 丛簇采样。
  ///
  /// 先把覆盖圆盘切成 [cellSize] 网格，逐格按 [densityAt] 决定期望根数
  /// （整数部分直接放，小数部分按概率进位 —— 泊松化），每格内先定 1–2 个
  /// 丛簇中心、再把草叶抖动散在簇心周围。格状分层保证不留系统性空穴，
  /// 簇内抖动又打破格子感 —— 这正是 blue-noise 采样想达成的观感。
  List<GrassBlade> sampleLayout() {
    final blades = <GrassBlade>[];
    final cells = <({int gx, int gy, double key})>[];

    final span = (outerRadius / cellSize).ceil();
    for (var gy = -span; gy <= span; gy++) {
      for (var gx = -span; gx <= span; gx++) {
        // 只留与圆盘相交的格子（格子中心距圆心 <= 外沿 + 对角余量）。
        final cx = (gx + 0.5) * cellSize;
        final cz = (gy + 0.5) * cellSize;
        final d = math.sqrt(cx * cx + cz * cz);
        if (d > outerRadius + cellSize * 0.71) continue;
        // 排序键 = 距离 + 抖动（±3m）：预算用尽时先裁掉远格，
        // 抖动则避免裁出一条生硬的圆形边界。
        cells.add((gx: gx, gy: gy, key: d + _rng.nextDouble() * 3.0));
      }
    }

    // **预算优先给近处**：按抖动距离排序，而不是打乱。
    // 这样 maxBlades 不够用时，损失的是屏幕上只占几像素的远景，
    // 而不是相机正前方的近景 —— 这是"实例预算花在看得见的地方"的落实。
    cells.sort((a, b) => a.key.compareTo(b.key));

    for (final cell in cells) {
      if (blades.length >= maxBlades) break;

      final cx = (cell.gx + 0.5) * cellSize;
      final cz = (cell.gy + 0.5) * cellSize;

      final density = densityAt(cx, cz);
      if (density <= 0) continue;

      var expected = density * cellSize * cellSize;
      var count = expected.floor();
      expected -= count;
      if (_rng.nextDouble() < expected) count++;
      if (count <= 0) continue;

      // 本格 1–3 个丛簇中心，数量随机：固定"每格一撮"是点阵感的另一个来源。
      var clumpCount = 1;
      if (count >= 2 && _rng.nextDouble() < 0.55) clumpCount++;
      if (count >= 5 && _rng.nextDouble() < 0.30) clumpCount++;
      final clumps = List.generate(
        clumpCount,
        (_) => (
          x: cx + (_rng.nextDouble() - 0.5) * cellSize * 1.2,
          z: cz + (_rng.nextDouble() - 0.5) * cellSize * 1.2,
          // 每撮自己的松散度（0.16–0.42m）：固定半径会让全场丛簇长得一样，
          // 在大面积上会读成规则的"点阵"。
          spread: 0.16 + _rng.nextDouble() * 0.26,
        ),
      );

      // 本格整体色相：同一片 patch 的草色相近（簇内再加一点扰动）。
      final patchTint = _rng.nextDouble();

      for (var i = 0; i < count; i++) {
        final clump = clumps[i % clumpCount];
        // 簇内抖动：能读出"一撮"，又不至于重叠成面向量冲突。
        // 半径用平方根分布，避免全挤在簇心形成过密的尖刺。
        final angle = _rng.nextDouble() * math.pi * 2;
        final dist = math.sqrt(_rng.nextDouble()) * clump.spread;
        var x = clump.x + math.cos(angle) * dist;
        var z = clump.z + math.sin(angle) * dist;

        // 域扭曲：低频相干位移，打断"每格一撮"的周期性（俯视点阵感的根治手段）。
        x += _noise.fbm2(x * 0.11 + 23.0, z * 0.11 - 8.0, octaves: 2) * 0.8;
        z += _noise.fbm2(x * 0.11 - 15.0, z * 0.11 + 41.0, octaves: 2) * 0.8;

        final d = math.sqrt(x * x + z * z);
        if (d < innerRadius || d > outerRadius) continue;

        final height = 0.45 + _rng.nextDouble() * 0.55;
        final tintMix = patchTint * 0.7 + _rng.nextDouble() * 0.3;
        blades.add(GrassBlade(
          x: x,
          z: z,
          yaw: _rng.nextDouble() * math.pi * 2,
          height: height,
          phase: _rng.nextDouble() * math.pi * 2,
          tint: vm.Vector4(
            lerpDouble(0.24, 0.40, tintMix),
            lerpDouble(0.48, 0.78, tintMix),
            lerpDouble(0.17, 0.31, tintMix),
            1.0,
          ),
        ));
        if (blades.length >= maxBlades) break;
      }
    }
    return blades;
  }

  // ------------------------------------------------------------------
  // 几何与组装
  // ------------------------------------------------------------------

  /// 自定义草叶：底宽尖顶、带前弯的 4 级锥形叶片，顶点色根部暗 / 叶尖亮。
  ///
  /// 局部空间：根部在原点，叶尖在 (bend, 1, 0)，宽面朝 ±Z（双面渲染）。
  /// 6 个三角形，比 3 段圆柱还便宜，但弯曲 + 渐变让单叶的体积感强得多。
  ///
  /// 注意 `GeometryBuilder.color()` 是 sticky 的：必须在 `addVertex` 之前设置。
  MeshGeometry _buildBladeGeometry() {
    final builder = GeometryBuilder();

    // 每级：高度 t、半宽、沿弯曲方向的偏移、顶点色。
    // 半宽 7.2cm（14.4cm 底宽）：远处草靠 [build] 里的距离加宽维持屏幕覆盖率。
    const levels = <(double t, double halfWidth, double bend, (
      double r,
      double g,
      double b,
    ))>[
      (0.00, 0.072, 0.00, (0.42, 0.70, 0.32)), // 根部：暗（近似 AO）
      (0.35, 0.056, 0.018, (0.56, 0.84, 0.36)),
      (0.70, 0.031, 0.075, (0.74, 0.96, 0.42)),
      (1.00, 0.000, 0.170, (0.94, 1.00, 0.52)), // 叶尖：亮（近似透光）
    ];

    final verts = <int>[];
    for (final (t, hw, bend, c) in levels) {
      builder.color(vm.Vector4(c.$1, c.$2, c.$3, 1.0));
      verts.add(builder.addVertex(vm.Vector3(bend, t, -hw)));
      verts.add(builder.addVertex(vm.Vector3(bend, t, hw)));
    }

    for (var i = 0; i < levels.length - 1; i++) {
      final l0 = i * 2, r0 = i * 2 + 1;
      final l1 = i * 2 + 2, r1 = i * 2 + 3;
      builder
        ..addTriangle(verts[l0], verts[l1], verts[r0])
        ..addTriangle(verts[r0], verts[l1], verts[r1]);
    }

    return builder.build();
  }

  InstancedMesh build() {
    final mesh = InstancedMesh(
      geometry: _buildBladeGeometry(),
      material: PhysicallyBasedMaterial()
        ..baseColorFactor = vm.Vector4(1, 1, 1, 1) // 实际颜色 = 顶点色 × 实例色
        ..roughnessFactor = 0.9
        ..metallicFactor = 0.0
        ..doubleSided = true, // 薄片草叶两面都要可见
    );

    final blades = sampleLayout();

    _baseTransforms = List.generate(blades.length, (i) {
      final b = blades[i];
      // 让草叶顺着坡面站，避免陡坡上"插进去"或"悬空"；根部下沉 4cm。
      final y = terrain.heightAt(b.x, b.z) - 0.04;
      final normal = terrain.normalAt(b.x, b.z);

      // 贴坡 + 轻微随机倾斜（±3.4°）。
      final tiltX = normal.z * 0.55 + (b.phase - math.pi) * 0.06;
      final tiltZ = -normal.x * 0.55 + math.cos(b.phase) * 0.06;

      // 注意 vector_math 的 `Quaternion.euler(yaw, pitch, roll)` 是
      // **绕 Z / Y / X**（航空约定），不是直觉上的"绕 Y / X / Z"。
      // 这里用显式轴角组合，避免再踩错轴：先按坡面倾斜，再绕竖直轴转向。
      final rotation = vm.Quaternion.axisAngle(vm.Vector3(0.0, 1.0, 0.0), b.yaw) *
          vm.Quaternion.axisAngle(vm.Vector3(1.0, 0.0, 0.0), tiltX) *
          vm.Quaternion.axisAngle(vm.Vector3(0.0, 0.0, 1.0), tiltZ);

      // 只烘焙"叶高"，距离补偿留给 [applyWind]（它需要观察者位置）。
      return vm.Matrix4.compose(
        vm.Vector3(b.x, y, b.z),
        rotation,
        vm.Vector3(1.0, b.height, 1.0),
      );
    });

    for (var i = 0; i < blades.length; i++) {
      mesh.addInstance(_baseTransforms[i], color: blades[i].tint);
    }

    _bladeXZ = Float32List(blades.length * 2);
    for (var i = 0; i < blades.length; i++) {
      _bladeXZ[i * 2] = blades[i].x;
      _bladeXZ[i * 2 + 1] = blades[i].z;
    }
    windPhase = List.generate(blades.length, (i) => blades[i].phase);
    _mesh = mesh;
    return mesh;
  }

  // ------------------------------------------------------------------
  // 运行时
  // ------------------------------------------------------------------

  // scratch 必须是 identity：Matrix4.zero() 的 m15=0，setRotationZ 只写
  // 旋转块不动 w 分量 —— 乘出来的实例矩阵 w=0，裁剪空间未定义，
  // 表现就是"整片草只剩屏幕中心一撮退化三角形"（踩过的坑，别改回去）。
  final vm.Matrix4 _swayScratch = vm.Matrix4.identity();
  final vm.Matrix4 _scaleScratch = vm.Matrix4.identity();
  final vm.Matrix4 _rotScratch = vm.Matrix4.identity();
  final vm.Matrix4 _outScratch = vm.Matrix4.zero();

  /// 每帧更新实例矩阵：风摆 + 距离补偿（加宽 / 矮化）。
  ///
  /// 两个补偿**用不同的基准点**，这是两个不同的目的：
  ///
  ///   * **加宽用 [cameraPos]**：它补偿的是"叶片在屏幕上太窄被光栅化丢弃"
  ///     （远处没草的经典原因），而屏幕覆盖率本来就该以相机为基准。
  ///     用角色距离会出错：相机低视角贴近地面时，靠近相机但离角色远的
  ///     叶片会被当成"远景"加宽，在画面里变成巨型叶片（实测踩过）。
  ///   * **矮化用 [focus]（角色）**：目的是别让草挡住角色，所以基准是角色。
  ///     若也改用相机，角色周围 8.5m 处的草会接近全高，反而把角色埋掉。
  ///
  /// 成本说明：我们的循环不是瓶颈 —— 实测把更新子集从 46k 缩到 4k 帧率不变，
  /// 真正的开销在引擎侧「实例一变就重打包整块实例缓冲」，所以调用频率
  /// （见 world.dart 的 tick）才是控制 CPU 的旋钮。因此这里零分配、
  /// 且更新全部实例（远景摆动同样受益）。
  void applyWind(
    double time, {
    required vm.Vector3 focus,
    required vm.Vector3 cameraPos,
    double strength = 0.22,
    double gustScale = 0.12,
  }) {
    final mesh = _mesh;
    if (mesh == null) return;

    for (var i = 0; i < _baseTransforms.length; i++) {
      final base = _baseTransforms[i];
      final bx = _bladeXZ[i * 2];
      final bz = _bladeXZ[i * 2 + 1];

      final cdx = bx - cameraPos.x;
      final cdz = bz - cameraPos.z;
      final pdx = bx - focus.x;
      final pdz = bz - focus.z;
      final (widthScale, heightRamp) = distanceCompensation(
        cameraDistance: math.sqrt(cdx * cdx + cdz * cdz),
        playerDistance: math.sqrt(pdx * pdx + pdz * pdz),
      );

      final phase = windPhase[i] + bx * gustScale + bz * gustScale;
      final wave =
          math.sin(time * 1.6 + phase) + 0.45 * math.sin(time * 3.1 + phase * 1.7);
      final lean = wave * strength;

      // 先缩放（局部），再绕叶根倾斜，最后左乘基础矩阵。
      _scaleScratch
        ..setIdentity()
        ..setDiagonal(vm.Vector4(widthScale, heightRamp, widthScale, 1.0));
      _rotScratch
        ..setIdentity()
        ..setRotationZ(lean)
        ..rotateX(lean * 0.4);
      _swayScratch
        ..setFrom(_scaleScratch)
        ..multiply(_rotScratch);
      _outScratch
        ..setFrom(base)
        ..multiply(_swayScratch);
      mesh.setInstanceTransform(i, _outScratch);
    }
  }

  /// 整体显隐（天气或性能档位可以关掉草地）。
  ///
  /// 用零矩阵把实例"缩没有了"，而不是设 `visible`——实例化的隐藏走矩阵
  /// 是引擎里已经验证过的方式，不依赖额外的布尔字段。
  ///
  /// 恢复显示时用的是**基础矩阵**（不含距离补偿），下一次 [applyWind]
  /// 会把它补回来；间隔最多一帧，看不出来。
  void setVisible(bool visible) {
    final mesh = _mesh;
    if (mesh == null) return;
    if (!visible) {
      final zero = vm.Matrix4.zero();
      for (var i = 0; i < _baseTransforms.length; i++) {
        mesh.setInstanceTransform(i, zero);
      }
    } else {
      for (var i = 0; i < _baseTransforms.length; i++) {
        mesh.setInstanceTransform(i, _baseTransforms[i]);
      }
    }
  }
}

double lerpDouble(double a, double b, double t) => a + (b - a) * t;
