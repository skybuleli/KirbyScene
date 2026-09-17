/// 河床水生植物（水草）：长在**水面之下**的贴底草丛，随同一条水流摇曳。
///
/// ## 与岸边芦苇的分工（不要重叠）
///
/// `flora.dart` 的 `_buildReeds` 是**挺水**植物：长在水线上下 0.9m 的过渡带，
/// 一半露出水面，生态位是"水 → 湿沙 → 草"的黏合剂。本文件是**沉水**植物：
/// 从河床长起、整个株体都在水面以下，生态位是"河床上的植被带"。
/// 两者靠 [isInWater] 与"株顶必须低于水位"两条硬约束分开，绝不会互相插进对方
/// 的地盘（否则会出现"芦苇长在河心水底""水草穿出水面"两种穿帮）。
///
/// ## 分布怎么做到"自然错落"而不是"均匀撒点"
///
/// 只按一个密度场撒点，无论密度怎么调都会读成"点阵"（`flora.dart` 与
/// `grass.dart` 的文件头都总结过这条教训）。这里叠了**四层**规则，
/// 每一层解决一个具体的读感问题，实现见 [planSites] 与 [_densityAt]：
///
///   1. **水深分带（物种层）**：不同水草适应不同水深 —— 浅滩是贴底矮草/苔、
///      中水是细叶丛、深槽是能长高的带状长草。只看总密度的话，
///      整条河会长得"一模一样"，看不出水深的差别。
///   2. **低频成丛噪声（空间层）**：fbm 把密度调制出"成片草丛 + 成片空白河床"。
///      河床上必须有大块裸地，草丛才读得出来；处处稀稀拉拉等于没有丛。
///   3. **流速筛选（水动力层）**：`speedAt` 高的地方水草抓不住根 —— 主流区
///      稀疏甚至没有，近岸缓流带与深潭里密。这一层让"草的疏密"和"水的急缓"
///      在俯视图里直接对上，读者会下意识读成"水在管草"。
///   4. **抖动网格 + 个体差异（采样层）**：分层抖动格子保证不留系统性空穴，
///      格内抖动 + 低频域扭曲打断周期性；每株再给独立的朝向/株高/颜色/相位，
///      并且**每株放多个实例**（一丛多叶），所以近处也找不到两株一样的水草。
///
/// ## 为什么撒点与建网格必须分开
///
/// [planSites] 是**纯计算**：只读地形与流场，产出一串 [AquaticPlantSite] 值对象，
/// **完全不构造 flutter_scene 对象**。测试环境没有 Flutter GPU 上下文，
/// 构造 `InstancedMesh`/`Scene` 会直接抛异常；把"决策"与"上网格"切开之后，
/// 分布规律（只在水下、急流没有、成丛、物种随水深分带）就能在测试里直接断言，
/// 不必渲染一帧。[buildNodes] 只做一件事：把 site 变成三类 [InstancedMesh]。
///
/// ## 摇曳模型：一整片被同一股水推着
///
/// 每株的摆动相位取 `flow.flowPhase(z, time, omega)` + 个体随机相位。
/// `flowPhase` 里已经含了"沿程流时"（`travelTimeAt`），因此相位随下游推进，
/// 整片水草读成**一列向下游传播的行波**（弯腰的波顺着河走），而不是各自乱抖。
/// 摆动的铰链轴取 `flow.directionAt(x, z)` 的水平垂线 —— 草叶顺/逆流弯腰，
/// 弯道里还会跟着主泓偏摆。振幅与频率都随当地 `speedAt` 增大（缓流轻晃、
/// 急流压得低而快），并在急流里叠一个**向下的平均倾角**（被水压弯）。
///
/// 关键：旋转**绕根部**做（矩阵按 T·R·S 组合，平移在最外层），所以根部世界
/// 坐标在摆动中恒定 —— 水草像铰接在河床上，而不是整根平移（那是"漂"不是"摆"）。
/// 因为旋转把株高乘了进去，叶尖位移 ≈ 株高 × sin(摆角)，高草摆得远、矮草摆得近。
///
/// ## CPU 预算：这是动态实例
///
/// 与 `flora.dart` 的静态层不同，水草每帧要重写实例矩阵，引擎会因此重算
/// 整块实例缓冲的聚合包围盒（见 `instanced_mesh_component.dart` 对 `revision`
/// 的处理）。所以：总数控制在 ~1200–2500（[instanceBudget] 默认 2000），
/// 更新频率降到每 4 帧一次（[tick] 由 `world.dart` 节流，与草的风摆同量级的
/// 取舍），且 [tick] 内**零堆分配**（实例数据预存在 Float32List 里，
/// 矩阵/向量 scratch 复用）。
///
/// 关于引擎 API 的确认：`flutter_scene` 的 `InstancedMesh` **有**"改单个实例矩阵"
/// 的接口（`setInstanceTransform(index, matrix)`），所以不必整块重建实例列表。
/// 它另有批量接口 `updateInstanceTransforms(callback)`，但那个接口要求传一个
/// 回调闭包 —— 每帧构造闭包会造成堆分配，与本文件的"零分配"约束冲突，
/// 因此这里选择逐实例 `setInstanceTransform`。代价是它每次都标记聚合包围盒
/// 变脏并递增一次 `revision`（`InstancedMesh._boundsDirty = true; _revision++`），
/// 于是**每帧仍会重算一次整体的聚合包围盒** —— 这正是"降频到每 4 帧"要省的那份钱。
library;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'flow.dart';
import 'noise.dart';
import 'terrain.dart';

/// 三种形态的水草。形态多样性靠"每株放多个实例"（一丛多叶），
/// 不靠多份网格 —— 三类 = 三个 [InstancedMesh] = 三次 draw call。
enum AquaticSpecies {
  /// 带状水草：长带状叶片，2–4 片一丛，株高、摆幅都最大。
  /// 生态位是较深的槽与缓流区 —— 深水里光少，得往上长。
  bandedLeaves(
    label: 'banded',
    swayAmplitude: 0.42,
    swayOmega: 1.45,
    minHeight: 0.20,
    leanBase: 0.26,
    spreadRadius: 0.16,
    bladeWidth: 0.034,
    hueR: 0.98,
    hueG: 1.05,
    hueB: 0.84,
  ),

  /// 细叶丛：轮生细叶，中等高度，摆动幅度小些。中水深的"主力"。
  fineLeaf(
    label: 'fine',
    swayAmplitude: 0.22,
    swayOmega: 1.72,
    minHeight: 0.14,
    leanBase: 0.55,
    spreadRadius: 0.10,
    bladeWidth: 0.010,
    hueR: 0.90,
    hueG: 1.02,
    hueB: 1.12,
  ),

  /// 河床矮草/苔：贴底矮丛，几乎不摆。用来打破"只有高草"的单调，
  /// 占据浅滩与近岸那一片别的物种站不住的浅水。
  bedMoss(
    label: 'moss',
    swayAmplitude: 0.035,
    swayOmega: 1.10,
    minHeight: 0.05,
    leanBase: 0.16,
    spreadRadius: 0.13,
    bladeWidth: 0.055,
    hueR: 1.02,
    hueG: 0.98,
    hueB: 0.80,
  );

  const AquaticSpecies({
    required this.label,
    required this.swayAmplitude,
    required this.swayOmega,
    required this.minHeight,
    required this.leanBase,
    required this.spreadRadius,
    required this.bladeWidth,
    required this.hueR,
    required this.hueG,
    required this.hueB,
  });

  /// 诊断/计数用的短名。
  final String label;

  /// 摆动角度的基准振幅（弧度）。缓流乘 ~0.3、急流乘 ~1.0（见 [_swayAngleAt]）。
  final double swayAmplitude;

  /// 摆动角频率基准（rad/s）。缓流更慢、急流更快（见 [_swayAngleAt]）。
  final double swayOmega;

  /// 该物种能成立的最小株高（米）。水深不够就不放它。
  final double minHeight;

  /// 叶片向外倾的基准角（弧度）：细叶丛最散、矮苔最贴底。
  final double leanBase;

  /// 一丛内叶片离株根的最大水平展开半径（米）。
  final double spreadRadius;

  /// 叶片的地方宽（米）。实例还会再乘个体宽度系数。
  final double bladeWidth;

  /// 物种自身的色相乘子（水下衰减之外的一点点偏色）。
  final double hueR;
  final double hueG;
  final double hueB;

  /// 该株放几片叶（"每株多个实例"的具体数量）。
  int bladeCount(math.Random rng) => switch (this) {
        AquaticSpecies.bandedLeaves => 2 + rng.nextInt(3), // 2–4
        AquaticSpecies.fineLeaf => 4 + rng.nextInt(3), // 4–6
        AquaticSpecies.bedMoss => 2 + rng.nextInt(2), // 2–3
      };

  /// 该物种的"理想株高"（米）。真实高度还会被水深上限压住（见 [_siteAt]）。
  double preferredHeight(double r) => switch (this) {
        AquaticSpecies.bandedLeaves => 0.42 + r * 0.50, // 0.42–0.92
        AquaticSpecies.fineLeaf => 0.22 + r * 0.30, // 0.22–0.52
        AquaticSpecies.bedMoss => 0.06 + r * 0.11, // 0.06–0.17
      };
}

/// 一个水草落点（布局阶段的产物，纯数据、可单测）。
///
/// 这里刻意把"渲染要用的量"全部算好存下来（河床高、水位、水深、流速、
/// 横向位置、物种、株高、朝向、颜色、相位、流向），而不是留给 [buildNodes]
/// 现算 —— 这样测试能直接对 site 断言分布与物理约束，不必碰 GPU。
class AquaticPlantSite {
  AquaticPlantSite({
    required this.x,
    required this.z,
    required this.bedY,
    required this.waterY,
    required this.depth,
    required this.speed,
    required this.lateral,
    required this.species,
    required this.height,
    required this.yaw,
    required this.phase,
    required this.flowDirX,
    required this.flowDirZ,
    required this.bladeCount,
    required this.tint,
  });

  final double x;
  final double z;

  /// 根部世界 y（= 河床高 − 一点点入土量）。株体从这里往上长。
  final double bedY;

  /// 该处的水面高程（m）。
  final double waterY;

  /// 水柱深度（m）：`waterY − 河床高`。物种分带与颜色衰减都用它。
  final double depth;

  /// 当地**表层**流速（m/s），来自 [RiverFlow.speedAt]。
  final double speed;

  /// 横向归一化位置（0 = 河心，1 = 岸边），来自 [RiverFlow.lateralAt]。
  final double lateral;

  final AquaticSpecies species;

  /// 株高（米）。**这是该株最高一片叶的高度**，且保证
  /// `bedY + height ≤ waterY − 5cm`（株顶不穿出水面）。
  final double height;

  /// 该株（丛）的主朝向，弧度。
  final double yaw;

  /// 个体摆动相位（弧度），打散整片水草的同步性。
  final double phase;

  /// 当地流向的水平分量（单位向量，指向下游）。
  final double flowDirX;
  final double flowDirZ;

  /// 该株拆成几个实例（叶片数）。
  final int bladeCount;

  /// 水下衰减后的实例色（越深越暗越偏蓝绿）。
  final vm.Vector4 tint;

  /// 株顶的世界高度（米）。比 [height] 更直观，测试与诊断都用它。
  double get tipY => bedY + height;
}

/// 河床水草系统。
///
/// 数据流：`RiverFlow`（唯一水动力源）+ `Terrain`（唯一高度源）→ [planSites]
/// （纯计算）→ [buildNodes]（三个 InstancedMesh）→ [tick]（每 4 帧重写摆姿）。
class AquaticFlora {
  AquaticFlora({
    required this.terrain,
    required this.flow,
    this.instanceBudget = 2000,
    int seed = 311,
  })  : _seed = seed,
        _noise = ValueNoise(seed: seed ^ 0x2a9f1);

  final Terrain terrain;

  /// 全项目唯一的水动力数据源。水草**不允许**另编流速/水位/流向公式。
  final RiverFlow flow;

  /// 实例预算（三个网格的实例数上限之和）。
  ///
  /// 1200–2500 是"够读出成丛、又不至于让每帧重打包实例缓冲"的区间。
  /// 预算按"离原点的距离"优先给近处（与 `flora.dart`、`grass.dart` 同一策略）。
  final int instanceBudget;

  final int _seed;
  final ValueNoise _noise;

  final Map<String, int> _counts = {};

  /// 三类的实例数据（构建后填充，供 [tick] 复用）。
  List<_SpeciesMesh> _batches = const [];

  /// 株顶离水面至少保留的余量（米）。水草穿出水面是最明显的穿帮，宁可矮一点。
  static const double minClearance = 0.05;

  /// 流速上限（m/s）：超过它的地方水草抓不住根，密度为 0。
  ///
  /// 0.45 取在实测流速分布的第 75 分位附近（本河道表层流速中位 ~0.22、
  /// 第 90 分位 ~0.53、最大 ~0.87），于是"主流区确实空出来一片、
  /// 缓流与近岸确实密"，而不是所有地方都被一刀切掉。
  static const double speedCutoff = 0.45;

  /// 流速筛选的下起点：低于它算全密度，往 [speedCutoff] 平滑降到 0。
  static const double _speedSoftStart = 0.10;

  /// 允许生长的最小水深（米）。太浅既站不住根、也留不出 5cm 的出水余量。
  static const double _minDepth = 0.16;

  /// 根部入土量（米）：让水草像"扎在河床里"而不是"摆在地上"。
  static const double _sink = 0.015;

  /// 理想密度的基准（株/m²，未乘任何调制）。调它等于调整条河的疏密。
  ///
  /// 4.0 配下面三层调制（流速 × 近岸 × 成丛 × 水深）后，整条河的自然产量约
  /// 1900 个实例 —— 正好让默认预算 2000 成为临界约束：预算不够时先裁远景，
  /// 而不是让近处的草变稀。
  static const double _baseDensity = 4.0;

  /// 分层采样的格子边长（米）≈ 一株水草的占地尺度。
  static const double _cell = 0.85;

  /// 布局阶段产物（缓存，避免重复撒点）。
  List<AquaticPlantSite>? _sites;

  /// 各类的数量快照：`aquaticSites` / `aquaticInstances` / 每类的 `aquaticXxx`。
  /// 与 `flora.dart` 的 `counts` 同义，供 MCP 诊断面板读。
  Map<String, int> get counts => _counts;

  // ------------------------------------------------------------------
  // 布局（纯计算，可单测）
  // ------------------------------------------------------------------

  /// 撒点：把整条河道的候选格按"离原点近"排序，逐格按 [_densityAt] 泊松化放点，
  /// 产出全部落点。**不构造任何 flutter_scene 对象**。
  ///
  /// 参考 `flora.dart` 的 `scatter()`（同构的分层抖动采样器），但规则不同：
  /// 那里撒在整个圆盘上、靠离水距离决定成败；这里只沿河道铺格，
  /// 用流速筛选 + 成丛噪声决定疏密。
  List<AquaticPlantSite> planSites() {
    final cached = _sites;
    if (cached != null) return cached;

    // 固定种子：同一 seed 调用多少次结果都一样，测试才能钉住分布规律。
    final rng = math.Random(_seed);
    final zTop = math.min(flow.river.zStart, 64.0);
    final zBottom = math.max(flow.river.zEnd, -64.0);

    // 候选格：沿 z 分行，每行沿水面宽度分格（随河道弯曲，格线跟着河走）。
    final cells = <_Cell>[];
    for (var z = zTop - _cell * 0.5; z > zBottom; z -= _cell) {
      final (left, right) = flow.banksAt(z);
      final width = right - left;
      if (width <= 0.6) continue;
      final n = math.max(1, (width / _cell).ceil());
      final step = width / n;
      for (var i = 0; i < n; i++) {
        final cx = left + (i + 0.5) * step;
        // 排序键 = 离原点距离 + 抖动：预算不够时先裁远景（近处玩家看得最清），
        // 抖动则避免裁出一条生硬的圆弧边界。
        final d = math.sqrt(cx * cx + z * z);
        cells.add(_Cell(cx, z, step, d + rng.nextDouble() * 4.0));
      }
    }
    // 第 4 层的"分层"部分：按格排序后再逐格放点 —— 保证不留系统性空穴。
    cells.sort((a, b) => a.key.compareTo(b.key));

    final result = <AquaticPlantSite>[];
    var usedInstances = 0;
    var budgetFull = false;
    for (final c in cells) {
      if (budgetFull) break;

      final density = _densityAt(c.x, c.z);
      if (density <= 0) continue;

      // 泊松化：整数部分直接放，小数部分按概率进位。
      final expected = density * c.step * _cell;
      var count = expected.floor();
      if (rng.nextDouble() < expected - count) count++;
      if (count <= 0) continue;

      for (var k = 0; k < count; k++) {
        // 格内抖动（第 4 层）。
        var x = c.x + (rng.nextDouble() - 0.5) * c.step;
        var z = c.z + (rng.nextDouble() - 0.5) * _cell;

        // 域扭曲：低频相干位移，打断"每格都有"的周期感（俯视尤其明显）。
        // 与 `flora.dart` / `grass.dart` 同一手法，只是尺度按河道收窄。
        x += _noise.fbm2(x * 0.13 + 41.0, z * 0.13 - 17.0, octaves: 2) * 0.5;
        z += _noise.fbm2(x * 0.13 - 29.0, z * 0.13 + 53.0, octaves: 2) * 0.5;

        final site = _siteAt(x, z, rng);
        if (site == null) continue;
        // 硬预算：整株要么全放、要么不放（不裁剪"半株"，否则丛会缺叶）。
        // 预算满时按排序先停 —— 损失的是远景（`flora.dart` / `grass.dart`
        // 的同一取舍）。
        if (usedInstances + site.bladeCount > instanceBudget) {
          budgetFull = true;
          break;
        }
        result.add(site);
        usedInstances += site.bladeCount;
      }
    }

    _sites = result;
    return result;
  }

  /// 某点的水草密度（株/m²，未泊松化）。四层规则在这里合成。
  double _densityAt(double x, double z) {
    final bed = terrain.heightAt(x, z);
    final waterY = flow.waterYAt(z);
    final depth = waterY - bed;
    if (depth < _minDepth) return 0.0; // 太浅：站不住根，也留不出出水余量

    final lateral = flow.lateralAt(x, z);
    if (lateral > 1.12) return 0.0; // 已经上岸

    // 第 3 层：流速筛选。急流里根系抓不住河床 —— 密度随流速平滑趋 0。
    final speed = flow.speedAt(x, z);
    if (speed >= speedCutoff) return 0.0;
    final speedOk =
        ((speedCutoff - speed) / (speedCutoff - _speedSoftStart)).clamp(0.0, 1.0);

    // 近岸缓流带加成：边界层让近岸流速低（[RiverFlow.speedAt] 已含），
    // 这里再补一点权重，让"近岸密、河心疏"更明确 —— 现实里也是缓流处沉积
    // 有机质、水草最旺。
    final shore = 0.60 + 0.70 * lateral.clamp(0.0, 1.0);

    // 第 2 层：低频成丛噪声。fbm 高的地方连成一片草丛，低的地方留出裸河床。
    // 指数 1.7 把"丛 / 空白"的对比拉开；不拉的话全河都是中等密度，
    // 读起来还是"点上撒了草"。
    final clump = _noise.fbm2(x * 0.055 + 9.0, z * 0.055 - 4.0, octaves: 3);
    final clumpiness = ((clump + 0.25) / 0.75).clamp(0.0, 1.0);
    final patch = math.pow(clumpiness, 1.7).toDouble();

    // 贴边浅水与极深槽都略降（前者是水位涨落的冲刷带，后者光太弱）。
    final depthFade = _smoothstep(_minDepth, _minDepth + 0.15, depth) *
        (1.0 - 0.35 * _smoothstep(1.6, 2.6, depth));

    return _baseDensity * speedOk * shore * (0.06 + 0.94 * patch) * depthFade;
  }

  /// 把一个候选坐标判定为一株水草（或 null = 这里不长）。
  ///
  /// 四条硬约束都在这里落地：在水下、水深够、流速够慢、株顶留 5cm 余量。
  AquaticPlantSite? _siteAt(double x, double z, math.Random rng) {
    final bed = terrain.heightAt(x, z);
    final waterY = flow.waterYAt(z);
    final depth = waterY - bed;
    if (depth < _minDepth) return null;

    final lateral = flow.lateralAt(x, z);
    if (lateral > 1.12) return null;

    final speed = flow.speedAt(x, z);
    if (speed >= speedCutoff) return null;

    // 第 1 层：按水深挑物种（浅 → 矮苔，中 → 细叶丛，深 → 带状长草）。
    final species = _pickSpecies(depth, rng);

    final rootY = bed - _sink;
    // 株高分两步：先取物种的理想高度，再用"水位 − 余量 − 根高"压住上限，
    // 于是**株顶永远比水面低 5cm 以上**（穿出水面是最明显的穿帮）。
    final maxHeight = waterY - minClearance - rootY;
    if (maxHeight < species.minHeight) return null; // 这里的水深不够这个物种

    final height = math.min(species.preferredHeight(rng.nextDouble()), maxHeight);
    final dir = flow.directionAt(x, z);

    return AquaticPlantSite(
      x: x,
      z: z,
      bedY: rootY,
      waterY: waterY,
      depth: depth,
      speed: speed,
      lateral: lateral,
      species: species,
      height: height,
      yaw: rng.nextDouble() * math.pi * 2.0,
      phase: rng.nextDouble() * math.pi * 2.0,
      flowDirX: dir.x,
      flowDirZ: dir.y,
      bladeCount: species.bladeCount(rng),
      tint: _underwaterTint(depth, species, rng.nextDouble()),
    );
  }

  /// 按水深挑物种（加权随机，权重平滑过渡 → 不会出现一条生硬的物种分界线）。
  AquaticSpecies _pickSpecies(double depth, math.Random rng) {
    // 浅滩矮苔、深槽长草；细叶丛吃中间，两端略退。
    final wMoss = 1.0 - _smoothstep(0.30, 0.68, depth);
    final wBanded = _smoothstep(0.55, 1.05, depth);
    final wFine = (1.0 - _smoothstep(0.95, 1.45, depth)) *
        _smoothstep(0.10, 0.42, depth);

    final total = wMoss + wBanded + wFine;
    if (total <= 1e-6) return AquaticSpecies.fineLeaf; // 兜底（理论上不会到）
    var r = rng.nextDouble() * total;
    if (r < wMoss) return AquaticSpecies.bedMoss;
    r -= wMoss;
    if (r < wBanded) return AquaticSpecies.bandedLeaves;
    return AquaticSpecies.fineLeaf;
  }

  /// 水下光衰减配色：越深越暗、越偏蓝绿；越浅越亮、越偏黄绿。
  ///
  /// 这一层让"深处的水草"和"浅处的水草"在画面里一眼可分 —— 也是玩家判断
  /// 河道深浅的视觉线索（水本身半透明，草色是水深最直接的读数）。
  vm.Vector4 _underwaterTint(
    double depth,
    AquaticSpecies species,
    double tone01,
  ) {
    final t = ((depth - 0.18) / 1.30).clamp(0.0, 1.0); // 0 浅 → 1 深
    final tone = 0.84 + tone01 * 0.30; // 同深度个体也有深浅差异
    return vm.Vector4(
      (_lerp(0.40, 0.05, t) * species.hueR * tone).clamp(0.0, 1.0),
      (_lerp(0.70, 0.19, t) * species.hueG * tone).clamp(0.0, 1.0),
      (_lerp(0.24, 0.22, t) * species.hueB * tone).clamp(0.0, 1.0),
      1.0,
    );
  }

  // ------------------------------------------------------------------
  // 摇曳（纯计算部分，可单测）
  // ------------------------------------------------------------------

  /// 该株在 [time] 时刻的摆动角（弧度，绕流速垂线，正 = 向下游弯）。
  ///
  /// 振幅与频率都随当地流速增大；另叠一个与流速成正比的**平均倾角**，
  /// 表达"急流把草压得低"。
  double swayAngle(AquaticPlantSite site, double time) => _swayAngleAt(
        site.speed,
        site.z,
        site.species.swayAmplitude,
        site.species.swayOmega,
        site.phase,
        time,
      );

  /// 该株当前的摆动角频率（rad/s）＝ 基准 × 流速系数。测试算周期用。
  double swayOmega(AquaticPlantSite site) =>
      site.species.swayOmega * _omegaFactor(site.speed);

  double _omegaFactor(double speed) =>
      0.55 + 1.30 * (speed / speedCutoff).clamp(0.0, 1.0);

  double _swayAngleAt(
    double speed,
    double z,
    double amplitudeBase,
    double omegaBase,
    double phase,
    double time,
  ) {
    final t = (speed / speedCutoff).clamp(0.0, 1.0);
    final amplitude = amplitudeBase * (0.30 + 0.70 * t); // 急流摆得大
    final omega = omegaBase * _omegaFactor(speed); // 急流摆得快
    // 相位取自流场：沿程流时让整片草读成一列向下游传播的波（同一股水）。
    final wave = flow.flowPhase(z, time, omega) + phase;
    final mean = amplitudeBase * 0.85 * t; // 被水压弯的平均倾角（向下游）
    return mean + amplitude * math.sin(wave);
  }

  /// 某株在 [time] 时刻的实例矩阵（**绕根部旋转**）。
  ///
  /// 纯函数：测试用它验证"根部不动""急流摆幅更大""叶尖只沿流向偏移"，
  /// 不需要 GPU。[dx]/[dz] 是丛内第 k 片叶相对株根的水平偏移。
  vm.Matrix4 swayMatrixFor(
    AquaticPlantSite site,
    double time, {
    double dx = 0.0,
    double dz = 0.0,
  }) {
    final out = vm.Matrix4.identity();
    _composeInto(
      out,
      rootX: site.x + dx,
      rootY: site.bedY,
      rootZ: site.z + dz,
      height: site.height,
      width: 1.0,
      yaw: site.yaw,
      lean: 0.0,
      leanAxisX: 1.0,
      leanAxisZ: 0.0,
      flowX: site.flowDirX,
      flowZ: site.flowDirZ,
      swayAngle: swayAngle(site, time),
    );
    return out;
  }

  // 复用的 scratch：tick 内零分配的保证。identity 而非 zero（zero 的 m15=0，
  // 裁剪空间会退化，`grass.dart` 里踩过这个坑）。
  final vm.Matrix4 _scratch = vm.Matrix4.identity();
  final vm.Vector3 _axis = vm.Vector3.zero();

  /// 组合一株的实例矩阵：**T · R_sway · R_yaw · R_lean · S**。
  ///
  /// 平移在最外层且最先写入，因此无论怎么旋转，根部世界坐标恒为
  /// `(rootX, rootY, rootZ)` —— 这就是"铰接在河床上"。缩放同样在里面，
  /// 于是叶尖位移随株高线性放大（高草摆得远）。
  void _composeInto(
    vm.Matrix4 out, {
    required double rootX,
    required double rootY,
    required double rootZ,
    required double height,
    required double width,
    required double yaw,
    required double lean,
    required double leanAxisX,
    required double leanAxisZ,
    required double flowX,
    required double flowZ,
    required double swayAngle,
  }) {
    // 摆动的铰链轴 = 流向的水平垂线。绕它旋转，叶尖就顺/逆流向倾倒
    // （在 (x,z) 平面上，叶尖水平位移方向恰好平行于流向）。
    out
      ..setIdentity()
      ..translateByDouble(rootX, rootY, rootZ, 1.0)
      ..rotate(_axis..setValues(flowZ, 0.0, -flowX), swayAngle)
      ..rotate(_axis..setValues(0.0, 1.0, 0.0), yaw)
      ..rotate(_axis..setValues(leanAxisX, 0.0, leanAxisZ), lean)
      ..scaleByDouble(width, height, width, 1.0);
  }

  // ------------------------------------------------------------------
  // 几何（一律"根部在局部原点、株尖在 y=1"，才能绕根旋转）
  // ------------------------------------------------------------------

  /// 单位高度的带状叶片：根部在 (0,0,0)，叶尖在 (bend, 1, 0)，
  /// 宽面朝 ±Z。顶点色根部暗、叶尖亮（水下光来自上方，叶尖受光更多）。
  ///
  /// 根部放在局部原点、株尖放在 y=1 是关键：实例矩阵用 `S(1, height, 1)`
  /// 缩放出真实株高，旋转又是绕局部原点 —— 于是旋转天然绕根。
  /// 若换成引擎自带的 `CylinderGeometry`（竖直居中，根部在 y=−0.5），
  /// 旋转就会绕几何中心，草叶会像扇子一样从半腰折，而不是从根铰接。
  MeshGeometry _bladeGeometry({
    required double halfWidth,
    required double bend,
    required int levels,
  }) {
    final b = GeometryBuilder();
    final left = <int>[];
    final right = <int>[];
    for (var i = 0; i < levels; i++) {
      final t = i / (levels - 1);
      final hw = halfWidth * (1.0 - 0.9 * t * t);
      final c = vm.Vector4(
        _lerp(0.46, 1.00, t),
        _lerp(0.56, 1.05, t),
        _lerp(0.48, 0.96, t),
        1.0,
      );
      b.color(c); // sticky：必须在下一次 addVertex 之前设置
      left.add(b.addVertex(vm.Vector3(bend * t * t, t, -hw)));
      right.add(b.addVertex(vm.Vector3(bend * t * t, t, hw)));
    }
    for (var i = 0; i < levels - 1; i++) {
      b
        ..addTriangle(left[i], left[i + 1], right[i])
        ..addTriangle(right[i], right[i + 1], left[i + 1]);
    }
    return b.build();
  }

  MeshGeometry _geometryFor(AquaticSpecies species) => switch (species) {
        // 带状水草：宽、长、明显前弯（分 5 级，弯曲更平滑）。
        AquaticSpecies.bandedLeaves =>
          _bladeGeometry(halfWidth: 0.032, bend: 0.30, levels: 5),
        // 细叶丛：极窄的针叶（轮生，靠 buildNodes 的花瓣式排布）。
        AquaticSpecies.fineLeaf =>
          _bladeGeometry(halfWidth: 0.009, bend: 0.22, levels: 4),
        // 矮苔：短而宽的叶片，几乎不弯（贴底）。
        AquaticSpecies.bedMoss =>
          _bladeGeometry(halfWidth: 0.055, bend: 0.03, levels: 3),
      };

  PhysicallyBasedMaterial _plantMaterial() => PhysicallyBasedMaterial()
    ..baseColorFactor = vm.Vector4(1, 1, 1, 1) // 颜色 = 顶点色 × 实例色
    ..roughnessFactor = 0.82
    ..metallicFactor = 0.0
    ..doubleSided = true;

  // ------------------------------------------------------------------
  // 组装
  // ------------------------------------------------------------------

  /// 把 [planSites] 的落点变成三个 [InstancedMesh]（每类一次 draw call）。
  List<Node> buildNodes() {
    final sites = planSites();

    // 先按物种统计实例数，据此一次性预分配（避免构建期反复扩容）。
    final totals = <AquaticSpecies, int>{};
    for (final s in sites) {
      totals[s.species] = (totals[s.species] ?? 0) + s.bladeCount;
    }

    final batches = <AquaticSpecies, _SpeciesMesh>{
      for (final sp in AquaticSpecies.values)
        sp: _SpeciesMesh(
          species: sp,
          mesh: InstancedMesh(
            geometry: _geometryFor(sp),
            material: _plantMaterial(),
          ),
          capacity: totals[sp] ?? 0,
        ),
    };

    // 每片叶的细节（丛内偏移、朝向、倾角、高度、色调）用独立的随机源，
    // 与撒点的随机源分开 —— 撒点是否重跑都不影响实例外观的可复现性。
    final rng = math.Random(_seed ^ 0x51a2f);

    for (final site in sites) {
      final batch = batches[site.species]!;
      final sp = site.species;
      final maxHeight = site.waterY - minClearance - site.bedY;

      for (var k = 0; k < site.bladeCount; k++) {
        final ang = rng.nextDouble() * math.pi * 2.0;
        final rad = 0.03 + rng.nextDouble() * sp.spreadRadius;
        final dx = math.cos(ang) * rad;
        final dz = math.sin(ang) * rad;

        // 叶片高度 ≤ 该株株高（株高已经是"最高叶"），于是 site 的出水约束
        // 直接覆盖到每片叶，不会出现某片叶偷偷顶出水面。
        var h = site.height * (0.66 + rng.nextDouble() * 0.34);
        if (h > maxHeight) h = maxHeight;

        // 朝向：细叶丛均匀轮生（一圈散开），其余物种绕主朝向小幅散开。
        final double yaw;
        if (sp == AquaticSpecies.fineLeaf) {
          yaw = k / site.bladeCount * math.pi * 2.0 + (rng.nextDouble() - 0.5) * 0.8;
        } else {
          yaw = site.yaw + (rng.nextDouble() - 0.5) * 1.3;
        }

        // 叶片向外倾：铰链轴取"沿叶片弯曲方向的垂线"，绕它转就是叶尖继续前倾。
        final bendX = math.cos(yaw);
        final bendZ = -math.sin(yaw);
        final lean = sp.leanBase * (0.35 + rng.nextDouble() * 0.9);

        final tone = 0.90 + rng.nextDouble() * 0.22;
        final tint = vm.Vector4(
          (site.tint.r * tone).clamp(0.0, 1.0),
          (site.tint.g * tone).clamp(0.0, 1.0),
          (site.tint.b * tone).clamp(0.0, 1.0),
          1.0,
        );

        // 初始姿态取 time = 0：首帧就摆好，不会先闪一下"笔直"的草。
        _composeInto(
          _scratch,
          rootX: site.x + dx,
          rootY: site.bedY,
          rootZ: site.z + dz,
          height: h,
          width: sp.bladeWidth * (0.82 + rng.nextDouble() * 0.42),
          yaw: yaw,
          lean: lean,
          leanAxisX: bendZ,
          leanAxisZ: -bendX,
          flowX: site.flowDirX,
          flowZ: site.flowDirZ,
          swayAngle: _swayAngleAt(site.speed, site.z, sp.swayAmplitude,
              sp.swayOmega, site.phase, 0.0),
        );

        batch.add(
          tint: tint,
          matrix: _scratch,
          rootX: site.x + dx,
          rootY: site.bedY,
          rootZ: site.z + dz,
          phaseZ: site.z,
          height: h,
          width: sp.bladeWidth,
          yaw: yaw,
          lean: lean,
          leanAxisX: bendZ,
          leanAxisZ: -bendX,
          flowX: site.flowDirX,
          flowZ: site.flowDirZ,
          speed: site.speed,
          phase: site.phase,
        );
      }
    }

    _batches = batches.values.toList(growable: false);

    var instances = 0;
    for (final sp in AquaticSpecies.values) {
      final batch = batches[sp]!;
      _counts['aquatic${_cap(sp.label)}'] = batch.count;
      instances += batch.count;
    }
    _counts['aquaticSites'] = sites.length;
    _counts['aquaticInstances'] = instances;

    return [
      for (final sp in AquaticSpecies.values)
        Node(name: 'aquatic${_cap(sp.label)}')
          ..addComponent(InstancedMeshComponent(batches[sp]!.mesh)),
    ];
  }

  /// 每 4 帧调一次（由 `world.dart` 节流）：重写全部实例矩阵为 [time] 的摆姿。
  ///
  /// **零堆分配**：实例数据在 Float32List 里，矩阵/向量用 scratch 复用。
  /// 与 `grass.dart` 的 `applyWind` 同理，真正的开销在引擎侧"实例一变就
  /// 重算整块实例缓冲的聚合包围盒"，所以控制 CPU 的旋钮是**调用频率**，
  /// 不是循环里的算术。
  void tick(double time) {
    for (final batch in _batches) {
      final mesh = batch.mesh;
      final amplitude = batch.species.swayAmplitude;
      final omega = batch.species.swayOmega;
      for (var i = 0; i < batch.count; i++) {
        _composeInto(
          _scratch,
          rootX: batch.rootX[i],
          rootY: batch.rootY[i],
          rootZ: batch.rootZ[i],
          height: batch.height[i],
          width: batch.width[i],
          yaw: batch.yaw[i],
          lean: batch.lean[i],
          leanAxisX: batch.leanAxisX[i],
          leanAxisZ: batch.leanAxisZ[i],
          flowX: batch.flowX[i],
          flowZ: batch.flowZ[i],
          swayAngle: _swayAngleAt(
            batch.speed[i],
            batch.phaseZ[i],
            amplitude,
            omega,
            batch.phase[i],
            time,
          ),
        );
        mesh.setInstanceTransform(i, _scratch);
      }
    }
  }

  static String _cap(String s) => s[0].toUpperCase() + s.substring(1);
}

/// 一类水草的实例数据。所有数组在构建时一次性预分配，[AquaticFlora.tick]
/// 只读（+ 写引擎里的矩阵），因此不产生堆分配。
class _SpeciesMesh {
  _SpeciesMesh({
    required this.species,
    required this.mesh,
    required int capacity,
  })  : rootX = Float32List(capacity),
        rootY = Float32List(capacity),
        rootZ = Float32List(capacity),
        height = Float32List(capacity),
        width = Float32List(capacity),
        yaw = Float32List(capacity),
        lean = Float32List(capacity),
        leanAxisX = Float32List(capacity),
        leanAxisZ = Float32List(capacity),
        flowX = Float32List(capacity),
        flowZ = Float32List(capacity),
        speed = Float32List(capacity),
        phaseZ = Float32List(capacity),
        phase = Float32List(capacity);

  final AquaticSpecies species;
  final InstancedMesh mesh;

  int count = 0;

  final Float32List rootX;
  final Float32List rootY;
  final Float32List rootZ;
  final Float32List height;
  final Float32List width;
  final Float32List yaw;
  final Float32List lean;
  final Float32List leanAxisX;
  final Float32List leanAxisZ;
  final Float32List flowX;
  final Float32List flowZ;
  final Float32List speed;

  /// 该实例所在株的河道坐标 z（摆动相位沿 z 推进，用株根 z 而非叶根 z，
  /// 保证同丛的叶片相位一致）。
  final Float32List phaseZ;

  final Float32List phase;

  /// 写入第 [count] 个实例（同时把矩阵登记进网格）。
  void add({
    required vm.Vector4 tint,
    required vm.Matrix4 matrix,
    required double rootX,
    required double rootY,
    required double rootZ,
    required double phaseZ,
    required double height,
    required double width,
    required double yaw,
    required double lean,
    required double leanAxisX,
    required double leanAxisZ,
    required double flowX,
    required double flowZ,
    required double speed,
    required double phase,
  }) {
    final i = count;
    this.rootX[i] = rootX;
    this.rootY[i] = rootY;
    this.rootZ[i] = rootZ;
    this.height[i] = height;
    this.width[i] = width;
    this.yaw[i] = yaw;
    this.lean[i] = lean;
    this.leanAxisX[i] = leanAxisX;
    this.leanAxisZ[i] = leanAxisZ;
    this.flowX[i] = flowX;
    this.flowZ[i] = flowZ;
    this.speed[i] = speed;
    this.phaseZ[i] = phaseZ;
    this.phase[i] = phase;
    count++;
    mesh.addInstance(matrix, color: tint);
  }
}

/// 候选格（沿河道铺的分层抖动网格的一格）。
class _Cell {
  _Cell(this.x, this.z, this.step, this.key);

  final double x;
  final double z;
  final double step;
  final double key;
}

double _lerp(double a, double b, double t) => a + (b - a) * t;

/// 平滑阶跃：0（≤edge0）→ 1（≥edge1），用来做物种分带与淡入淡出。
double _smoothstep(double edge0, double edge1, double x) {
  final t = ((x - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
  return t * t * (3.0 - 2.0 * t);
}
