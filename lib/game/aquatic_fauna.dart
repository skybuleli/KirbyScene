/// 河里的**移动生物层**：鱼群与贴底虾。
///
/// ## 与其它模块的分工
///
///   * `flow.dart` —— 水动力数据源（流速/流向/水深/湍流）；
///   * `water_waves.dart` + `water.dart` —— 水面（水动力学在**水面**上的表现）；
///   * `aquatic_flora.dart` —— 沉水植物（水动力学下的**静物**）；
///   * 本文件 —— 水里**会自己动**的东西：鱼（游动 / 惊逃 / 跃出）与虾
///     （爬行 / 弹射 / 停歇）。
///
/// 三者共享同一个 [RiverFlow]：鱼的位移被水流推着走、虾贴着同一条河床爬、
/// 跃出水面落回时产生的那圈涟漪直接交给 `WaterSurface.addRipple`。
/// 于是"波纹往哪边涌、水草往哪边倒、鱼往哪边游"读起来是同一条河。
///
/// ## 行为怎么才不像"机器鱼"
///
/// 只让每条鱼朝一个随机点匀速游，无论参数怎么调都读成鱼雷：个体同频、
/// 转弯半径一致、永不休息。这里叠了四层，每层解决一个具体的读感问题：
///
///   1. **群体（school）**：鱼分 4 群，每群有一个缓慢漂移的群心；成员的目标点
///      混入群心权重 —— 于是既有"几条同向游"的群游段落，也有散开各自觅食的
///      段落。没有这一层，36 条鱼会变成 36 个互不相干的独立个体。
///   2. **水动力耦合**：位移 = 自身游速指向目标 **+ 水流速度 × 拖曳系数**。
///      逆流上溯时"顶水前进"、顺流时加速掠过、急流里被推歪 —— 这正是
///      "活在水里"与"在水面上滑行"的区别（`flow.speedAt` / `directionAt`）。
///   3. **状态机 cruising / startled / breaching**：玩家靠近会惊起 —— 多数鱼
///      加速逃开并下潜，其中一部分直接**跳出水面**，落水时在水面留下一圈涟漪。
///      除此之外鱼也会**自发跃出**（隔 9–26 秒一次，觅食/换气的真实行为）：
///      只靠"玩家靠近才惊跳"的话，玩家站着不动时整条河在画面上是静止的，
///      而"走到河边站定就能看到有鱼蹦出来"才是这条河活着的直接证据。
///      另外到达目标点会短暂停歇（鱼不是永动机）。
///   4. **个体差异**：体长、体色、巡游速度、尾摆频率与振幅、巡游水层
///      （小鱼贴水面、大鱼沉底）全部逐条独立，近处也找不出两条一样的。
///
/// 虾是另一套节奏：贴河床、慢、时常静止，受惊时**尾部弹射**（瞬间向后冲出
/// 一小段再停住）。它们负责水下那点细碎动静，让河床不至于是一张静物画。
///
/// ## 为什么"决策"与"上网格"必须分开
///
/// 与 `aquatic_flora.dart` 同样的理由：`flutter_scene` 的 `Scene` /
/// `InstancedMesh` 构造函数会**同步**取 Flutter GPU 上下文，测试环境里直接抛。
/// 所以 [advance] 是纯计算（只改 Float64List/Float32List 里的状态、不碰引擎
/// 对象），[applyTransforms] 才把状态写成实例矩阵。这样"鱼不会游上岸"
/// "惊逃确实远离玩家""跃出之后一定回到水里并发出涟漪"这些**行为契约**
/// 才能在单测里钉死，而不必渲染一帧。
///
/// ## CPU 预算
///
/// 鱼 36 条（身体 + 尾鳍 = 72 个实例）+ 虾 48 只 = 120 个实例。相比草地的
/// 11 万实例，矩阵重写是零头；但它们**每帧都在变**，而引擎在实例矩阵变动时会
/// 重算整块实例缓冲的聚合包围盒。所以世界层仍然分两档：[advance] 每帧跑
/// （游动轨迹连续），[applyTransforms] 每 2 帧写一次矩阵（可视姿态 30Hz）。
/// [advance] 内**零堆分配**：状态全在预分配的 `Float64List` 里，矩阵/四元数
/// 用 scratch 复用。
library;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'flow.dart';
import 'terrain.dart';

/// 鱼的行动模式。
enum FishMood {
  /// 巡游：朝目标点游，偶尔停歇。
  cruising,

  /// 惊逃：玩家靠得太近，加速远离并下潜。
  startled,

  /// 跃出：离开水面走抛物线，落回时在水面留一圈涟漪。
  breaching,
}

/// 虾的行为状态。
enum ShrimpState {
  /// 爬行：沿河床缓慢移动。
  crawling,

  /// 弹射：尾部急速摆动向后冲出（受惊）。
  darting,

  /// 停歇：原地不动，只轻微摆动触须。
  resting,
}

/// 一次入水事件（鱼跃出后落回水面）。世界层把它转给水面的涟漪系统，
/// 音效层用它触发一声"扑通"。
///
/// **槽位是复用的**：[AquaticFauna.advance] 每次只更新已有对象的字段，
/// 不新建对象（避免每帧堆分配）。所以拿到 [AquaticFauna.splashes] 后要在
/// 下一次 `advance` 之前消费完 —— 别把引用存起来跨帧用。
class FaunaSplash {
  FaunaSplash(this.x, this.z, this.strength, this.size);

  double x;
  double z;

  /// 涟漪强度（米）。与入水速度、鱼体大小相关。
  double strength;

  /// 肇事鱼的体长（米）—— 音效层据此决定"扑通"声的响度。
  double size;
}

/// 河里的移动生物（鱼 + 虾）。见文件头说明。
class AquaticFauna {
  AquaticFauna({
    required this.terrain,
    required this.flow,
    this.fishCount = 64,
    this.shrimpCount = 72,
    this.zHalfRange = 30.0,
    int seed = 707,
  })  : _rng = math.Random(seed) {
    // 顺序有讲究：群心必须先建好 —— `_initFish` 给自己挑第一个目标点时
    // 会读群心（`_retargetFish` 的落点 = 个体游荡点与群心的混合）。
    _initSchools();
    _initFish();
    _initShrimp();
  }

  final Terrain terrain;

  /// 全项目唯一的水动力数据源（与水面、水草共享同一个实例）。
  final RiverFlow flow;

  /// 鱼与虾的数量。鱼每个占 2 个实例（身体 + 尾鳍）。
  ///
  /// 这个数不是"性能能扛多少"，而是**看得见的下限**：河道宽约 7m，
  /// 活动河段取 ±[zHalfRange]，于是鱼的面密度 ≈
  /// `64 / (60 × 7) ≈ 0.15 条/m²`（平均每 6.5m² 一条）。第一版用 36 条铺在
  /// ±46m 上（0.06 条/m²），实机截图里整条河**一条鱼都看不见** ——
  /// 生态做得再对，看不见就等于没做。
  final int fishCount;
  final int shrimpCount;

  /// 生物活动的河道 z 范围（±）。河全长 ±78m，而玩法区在原点附近 ——
  /// 取 ±30m 既覆盖玩家真的会走到的河段，又不把有限的数量摊薄。
  final double zHalfRange;

  final math.Random _rng;

  // ---- 调参常量（都是"读感"参数，集中放这里便于对照）----

  /// 鱼的惊逃半径（米）。4.5m ≈ 玩家跑到岸边时河里的鱼会成片炸开。
  static const double fishStartleRadius = 4.5;

  /// 虾的惊逃半径（米）。比鱼近得多：虾是贴底的小东西，只有踩到跟前才弹。
  static const double shrimpStartleRadius = 2.4;

  /// 受惊后鱼直接跃出水面的概率（要够深才行）。
  static const double breachChance = 0.28;

  /// 自发跃出的间隔（秒）。每条鱼自己隔一阵跳一次 —— 见 [_advanceFish]
  /// 里"自发跃出"那段的说明。
  static const double _selfBreachMin = 9.0;
  static const double _selfBreachMax = 26.0;

  /// 尾摆振幅上限（弧度）。
  static const double maxTailAmplitude = 0.62;

  /// 鱼群数量。群心数量决定了"同时有几个方向在游"。
  static const int schoolCount = 4;

  /// 入水涟漪的强度基准（米）。水面涟漪的振幅上限是 0.5m，
  /// 这里取到 0.30 就够显眼 —— 再大就成了石头落水。
  static const double splashStrengthBase = 0.14;
  static const double splashStrengthScale = 0.20;

  /// 一帧内最多向外报告几次入水（超出就丢弃：16 条鱼同时跃出是极罕见情形，
  /// 丢掉的那几个涟漪本来也会被水面合并）。
  static const int splashCapacity = 8;

  // ---- 鱼状态 ----
  late final Float64List _fishX;
  late final Float64List _fishZ;
  late final Float64List _fishY;
  late final Float64List _fishHeading;
  late final Float64List _fishVx;
  late final Float64List _fishVz;
  late final Float64List _fishVy;
  late final Float64List _fishSize;
  late final Float64List _fishCruiseSpeed;
  late final Float64List _fishDepthFrac;

  /// 个体偏好的巡游水层（0 = 贴河床，1 = 贴水面）。
  late final Float64List _fishDepthPref;
  late final Float64List _fishTargetX;
  late final Float64List _fishTargetZ;
  late final Float64List _fishMoodTimer;
  late final Float64List _fishBreachTimer;
  late final Float64List _fishPauseTimer;
  late final Float64List _fishTailOmega;
  late final Float64List _fishTailAmp;
  late final Float64List _fishPhase;
  late final Float64List _fishRoll;
  late final Float64List _fishPitch;
  late final Float64List _fishTintR;
  late final Float64List _fishTintG;
  late final Float64List _fishTintB;
  late final Int32List _fishSchool;
  late final List<FishMood> _fishMood;

  // ---- 虾状态 ----
  late final Float64List _shrimpX;
  late final Float64List _shrimpZ;
  late final Float64List _shrimpHeading;
  late final Float64List _shrimpVx;
  late final Float64List _shrimpVz;
  late final Float64List _shrimpSize;
  late final Float64List _shrimpPhase;
  late final Float64List _shrimpTimer;
  late final Float64List _shrimpTintR;
  late final Float64List _shrimpTintG;
  late final Float64List _shrimpTintB;
  late final List<ShrimpState> _shrimpState;

  // ---- 群心 ----
  late final Float64List _schoolX;
  late final Float64List _schoolZ;
  late final Float64List _schoolTargetX;
  late final Float64List _schoolTargetZ;
  late final Float64List _schoolTimer;

  // ---- 本帧的入水事件（复用槽位，见 [FaunaSplash] 的说明）----
  final List<FaunaSplash> _splashes =
      List<FaunaSplash>.generate(splashCapacity, (_) => FaunaSplash(0, 0, 0, 0));
  int _splashCount = 0;

  // ---- 渲染 ----
  InstancedMesh? _fishBodyMesh;
  InstancedMesh? _fishTailMesh;
  InstancedMesh? _shrimpMesh;

  // ---- scratch（零分配）----
  final vm.Matrix4 _body = vm.Matrix4.identity();
  final vm.Matrix4 _local = vm.Matrix4.identity();
  final vm.Matrix4 _out = vm.Matrix4.identity();

  /// 诊断计数（与 `flora.counts` / `aquatic_flora.counts` 同义，供 MCP 读）。
  Map<String, int> get counts => {
        'fish': fishCount,
        'shrimp': shrimpCount,
        'faunaInstances': fishCount * 2 + shrimpCount,
        'breaching': _fishMood.where((m) => m == FishMood.breaching).length,
        'startled': _fishMood.where((m) => m == FishMood.startled).length,
      };

  /// 本帧发生的入水事件：有效区间是 `[0, splashCount)`。
  List<FaunaSplash> get splashes => _splashes;

  /// 本帧入水事件的条数。
  int get splashCount => _splashCount;

  // ------------------------------------------------------------------
  // 初始化
  // ------------------------------------------------------------------

  void _initFish() {
    final n = fishCount;
    _fishX = Float64List(n);
    _fishZ = Float64List(n);
    _fishY = Float64List(n);
    _fishHeading = Float64List(n);
    _fishVx = Float64List(n);
    _fishVz = Float64List(n);
    _fishVy = Float64List(n);
    _fishSize = Float64List(n);
    _fishCruiseSpeed = Float64List(n);
    _fishDepthFrac = Float64List(n);
    _fishDepthPref = Float64List(n);
    _fishTargetX = Float64List(n);
    _fishTargetZ = Float64List(n);
    _fishMoodTimer = Float64List(n);
    _fishBreachTimer = Float64List(n);
    _fishPauseTimer = Float64List(n);
    _fishTailOmega = Float64List(n);
    _fishTailAmp = Float64List(n);
    _fishPhase = Float64List(n);
    _fishRoll = Float64List(n);
    _fishPitch = Float64List(n);
    _fishTintR = Float64List(n);
    _fishTintG = Float64List(n);
    _fishTintB = Float64List(n);
    _fishSchool = Int32List(n);
    _fishMood = List<FishMood>.filled(n, FishMood.cruising);

    // 四种体色：青白（溪流小鱼）、金黄（鲤鲫）、银白（白条）、青绿（底栖）。
    // 都比"真实鱼色"更亮一档 —— 鱼在水面之下，会被水色、深度衰减与半透明
    // 水面各压一层，实拍色调搬到屏幕上就是一团灰影（实测：暗青灰的鱼在
    // 8m 外的岸上几乎读不出轮廓）。
    const tints = <(double, double, double)>[
      (0.72, 0.80, 0.84),
      (0.96, 0.80, 0.42),
      (0.90, 0.92, 0.95),
      (0.52, 0.68, 0.56),
    ];

    for (var i = 0; i < n; i++) {
      // 体长 0.22–0.40 m：**由河道深度倒推出来的上限**。本关河道水深固定在
      // 0.8m（`River.waterDepth`），而一条鱼至少要 1.35 倍体长的水深才不会
      // 贴底蹭沙（`_fishSwimY` 的余量 + 目标点的深度筛选都按这个比例）。
      // 0.86m 的鱼在这里必然搁浅 —— 实测过，鱼会被迫挤在河心最深处。
      // 这个尺寸在 8.5m 相机距离下约 70px 长，足够看清尾摆。
      final size = 0.26 + _rng.nextDouble() * 0.18; // 0.26–0.44 m
      _fishSize[i] = size;
      _fishCruiseSpeed[i] = (0.42 + _rng.nextDouble() * 0.62) * (0.75 + size * 0.5);
      // 大鱼偏深、小鱼偏浅 —— 与真实溪流的"鱼层"一致。整体偏中上层：
      // 水面附近比贴底更容易被岸上的玩家看见（可读性优先于严格生态）。
      _fishDepthPref[i] =
          (0.92 - size * 1.1 + _rng.nextDouble() * 0.14).clamp(0.18, 0.88);
      _fishDepthFrac[i] = _fishDepthPref[i];
      _fishTailOmega[i] = 5.2 + _rng.nextDouble() * 2.6;
      // 第一条鱼很快就跳一次：玩家走到河边站定后不久就能看到动静。
      _fishBreachTimer[i] = 3.0 + _rng.nextDouble() * 9.0;
      _fishTailAmp[i] = 0.32 + _rng.nextDouble() * 0.26;
      _fishPhase[i] = _rng.nextDouble() * math.pi * 2;
      _fishSchool[i] = i % schoolCount;

      final tint = tints[i % tints.length];
      _fishTintR[i] = tint.$1;
      _fishTintG[i] = tint.$2;
      _fishTintB[i] = tint.$3;

      // 初始落点：沿中段河道均匀铺开，再抖动一下打散规律性。
      final z = -zHalfRange + (i + 0.5) / n * (zHalfRange * 2) +
          (_rng.nextDouble() - 0.5) * 3.0;
      _spawnAt(
        i,
        z,
        isFish: true,
        depthNeeded: size * 1.35 + 0.10,
        // 鱼也不许一出生就贴着岸 —— 那里浅，而且会撞上水草。
        lateralMin: -0.70,
        lateralMax: 0.70,
      );
      _retargetFish(i);
    }
  }

  void _initShrimp() {
    final n = shrimpCount;
    _shrimpX = Float64List(n);
    _shrimpZ = Float64List(n);
    _shrimpHeading = Float64List(n);
    _shrimpVx = Float64List(n);
    _shrimpVz = Float64List(n);
    _shrimpSize = Float64List(n);
    _shrimpPhase = Float64List(n);
    _shrimpTimer = Float64List(n);
    _shrimpTintR = Float64List(n);
    _shrimpTintG = Float64List(n);
    _shrimpTintB = Float64List(n);
    _shrimpState = List<ShrimpState>.filled(n, ShrimpState.crawling);

    for (var i = 0; i < n; i++) {
      final size = 0.14 + _rng.nextDouble() * 0.10; // 0.14–0.24 m
      _shrimpSize[i] = size;
      _shrimpPhase[i] = _rng.nextDouble() * math.pi * 2;
      _shrimpTimer[i] = _rng.nextDouble() * 0.8;

      // 偏暖的褐/青两色：与河床的土色同族，但亮一档 —— 贴底的小东西在
      // 水下会被压暗，照实际土色配就成了一块看不出来的泥。
      if (i.isEven) {
        _shrimpTintR[i] = 0.88;
        _shrimpTintG[i] = 0.62;
        _shrimpTintB[i] = 0.46;
      } else {
        _shrimpTintR[i] = 0.62;
        _shrimpTintG[i] = 0.72;
        _shrimpTintB[i] = 0.66;
      }

      final z = -zHalfRange + (i + 0.5) / n * (zHalfRange * 2) +
          (_rng.nextDouble() - 0.5) * 2.5;
      // 虾贴岸：横向落在近岸缓流带（也是水草最密的地方）。
      _spawnAt(
        i,
        z,
        isFish: false,
        depthNeeded: 0.16,
        lateralMin: 0.28,
        lateralMax: 0.88,
      );
      _shrimpHeading[i] = flow.directionAt(_shrimpX[i], _shrimpZ[i]).x >= 0
          ? math.pi * 0.5
          : -math.pi * 0.5;
    }
  }

  void _initSchools() {
    _schoolX = Float64List(schoolCount);
    _schoolZ = Float64List(schoolCount);
    _schoolTargetX = Float64List(schoolCount);
    _schoolTargetZ = Float64List(schoolCount);
    _schoolTimer = Float64List(schoolCount);

    for (var s = 0; s < schoolCount; s++) {
      // 群心沿河道错开，避免四群挤在同一段。
      final z = -zHalfRange + (s + 0.5) / schoolCount * (zHalfRange * 2);
      final (left, right) = flow.banksAt(z);
      _schoolX[s] = (left + right) * 0.5;
      _schoolZ[s] = z;
      _schoolTargetX[s] = _schoolX[s];
      _schoolTargetZ[s] = z;
      _schoolTimer[s] = 2.0 + _rng.nextDouble() * 6.0;
    }
  }

  /// 把第 [i] 条鱼（[isFish] 为真）或第 i 只虾放到 z 附近的合适水面上。
  ///
  /// `depthNeeded` 是"这里至少要有这么深"；横向先随机取，深度不够就往河心退，
  /// 退到河心还不够就放在河心（河心必然最深）。
  ///
  /// [isFish] 是必填而不是默认为真：这两种生物的落点规则不同，而"忘了传"
  /// 会让虾的坐标被写进鱼的数组（虾全留在原点）—— 这种错误只有渲染出来
  /// 才看得见。必填参数把它变成编译期错误。
  void _spawnAt(
    int i,
    double z, {
    required bool isFish,
    required double depthNeeded,
    double lateralMin = -0.72,
    double lateralMax = 0.72,
  }) {
    final zc = z.clamp(-zHalfRange, zHalfRange);
    final (left, right) = flow.banksAt(zc);
    final half = math.max((right - left) * 0.5, 0.25);
    final cx = (left + right) * 0.5;

    var lateral = lateralMin + _rng.nextDouble() * (lateralMax - lateralMin);
    var x = cx + lateral * half;
    if (flow.waterYAt(zc) - terrain.heightAt(x, zc) < depthNeeded) {
      // 逐步收向河心（河心最深），最多三次；仍不达标就用河心。
      for (var k = 0; k < 3; k++) {
        lateral *= 0.55;
        final probe = cx + lateral * half;
        if (flow.waterYAt(zc) - terrain.heightAt(probe, zc) >= depthNeeded) {
          x = probe;
          break;
        }
        x = cx;
      }
    }

    if (isFish) {
      _fishX[i] = x;
      _fishZ[i] = zc;
      _fishY[i] = _fishSwimY(i, x, zc, _fishDepthFrac[i]);
    } else {
      _shrimpX[i] = x;
      _shrimpZ[i] = zc;
    }
  }

  // ------------------------------------------------------------------
  // 纯逻辑推进（可单测）
  // ------------------------------------------------------------------

  /// 推进 [dt] 秒。[playerPos] 用于惊逃判定。
  ///
  /// **不触碰任何引擎对象**：状态变化全在 `Float64List` 里。
  void advance(double dt, vm.Vector3 playerPos) {
    _splashCount = 0;
    _advanceSchools(dt);
    for (var i = 0; i < fishCount; i++) {
      _advanceFish(i, dt, playerPos);
    }
    for (var i = 0; i < shrimpCount; i++) {
      _advanceShrimp(i, dt, playerPos);
    }
  }

  void _advanceSchools(double dt) {
    for (var s = 0; s < schoolCount; s++) {
      _schoolTimer[s] -= dt;
      if (_schoolTimer[s] <= 0) {
        _schoolTimer[s] = 6.0 + _rng.nextDouble() * 9.0;
        final z = (_schoolZ[s] + (_rng.nextDouble() - 0.5) * 34.0)
            .clamp(-zHalfRange + 4, zHalfRange - 4);
        final (left, right) = flow.banksAt(z);
        final half = (right - left) * 0.5;
        _schoolTargetX[s] = (left + right) * 0.5 +
            (_rng.nextDouble() - 0.5) * half * 1.1;
        _schoolTargetZ[s] = z;
      }
      // 群心慢慢朝目标漂（0.35 m/s 量级），所以鱼群是"游过去"而不是瞬移。
      final dx = _schoolTargetX[s] - _schoolX[s];
      final dz = _schoolTargetZ[s] - _schoolZ[s];
      final d = math.sqrt(dx * dx + dz * dz);
      if (d > 0.05) {
        final step = math.min(d, 0.38 * dt);
        _schoolX[s] += dx / d * step;
        _schoolZ[s] += dz / d * step;
      }
    }
  }

  void _advanceFish(int i, double dt, vm.Vector3 playerPos) {
    var mood = _fishMood[i];
    final x = _fishX[i];
    final z = _fishZ[i];

    // --- 惊起判定（跃出中的鱼不再被惊到）---
    if (mood != FishMood.breaching) {
      final dx = x - playerPos.x;
      final dz = z - playerPos.z;
      if (dx * dx + dz * dz < fishStartleRadius * fishStartleRadius) {
        if (mood != FishMood.startled) {
          _fishMood[i] = FishMood.startled;
          mood = FishMood.startled;
          _fishMoodTimer[i] = 0.9 + _rng.nextDouble() * 1.2;
          // 一部分鱼受惊会直接跃出水面（水太浅则只是逃）。
          // 跃出需要一点起跳水深：1.25 倍体长足够鱼把身体完全离水。
          // （原先用 1.6 倍，配 0.8m 深的河道等于"只有河心最深处才允许跳"，
          //   实测整段模拟里一条都跳不出来 —— 参数与场景尺度不匹配。）
          if (_rng.nextDouble() < breachChance &&
              flow.waterYAt(z) - terrain.heightAt(x, z) > _fishSize[i] * 1.25) {
            _startBreach(i);
            return;
          }
        } else {
          _fishMoodTimer[i] = math.max(_fishMoodTimer[i], 0.5);
        }
      }
    }

    if (mood == FishMood.breaching) {
      _integrateBreach(i, dt);
      return;
    }

    // --- 自发跃出 ---
    // 鱼不只被玩家惊到时才跳：觅食、换气、甩掉寄生虫都会让它们自己蹦出水面。
    // 这条路径是"站在岸边就能看到河里活着"的主要来源 —— 只靠"玩家靠近才惊跳"
    // 的话，玩家不动，整条河看上去就是静止的（实机验证过）。
    if (mood == FishMood.cruising) {
      _fishBreachTimer[i] -= dt;
      if (_fishBreachTimer[i] <= 0 &&
          flow.waterYAt(z) - terrain.heightAt(x, z) > _fishSize[i] * 1.25) {
        // `_startBreach` 负责重置计时（受惊跃出走的也是它）。
        _startBreach(i);
        return;
      }
    }

    // --- 目标点 ---
    final dxT = _fishTargetX[i] - x;
    final dzT = _fishTargetZ[i] - z;
    final distT = math.sqrt(dxT * dxT + dzT * dzT);

    if (mood == FishMood.startled) {
      _fishMoodTimer[i] -= dt;
      if (_fishMoodTimer[i] <= 0) {
        _fishMood[i] = FishMood.cruising;
        mood = FishMood.cruising;
        _retargetFish(i);
      }
    } else if (distT < 1.1) {
      // 到达目标：短暂停歇（尾摆变小），再换下一个目标 —— 鱼不是永动机。
      _fishPauseTimer[i] -= dt;
      if (_fishPauseTimer[i] <= 0) _retargetFish(i);
    } else {
      _fishPauseTimer[i] = 0.6 + _rng.nextDouble() * 2.2;
    }

    // --- 期望速度 ---
    var speed = _fishCruiseSpeed[i];
    var aimX = dxT;
    var aimZ = dzT;

    if (mood == FishMood.startled) {
      speed *= 1.85;
      aimX = x - playerPos.x;
      aimZ = z - playerPos.z;
      _fishDepthFrac[i] += (0.16 - _fishDepthFrac[i]) * math.min(1.0, dt * 2.2);
    } else if (_fishPauseTimer[i] <= 0.0 || distT < 1.1) {
      speed *= 0.45; // 停歇期：慢慢晃
    } else {
      _fishDepthFrac[i] +=
          (_fishDepthPref[i] - _fishDepthFrac[i]) * math.min(1.0, dt * 1.1);
    }

    final aimLen = math.sqrt(aimX * aimX + aimZ * aimZ);
    if (aimLen > 1e-4) {
      aimX /= aimLen;
      aimZ /= aimLen;
    } else {
      aimX = 0;
      aimZ = 0;
    }

    // --- 水动力耦合：自身游速 + 水流拖曳 ---
    // 0.35 是"这条鱼有多懒得对抗水流"：急流里明显被推歪，缓流里几乎自控。
    final dir = flow.directionAt(x, z);
    final flowSpeed = flow.speedAt(x, z) * 0.35;
    final vx = aimX * speed + dir.x * flowSpeed;
    final vz = aimZ * speed + dir.y * flowSpeed;

    _fishVx[i] = vx;
    _fishVz[i] = vz;

    var nx = x + vx * dt;
    var nz = z + vz * dt;

    // --- 边界：不出去河道，也不上浅滩 ---
    final (left, right) = flow.banksAt(nz);
    final cx = (left + right) * 0.5;
    final half = math.max((right - left) * 0.5, 0.25);
    final need = _fishSize[i] * 1.25 + 0.08;
    var nudged = false;

    if (nz < -zHalfRange || nz > zHalfRange) {
      nz = nz.clamp(-zHalfRange, zHalfRange);
      nudged = true;
    }
    if ((nx - cx).abs() > half * 0.86) {
      nx = cx + (nx - cx).sign * half * 0.86;
      nudged = true;
    }
    // 水位与河床高度各算一次，下面的游泳高度直接复用 —— `heightAt` 内含
    // fbm，同一条鱼在一帧里重复问同一个点几遍是纯浪费（这里有上百个个体）。
    final waterYHere = flow.waterYAt(nz);
    var bedHere = terrain.heightAt(nx, nz);
    if (waterYHere - bedHere < need) {
      // 水太浅：贴回河心方向（河心最深），并重选目标。
      nx = cx + (nx - cx).sign * half * 0.35;
      bedHere = terrain.heightAt(nx, nz);
      if (waterYHere - bedHere < need) {
        nx = cx;
        bedHere = terrain.heightAt(nx, nz);
      }
      nudged = true;
    }
    if (nudged) _retargetFish(i);

    _fishX[i] = nx;
    _fishZ[i] = nz;

    // --- 朝向：朝速度方向平滑转（限制角速度，才有"摆尾转身"而不是瞬转）---
    if (vx * vx + vz * vz > 1e-6) {
      _steerFish(i, math.atan2(vx, vz), dt, mood == FishMood.startled ? 6.5 : 3.4);
    }

    _fishY[i] = _swimYFrom(i, bedHere, waterYHere, _fishDepthFrac[i]);
    _fishPitch[i] += (0.0 - _fishPitch[i]) * math.min(1.0, dt * 4.0);
  }

  /// 把朝向朝 [targetHeading] 转，受角速度限制；顺带算出转弯侧倾（banking）。
  void _steerFish(int i, double targetHeading, double dt, double turnRate) {
    var d = targetHeading - _fishHeading[i];
    while (d > math.pi) {
      d -= math.pi * 2;
    }
    while (d < -math.pi) {
      d += math.pi * 2;
    }
    final maxStep = turnRate * dt;
    final step = d.clamp(-maxStep, maxStep);
    _fishHeading[i] = (_fishHeading[i] + step) % (math.pi * 2);

    // 侧倾：转得越急倾得越多（鱼转弯时会"侧身"）。
    final rollTarget =
        (-d * 1.6).clamp(-0.55, 0.55) * (maxStep > 1e-6 ? (step.abs() / maxStep).clamp(0.0, 1.0) : 0.0);
    _fishRoll[i] += (rollTarget - _fishRoll[i]) * math.min(1.0, dt * 5.0);
  }

  /// 鱼在水柱里的高度：河床之上留出体位余量，水面之下同样留出，
  /// 再按 [frac]（0 贴底 / 1 贴面）插值。
  double _fishSwimY(int i, double x, double z, double frac) =>
      _swimYFrom(i, terrain.heightAt(x, z), flow.waterYAt(z), frac);

  /// [ _fishSwimY ] 的复用版：水位与河床高度由调用方传入（避免重复查询）。
  double _swimYFrom(int i, double bed, double waterY, double frac) {
    final clear = _fishSize[i] * 0.45 + 0.03;
    final low = bed + clear;
    final high = math.max(waterY - clear, low);
    return low + (high - low) * frac.clamp(0.0, 1.0);
  }

  void _startBreach(int i) {
    final size = _fishSize[i];
    _fishMood[i] = FishMood.breaching;
    // 重置自发计时：刚跳过就不该马上又跳（连着蹦很假）。
    _fishBreachTimer[i] =
        _selfBreachMin + _rng.nextDouble() * (_selfBreachMax - _selfBreachMin);
    _fishVy[i] = 1.6 + size * 1.15 + _rng.nextDouble() * 0.5;
    // 水平速度放大一点：跃出是冲刺的延续，不是原地弹跳。
    _fishVx[i] *= 1.25;
    _fishVz[i] *= 1.25;
    if (_fishVx[i] * _fishVx[i] + _fishVz[i] * _fishVz[i] < 0.25) {
      // 原本几乎是静止的（停歇中）：朝下游方向跃出。
      final dir = flow.directionAt(_fishX[i], _fishZ[i]);
      _fishVx[i] = dir.x * 1.1;
      _fishVz[i] = dir.y * 1.1;
    }
    _fishPitch[i] = 0.7;
  }

  void _integrateBreach(int i, double dt) {
    final x = _fishX[i];
    final z = _fishZ[i];
    _fishVy[i] -= 7.8 * dt; // 略低于 g：读感更"轻"，与卡比草原的调子一致
    final nx = x + _fishVx[i] * dt;
    final nz = z + _fishVz[i] * dt;
    final ny = _fishY[i] + _fishVy[i] * dt;
    final waterY = flow.waterYAt(nz);

    if (ny <= waterY && _fishVy[i] < 0) {
      // 落水：交回水面一圈涟漪，并由世界层转给音效。
      final impact = _fishVy[i].abs();
      _fishY[i] = waterY - _fishSize[i] * 0.35;
      _fishX[i] = nx;
      _fishZ[i] = nz;
      _fishMood[i] = FishMood.cruising;
      _fishVy[i] = 0;
      _fishVx[i] *= 0.35;
      _fishVz[i] *= 0.35;
      _fishPitch[i] = -0.4;
      _fishDepthFrac[i] = 0.55;
      _fishPauseTimer[i] = 0.4 + _rng.nextDouble() * 0.8;
      _retargetFish(i);
      _reportSplash(nx, nz, impact);
      return;
    }

    _fishX[i] = nx;
    _fishZ[i] = nz;
    _fishY[i] = ny;
    _fishPitch[i] =
        math.atan2(_fishVy[i], math.max(_hypot(_fishVx[i], _fishVz[i]), 0.2))
            .clamp(-1.2, 1.2);
    if (_fishVx[i] * _fishVx[i] + _fishVz[i] * _fishVz[i] > 1e-6) {
      _steerFish(i, math.atan2(_fishVx[i], _fishVz[i]), dt, 4.0);
    }
  }

  void _reportSplash(double x, double z, double impact) {
    if (_splashCount >= splashCapacity) return;
    final slot = _splashes[_splashCount++];
    slot
      ..x = x
      ..z = z
      ..strength = (splashStrengthBase +
              splashStrengthScale * (impact / 2.6).clamp(0.0, 1.4))
          .clamp(0.05, 0.45)
      ..size = _fishSize[_nearestFishIndex(x, z)];
  }

  /// 找到离 (x,z) 最近的那条鱼（只用于给入水事件附上体长，O(n)，n=36）。
  int _nearestFishIndex(double x, double z) {
    var best = 0;
    var bestD = double.infinity;
    for (var i = 0; i < fishCount; i++) {
      final dx = _fishX[i] - x;
      final dz = _fishZ[i] - z;
      final d = dx * dx + dz * dz;
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }

  /// 给第 [i] 条鱼挑下一个目标点：个体游荡点与群心的加权混合。
  void _retargetFish(int i) {
    final school = _fishSchool[i];
    final baseZ = _fishZ[i];
    final wanderZ = (baseZ + (_rng.nextDouble() - 0.5) * 30.0)
        .clamp(-zHalfRange + 2, zHalfRange - 2);
    final z = wanderZ * 0.45 + _schoolZ[school] * 0.55;

    final (left, right) = flow.banksAt(z);
    final half = math.max((right - left) * 0.5, 0.25);
    final cx = (left + right) * 0.5;
    final schoolLateral = ((_schoolX[school] - cx) / half).clamp(-0.6, 0.6);
    final lateral = (schoolLateral * 0.5 + (_rng.nextDouble() - 0.5) * 1.0)
        .clamp(-0.66, 0.66);

    var tx = cx + lateral * half;
    // 目标点必须够深，否则鱼会一路游到浅滩上晒背。
    final need = _fishSize[i] * 1.3 + 0.1;
    if (flow.waterYAt(z) - terrain.heightAt(tx, z) < need) tx = cx;

    _fishTargetX[i] = tx;
    _fishTargetZ[i] = z.clamp(-zHalfRange, zHalfRange);
  }

  void _advanceShrimp(int i, double dt, vm.Vector3 playerPos) {
    final x = _shrimpX[i];
    final z = _shrimpZ[i];
    _shrimpTimer[i] -= dt;

    final dx = x - playerPos.x;
    final dz = z - playerPos.z;
    final nearPlayer =
        dx * dx + dz * dz < shrimpStartleRadius * shrimpStartleRadius;

    var state = _shrimpState[i];

    // 受惊：尾部弹射（向后急冲一小段）。
    if (nearPlayer && state != ShrimpState.darting) {
      state = ShrimpState.darting;
      _shrimpState[i] = state;
      _shrimpTimer[i] = 0.22;
      final away = math.atan2(dx, dz);
      _shrimpHeading[i] = away;
      _shrimpVx[i] = math.sin(away) * (0.9 + _rng.nextDouble() * 0.7);
      _shrimpVz[i] = math.cos(away) * (0.9 + _rng.nextDouble() * 0.7);
    }

    switch (state) {
      case ShrimpState.darting:
        if (_shrimpTimer[i] <= 0) {
          _shrimpState[i] = ShrimpState.resting;
          _shrimpTimer[i] = 0.35 + _rng.nextDouble() * 0.9;
          _shrimpVx[i] = 0;
          _shrimpVz[i] = 0;
        }
      case ShrimpState.resting:
        if (_shrimpTimer[i] <= 0) {
          _shrimpState[i] = ShrimpState.crawling;
          _shrimpTimer[i] = 1.6 + _rng.nextDouble() * 3.4;
          _shrimpHeading[i] += (_rng.nextDouble() - 0.5) * 2.4;
          final sp = 0.05 + _rng.nextDouble() * 0.11;
          _shrimpVx[i] = math.sin(_shrimpHeading[i]) * sp;
          _shrimpVz[i] = math.cos(_shrimpHeading[i]) * sp;
        }
      case ShrimpState.crawling:
        if (_shrimpTimer[i] <= 0) {
          _shrimpState[i] = ShrimpState.resting;
          _shrimpTimer[i] = 0.4 + _rng.nextDouble() * 1.1;
          _shrimpVx[i] = 0;
          _shrimpVz[i] = 0;
        }
    }

    // 爬行/停歇时受水流轻微带动（虾几乎不游，是被水推着走的）。
    final dir = flow.directionAt(x, z);
    final drift = flow.speedAt(x, z) * 0.10;
    var nx = x + (_shrimpVx[i] + dir.x * drift) * dt;
    var nz = z + (_shrimpVz[i] + dir.y * drift) * dt;

    // 约束：留在水里、留在近岸缓流带、贴着 z 范围。
    nz = nz.clamp(-zHalfRange, zHalfRange);
    final (left, right) = flow.banksAt(nz);
    final cx = (left + right) * 0.5;
    final half = math.max((right - left) * 0.5, 0.25);
    final lateral = (nx - cx) / half;
    final outOfBand = lateral.abs() > 0.9 || lateral.abs() < 0.12;
    final tooShallow = flow.waterYAt(nz) - terrain.heightAt(nx, nz) < 0.15;

    if (outOfBand || tooShallow) {
      // 朝河心偏一点（但仍在近岸带），并重选前进方向。
      final want = (lateral.sign == 0 ? 1.0 : lateral.sign) * 0.55;
      nx = cx + want * half;
      _shrimpHeading[i] = (_rng.nextDouble() - 0.5) * math.pi * 2;
      final sp = state == ShrimpState.darting ? 1.2 : 0.08;
      _shrimpVx[i] = math.sin(_shrimpHeading[i]) * sp;
      _shrimpVz[i] = math.cos(_shrimpHeading[i]) * sp;
    }

    _shrimpX[i] = nx;
    _shrimpZ[i] = nz;

    if (_shrimpVx[i] * _shrimpVx[i] + _shrimpVz[i] * _shrimpVz[i] > 1e-6) {
      final target = math.atan2(_shrimpVx[i], _shrimpVz[i]);
      var d = target - _shrimpHeading[i];
      while (d > math.pi) {
        d -= math.pi * 2;
      }
      while (d < -math.pi) {
        d += math.pi * 2;
      }
      _shrimpHeading[i] += d.clamp(-9.0 * dt, 9.0 * dt);
    }
  }

  // ------------------------------------------------------------------
  // 查询（测试与渲染共用）
  // ------------------------------------------------------------------

  double fishX(int i) => _fishX[i];
  double fishZ(int i) => _fishZ[i];
  double fishY(int i) => _fishY[i];
  double fishSize(int i) => _fishSize[i];
  FishMood fishMood(int i) => _fishMood[i];
  double shrimpX(int i) => _shrimpX[i];
  double shrimpZ(int i) => _shrimpZ[i];
  double shrimpSize(int i) => _shrimpSize[i];
  ShrimpState shrimpState(int i) => _shrimpState[i];

  /// 第 [i] 条鱼是否在水面以上（跃出中）。
  bool fishIsAirborne(int i) => _fishY[i] > flow.waterYAt(_fishZ[i]);

  // ------------------------------------------------------------------
  // 上网格
  // ------------------------------------------------------------------

  /// 把当前状态写成实例矩阵。世界层每 2 帧调一次。
  void applyTransforms(double time) {
    final bodyMesh = _fishBodyMesh;
    final tailMesh = _fishTailMesh;
    final shrimpMesh = _shrimpMesh;
    if (bodyMesh == null || tailMesh == null || shrimpMesh == null) return;

    for (var i = 0; i < fishCount; i++) {
      final size = _fishSize[i];
      _composeInto(
        _body,
        _fishX[i], _fishY[i], _fishZ[i],
        _fishHeading[i], -_fishPitch[i], _fishRoll[i],
        size, size, size,
      );

      // 尾摆：游得越急摆得越快越大；跃出水面时几乎僵直（鱼在空中的姿态）。
      final speed = _hypot(_fishVx[i], _fishVz[i]);
      final excitement =
          (speed / math.max(_fishCruiseSpeed[i], 0.2)).clamp(0.25, 2.0);
      final airborne = _fishMood[i] == FishMood.breaching;
      final amp = _fishTailAmp[i] * excitement * (airborne ? 0.25 : 1.0);
      final omega = _fishTailOmega[i] * (0.7 + 0.5 * excitement);
      final tailAngle = math.sin(time * omega + _fishPhase[i]) * amp;

      // 尾鳍挂在尾柄上：局部矩阵 = T(0,0,-attach) · Ry(尾摆角)，再整体乘鱼身
      // 矩阵 —— 于是尾鳍绕**尾柄**转，而不是绕自己的几何中心转。
      _composeInto(_local, 0, 0, -_fishTailAttach, tailAngle, 0, 0, 1, 1, 1);
      _out.setFrom(_body);
      _out.multiply(_local);

      tailMesh.setInstanceTransform(i, _out);
      bodyMesh.setInstanceTransform(i, _body);
    }

    for (var i = 0; i < shrimpCount; i++) {
      final size = _shrimpSize[i];
      // 贴着河床，随触须摆动轻微起伏 + 左右摆 —— 是"在动"，不是被粘住。
      final bob = math.sin(time * 2.1 + _shrimpPhase[i]) * 0.035;
      final sway = math.sin(time * 1.4 + _shrimpPhase[i] * 1.7) * 0.16;
      _composeInto(
        _out,
        _shrimpX[i],
        terrain.heightAt(_shrimpX[i], _shrimpZ[i]) + size * 0.26 + bob * 0.06,
        _shrimpZ[i],
        _shrimpHeading[i] + sway, bob, 0,
        size, size, size,
      );
      shrimpMesh.setInstanceTransform(i, _out);
    }
  }

  /// 鱼体长 1 的几何里，尾鳍铰接点所在的 z（负值 = 尾部）。
  static const double _fishTailAttach = 0.44;

  /// 组装 `T(px,py,pz) · R(yaw,pitch,roll) · S(sx,sy,sz)` 写进 [out]。
  ///
  /// 为什么不用 `vector_math` 的四元数/矩阵工厂来拼：
  ///   * `Quaternion` **没有** `multiply`，组合只能走 `*` —— 每次分配一个新对象；
  ///   * `Matrix4.rotationY(..)` 之类的静态工厂同样每次分配；
  ///   * 这里的旋转顺序是固定的 Y·X·Z（偏航 → 俯仰 → 侧倾），展开成 9 个乘法
  ///     既是最省的写法，也把"顺序到底是什么"直接写在纸上，不依赖读者在脑内
  ///     模拟四元数乘法（`grass.dart` 就在这里踩过坑）。
  ///
  /// 列主序写入：`out[0..2]` 是第一列（局部 +X 轴映射到世界的向量），依此类推。
  static void _composeInto(
    vm.Matrix4 out,
    double px,
    double py,
    double pz,
    double yaw,
    double pitch,
    double roll,
    double sclX,
    double sclY,
    double sclZ,
  ) {
    final cy = math.cos(yaw), sy = math.sin(yaw);
    final cx = math.cos(pitch), sx = math.sin(pitch);
    final cz = math.cos(roll), sz = math.sin(roll);

    // Ry·Rx（a10 恒为 0：Ry 的第一列第二个元素就是 0）
    const a10 = 0.0;
    final a00 = cy, a01 = sy * sx, a02 = sy * cx;
    final a11 = cx, a12 = -sx;
    final a20 = -sy, a21 = cy * sx, a22 = cy * cx;

    // (Ry·Rx)·Rz
    final r00 = a00 * cz + a01 * sz;
    final r01 = -a00 * sz + a01 * cz;
    final r02 = a02;
    final r10 = a10 * cz + a11 * sz;
    final r11 = -a10 * sz + a11 * cz;
    final r12 = a12;
    final r20 = a20 * cz + a21 * sz;
    final r21 = -a20 * sz + a21 * cz;
    final r22 = a22;

    out[0] = r00 * sclX;
    out[1] = r10 * sclX;
    out[2] = r20 * sclX;
    out[3] = 0.0;
    out[4] = r01 * sclY;
    out[5] = r11 * sclY;
    out[6] = r21 * sclY;
    out[7] = 0.0;
    out[8] = r02 * sclZ;
    out[9] = r12 * sclZ;
    out[10] = r22 * sclZ;
    out[11] = 0.0;
    out[12] = px;
    out[13] = py;
    out[14] = pz;
    out[15] = 1.0;
  }

  /// 把当前鱼虾变成三个 [InstancedMesh]（鱼身 / 鱼尾 / 虾），每类一次 draw call。
  List<Node> buildNodes() {
    _fishBodyMesh = InstancedMesh(
      geometry: _fishBodyGeometry(),
      material: _faunaMaterial(roughness: 0.35),
    );
    _fishTailMesh = InstancedMesh(
      geometry: _fishTailGeometry(),
      material: _faunaMaterial(roughness: 0.55),
    );
    _shrimpMesh = InstancedMesh(
      geometry: _shrimpGeometry(),
      material: _faunaMaterial(roughness: 0.62),
    );

    // 先登记实例（矩阵随后由 applyTransforms 统一覆盖）。
    final identity = vm.Matrix4.identity();
    for (var i = 0; i < fishCount; i++) {
      final tint = vm.Vector4(_fishTintR[i], _fishTintG[i], _fishTintB[i], 1.0);
      _fishBodyMesh!.addInstance(identity, color: tint);
      _fishTailMesh!.addInstance(identity, color: vm.Vector4(tint.r * 0.9, tint.g * 0.9, tint.b * 0.9, 1.0));
    }
    for (var i = 0; i < shrimpCount; i++) {
      _shrimpMesh!.addInstance(
        identity,
        color: vm.Vector4(_shrimpTintR[i], _shrimpTintG[i], _shrimpTintB[i], 1.0),
      );
    }

    applyTransforms(0);
    return [
      Node(name: 'faunaFish')..addComponent(InstancedMeshComponent(_fishBodyMesh!)),
      Node(name: 'faunaFishTail')
        ..addComponent(InstancedMeshComponent(_fishTailMesh!)),
      Node(name: 'faunaShrimp')..addComponent(InstancedMeshComponent(_shrimpMesh!)),
    ];
  }

  PhysicallyBasedMaterial _faunaMaterial({required double roughness}) =>
      PhysicallyBasedMaterial()
        ..baseColorFactor = vm.Vector4(1, 1, 1, 1) // 颜色 = 顶点色 × 实例色
        ..roughnessFactor = roughness
        ..metallicFactor = 0.0
        ..doubleSided = true;

  // ------------------------------------------------------------------
  // 几何（单位长度 1，实例矩阵再缩放到体长；头朝局部 +Z）
  // ------------------------------------------------------------------

  /// 鱼身：沿体轴 +Z 的梭形，背部深、腹部浅（顶点色），头钝尾细。
  MeshGeometry _fishBodyGeometry() {
    const rings = 11;
    const seg = 10;
    final b = GeometryBuilder();
    final rows = <List<int>>[];

    for (var i = 0; i < rings; i++) {
      final t = i / (rings - 1); // 0 = 尾柄, 1 = 吻端
      final z = -0.5 + t;
      // 体宽剖面：头端钝、中后段最宽、尾柄收细。
      final w = math.pow(math.sin(math.pi * math.pow(t, 0.58)), 0.85).toDouble();
      final rx = 0.055 * w + 0.014;
      final ry = 0.075 * w + 0.018;
      final row = <int>[];
      for (var s = 0; s <= seg; s++) {
        final a = s / seg * math.pi * 2;
        final oy = math.cos(a);
        final ox = math.sin(a);
        // 背深腹浅（oy > 0 为背部）。
        final k = (oy * 0.5 + 0.5).clamp(0.0, 1.0);
        b.color(vm.Vector4(
          _lerp(0.94, 0.30, k),
          _lerp(0.95, 0.40, k),
          _lerp(0.88, 0.36, k),
          1.0,
        ));
        row.add(b.addVertex(vm.Vector3(ox * rx, oy * ry, z)));
      }
      rows.add(row);
    }

    for (var i = 0; i < rings - 1; i++) {
      for (var s = 0; s < seg; s++) {
        final a = rows[i][s];
        final bb = rows[i][s + 1];
        final c = rows[i + 1][s + 1];
        final d = rows[i + 1][s];
        b
          ..addTriangle(a, bb, c)
          ..addTriangle(a, c, d);
      }
    }
    return b.build();
  }

  /// 尾鳍：竖直平面上的叉形鳍片，铰接点在原点（实例矩阵把它挂到鱼尾柄上）。
  MeshGeometry _fishTailGeometry() {
    final b = GeometryBuilder();
    // 注意：`vector_math` 的向量/四元数**不是** const 构造。
    final light = vm.Vector4(0.86, 0.90, 0.86, 1.0);
    final mid = vm.Vector4(0.62, 0.70, 0.68, 1.0);

    b.color(light);
    final root = b.addVertex(vm.Vector3(0, 0, 0.0));
    final upperMid = b.addVertex(vm.Vector3(0, 0.055, -0.075));
    final upperTip = b.addVertex(vm.Vector3(0, 0.185, -0.245));
    b.color(mid);
    final lowerMid = b.addVertex(vm.Vector3(0, -0.055, -0.075));
    final lowerTip = b.addVertex(vm.Vector3(0, -0.185, -0.245));

    // 单面片就够了：材质是 doubleSided，背面会自动渲染。
    // 不要再补一片**反向重复**的三角形 —— 面积加权的法线会把两片抵消成
    // 零向量（`GeometryBuilder` 的自动法线是按面积加权求和），尾鳍会变黑。
    b
      ..addTriangle(root, upperMid, upperTip)
      ..addTriangle(root, lowerTip, lowerMid);
    return b.build();
  }

  /// 虾：弓形身体 + 一对触须，单实例（不做分节动画，靠整体摆动读出"活")。
  MeshGeometry _shrimpGeometry() {
    const rings = 7;
    const seg = 6;
    final b = GeometryBuilder();
    final rows = <List<int>>[];

    for (var i = 0; i < rings; i++) {
      final t = i / (rings - 1); // 0 = 尾, 1 = 头
      final z = -0.5 + t;
      // 身体沿弧线上弓：中段抬高，头尾下垂 —— 虾的标志性姿态。
      final bend = math.sin(math.pi * t) * 0.10;
      final w = math.pow(math.sin(math.pi * math.pow(t, 0.7)), 0.7).toDouble();
      final rx = 0.045 * w + 0.010;
      final ry = 0.055 * w + 0.012;
      final row = <int>[];
      for (var s = 0; s <= seg; s++) {
        final a = s / seg * math.pi * 2;
        final oy = math.cos(a);
        final ox = math.sin(a);
        // 背部带一点暖色甲壳反光，腹部偏暗。
        final k = (oy * 0.5 + 0.5).clamp(0.0, 1.0);
        b.color(vm.Vector4(
          _lerp(0.72, 0.92, k),
          _lerp(0.66, 0.86, k),
          _lerp(0.58, 0.78, k),
          1.0,
        ));
        row.add(b.addVertex(vm.Vector3(ox * rx, oy * ry + bend, z)));
      }
      rows.add(row);
    }

    for (var i = 0; i < rings - 1; i++) {
      for (var s = 0; s < seg; s++) {
        b
          ..addTriangle(rows[i][s], rows[i][s + 1], rows[i + 1][s + 1])
          ..addTriangle(rows[i][s], rows[i + 1][s + 1], rows[i + 1][s]);
      }
    }

    // 触须：从头部向前伸出的两条细带（单面片，双面材质负责背面）。
    b.color(vm.Vector4(0.86, 0.82, 0.74, 1.0));
    for (final sy in const [-1.0, 1.0]) {
      final a0 = b.addVertex(vm.Vector3(0.012 * sy, 0.045, 0.48));
      final a1 = b.addVertex(vm.Vector3(0.030 * sy, 0.035, 0.62));
      final a2 = b.addVertex(vm.Vector3(0.052 * sy, 0.010, 0.74));
      b.addTriangle(a0, a1, a2);
    }
    return b.build();
  }
}

double _lerp(double a, double b, double t) => a + (b - a) * t;

double _hypot(double a, double b) => math.sqrt(a * a + b * b);
