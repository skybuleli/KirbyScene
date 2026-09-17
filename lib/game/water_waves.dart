/// 水面的**纯数学模型**：不依赖 flutter_scene，只吃 [RiverFlow] 的水动力数据，
/// 吐出 positions / colors / normals 三个 [Float32List]。
///
/// ## 为什么要把数学从引擎里拆出来
///
/// flutter_scene 的 `Scene` / `MeshGeometry` 构造函数会**同步**去取 Flutter GPU
/// 上下文，在没有渲染环境的地方（CI、单元测试）直接抛异常。一旦水面动效和
/// `MeshGeometry` 绑在一起，整块水就成了不可测的 —— 而"水到底有没有在动、
/// 波峰有没有越过岸线、法线是不是单位向量"恰恰是最该被钉死的东西。
///
/// 所以这里做一次彻底分离：本文件只做纯浮点运算，一个 GPU 对象都不碰；
/// 三份顶点缓冲在构造时一次性预分配，[update] 里只做原地写入，**不产生任何
/// 堆分配**。GPU 上传留给适配层 `water.dart`。
///
/// ## 动效为什么要分这么多层
///
/// 单靠"一个正弦波沿 z 摆"，无论振幅调多大都像一张在动的贴图 —— 因为水面
/// 是**高度场**，在 flutter_scene 不支持自定义着色器的前提下，让运动真正被
/// 光照看见的唯一手段是**顶点法线**。所以每一层最终都要落到法线上：
///
///   1. **沿流向的行波**：相位取 [RiverFlow.flowPhase]，空间波距 λ = 2πv/ω
///      自动正比于当地流速 —— 急滩波被拉长、深潭纹被挤密。叠了两个频率
///      （主波 ω1、细纹 ω2）再加一个横向干涉分量，避免读成规则条纹。
///   2. **湍流白水**（[RiverFlow.turbulenceAt]）：浅 + 快处叠一层高频碎波。
///      注意这跟行波**不是一回事** —— 行波管"波长"，白水管"碎不碎"。
///      浅滩的正确读法是"长波 + 白浪"，把两者混成一个频率就全糊了。
///   3. **岸边衰减**：近岸振幅衰减到 0（[_amplitude] 里的横向 + 水深双衰减），
///      于是最外列顶点严格停在 [RiverFlow.waterYAt] 上，
///      **水面永远不会戳出岸线**（这是硬约束，单测会查）。
///   4. **点源涟漪**：外部（鱼跃、雨滴）调 [addRipple]，是一圈以水波速度向外
///      扩的环形行波、外加源头一个快速衰减的"水花"凸起；同点重复触发会合并，
///      总数有上限。
///
/// ## 每帧怎么算（性能取舍）
///
/// 时间在 [update] 里推进，一次 update 做三件事：
///   * 用**位移后的网格**做有限差分算单位法线（"看得出在动"的关键）；
///   * 重写 colors：顺流滚动的泡沫条纹 + 湍流白水噪点；
///   * 顺手淘汰过期涟漪。
///
/// 所有"与时间无关"的量（到河心的横向位置、水深、湍流强度、流速因子、随机
/// 相位、静态基色）都在构造时预计算进 Float32List，[update] 里只剩三角函数与
/// 四则运算。再加一条：`flowPhase` 只依赖 z，所以按行算一次就够，不必每顶点
/// 重算。2400 个顶点 × 每 3 帧一次，对 CPU 毫无压力（对比：草叶有 11 万个实例）。
library;
import 'dart:math' as math;
import 'dart:typed_data';

import 'flow.dart';
import 'noise.dart';

/// 水面波场模型。见文件头说明。
class WaterWaves {
  WaterWaves({
    required this.flow,
    this.rows = 240,
    this.cols = 10,
    int seed = 4242,
  }) : _noise = ValueNoise(seed: seed ^ 0x5eed) {
    _meanSpeed = math.max(flow.meanSpeed, 0.05);

    final n = rows * cols;
    rowZ = Float32List(rows);
    rowWaterY = Float32List(rows);
    rowLeft = Float32List(rows);
    rowRight = Float32List(rows);

    vertexX = Float32List(n);
    vertexLateral = Float32List(n);
    vertexUSign = Float32List(n);
    vertexDepth = Float32List(n);
    vertexTurb = Float32List(n);
    vertexSpeedFactor = Float32List(n);
    vertexRand = Float32List(n);
    vertexStreakGain = Float32List(n);
    baseR = Float32List(n);
    baseG = Float32List(n);
    baseB = Float32List(n);
    baseA = Float32List(n);

    positions = Float32List(n * 3);
    colors = Float32List(n * 4);
    normals = Float32List(n * 3);
    indices = Uint32List((rows - 1) * (cols - 1) * 6);

    _rippleX = Float64List(rippleCapacity);
    _rippleZ = Float64List(rippleCapacity);
    _rippleStart = Float64List(rippleCapacity);
    _rippleStrength = Float64List(rippleCapacity);

    _buildGrid();
    _buildIndices();
    _computeBaseColors();
    update(0.0);
  }

  /// 水动力数据源。**所有**流速/流向/湍流/水位/岸线都从这里取，
  /// 本文件不另立一套公式 —— 否则水面的流向会和鱼虾水草打架。
  final RiverFlow flow;

  /// 沿流向（z）的分段数，与横向（x）的顶点列数。
  ///
  /// 240 × 10 = 2400 个顶点，落在 1.5k–2.5k 的预算里。行列比 24:1 是因为
  /// "沿流向的行波"需要沿 z 的分辨率（波距 λ ≈ 2πv/ω，约 2–5m），
  /// 而横向只有一个横向干涉分量，不需要那么多列。
  final int rows;
  final int cols;

  final ValueNoise _noise;

  /// 全河平均流速，用来把 [RiverFlow.sectionSpeedAt] 归一化成"快/慢"因子。
  /// 只算一次：`flow.meanSpeed` 每次都会遍历整张断面表。
  late final double _meanSpeed;

  /// 每行的 z、基准水位与左右岸 x（直接来自 flow，不自己扫地形）。
  late final Float32List rowZ;
  late final Float32List rowWaterY;
  late final Float32List rowLeft;
  late final Float32List rowRight;

  /// 每顶点的静态量（构造时算一次，之后时间无关）。
  late final Float32List vertexX;

  /// 到河心的归一化横向位置：0 = 河心，1 = 岸边。
  late final Float32List vertexLateral;

  /// 带符号的横向位置（−1…+1），横向干涉分量用它。
  late final Float32List vertexUSign;

  /// 水深（米）。
  late final Float32List vertexDepth;

  /// 湍流强度 0–1（白水/急滩的主要读感来源）。
  late final Float32List vertexTurb;

  /// 当地流速因子（断面流速 / 全河平均，clamp 到 0.55–1.8）。
  late final Float32List vertexSpeedFactor;

  /// 每顶点随机相位，避免涟漪排成整齐的行列。
  late final Float32List vertexRand;

  /// 顺流泡沫条纹的增益（浅水更明显）。
  late final Float32List vertexStreakGain;

  /// 静态基色分量（深浅配色 + 岸边泡沫亮边），每帧只在其上叠明暗。
  late final Float32List baseR;
  late final Float32List baseG;
  late final Float32List baseB;

  /// 静态不透明度分量。水面是**半透明**的：河床、水草、鱼虾都在水面以下，
  /// 水不透明的话整层水下生态等于白做（连颜色都不会出现在画面上）。
  /// 浅处更透（看得见河床）、深槽更实（水色压住底）。
  late final Float32List baseA;

  /// 输出缓冲：每帧原地重写，适配层直接上传。
  late final Float32List positions;
  late final Float32List colors;
  late final Float32List normals;

  /// 三角面索引（每 3 个一组）。适配层与单测共用同一份拓扑，
  /// 不会出现"测试数与渲染数各说各话"。
  late final Uint32List indices;

  late final Float64List _rippleX;
  late final Float64List _rippleZ;
  late final Float64List _rippleStart;
  late final Float64List _rippleStrength;
  int _rippleCount = 0;

  /// 最近一次 [update] 的时间；也是 [addRipple] 给新涟漪打的出生时间戳。
  double _now = 0.0;

  // ------------------------------------------------------------------
  // 调参常量
  // ------------------------------------------------------------------

  /// 主行波 / 细纹的角频率。波距 λ = 2πv/ω：ω1=1.2 时，v=0.5m/s 处 λ≈2.6m，
  /// 用 240 行（z 间距 ≈0.65m）大约是 4 个采样/波长，不至于混叠成一团。
  static const double omega1 = 1.2;
  static const double omega2 = 2.0;

  /// 横向干涉分量的角频率（它沿宽度方向，被列方向很好地解析）。
  static const double crossOmega = 1.7;

  /// 泡沫条纹的角频率。比几何行波高：条纹是"看出往哪边流"最便宜的手段，
  /// 滚得稍快一点读感更明确，而它只是亮度带，不受顶点分辨率限制。
  static const double streakOmega = 2.8;

  /// 振幅上限（米）。岸线在 mean water level 上几乎没有超高（[RiverFlow.banksAt]
  /// 就是按"地形 = 水位"找出来的），所以振幅必须收得住，否则近岸会戳出水面。
  static const double maxAmplitude = 0.26;

  /// 涟漪容量上限。鱼跃/雨滴可能在同一帧里密集触发，合并之后仍留这么多格。
  static const int rippleCapacity = 24;
  static const double rippleSpeed = 1.5; // 外扩速度 m/s（浅水重力波量级）
  static const double rippleK = 7.0; // 空间角频率（λ≈0.9m）
  static const double rippleOmega = 8.0; // 时间角频率
  static const double rippleSigma = 0.5; // 波前包络宽度
  static const double rippleLifetime = 2.4; // 寿命（秒）
  static const double rippleMergeRadius = 0.35; // 合并半径
  static const double rippleMaxStrength = 0.5; // 单个涟漪的振幅上限（米）
  static const double rippleRadialAtten = 0.35; // 径向衰减 1/m

  // ------------------------------------------------------------------
  // 只读视图（单测用）
  // ------------------------------------------------------------------

  int get vertexCount => rows * cols;

  int get triangleCount => (rows - 1) * (cols - 1) * 2;

  /// 当前活跃涟漪数。
  int get rippleCount => _rippleCount;

  /// 最近一次 [update] 的时间。
  double get time => _now;

  /// 第 [row] 行顶点的 z。
  double vertexZ(int row) => rowZ[row];

  /// 第 [row] 行、第 [col] 列顶点的 x。
  double vertexXAt(int row, int col) => vertexX[row * cols + col];

  // ------------------------------------------------------------------
  // 组装
  // ------------------------------------------------------------------

  void _buildGrid() {
    final zStart = flow.river.zStart;
    final zEnd = flow.river.zEnd;

    for (var i = 0; i < rows; i++) {
      final t = rows == 1 ? 0.0 : i / (rows - 1);
      final z = zStart + (zEnd - zStart) * t;
      rowZ[i] = z;
      // 水位与岸线一律取流场：那里是"与 Terrain.waterSurfaceAt 逐位一致"的
      // 同一套解析式，自己扫地形必然对不上（水草/鱼是贴着水位放的）。
      rowWaterY[i] = flow.waterYAt(z);
      final (left, right) = flow.banksAt(z);
      rowLeft[i] = left;
      rowRight[i] = right;

      final width = right - left;
      final halfW = math.max(width * 0.5, 0.25);
      final cx = (left + right) * 0.5;
      final speedF = _speedFactor(z);

      for (var j = 0; j < cols; j++) {
        final u = cols == 1 ? 0.0 : j / (cols - 1);
        final x = left + width * u;
        final vi = i * cols + j;

        vertexX[vi] = x;
        vertexLateral[vi] = (x - cx).abs() / halfW;
        vertexUSign[vi] = ((x - cx) / halfW).clamp(-1.2, 1.2);

        final depth = math.max(flow.depthAt(x, z), 0.0);
        vertexDepth[vi] = depth;
        vertexTurb[vi] = flow.turbulenceAt(x, z);
        vertexSpeedFactor[vi] = speedF;
        vertexRand[vi] = _phaseNoise(x, z);
        vertexStreakGain[vi] =
            0.085 * (0.35 + 0.65 * (1.0 - (depth / 1.6).clamp(0.0, 1.0)));
      }
    }
  }

  void _buildIndices() {
    var p = 0;
    for (var i = 0; i < rows - 1; i++) {
      for (var j = 0; j < cols - 1; j++) {
        final a = i * cols + j;
        final b = a + 1;
        final c = a + cols;
        final d = c + 1;
        // 绕序：从 +Y 俯视为 CW，配合下面的法线朝向取 +Y（水面是高度场）。
        indices[p++] = a;
        indices[p++] = b;
        indices[p++] = c;
        indices[p++] = b;
        indices[p++] = d;
        indices[p++] = c;
      }
    }
  }

  /// 静态基色：浅滩偏青、深处偏蓝、岸边压一条泡沫亮边。
  ///
  /// 这一步与时间无关，所以只在构造时算一次，[update] 里只在其上叠明暗 ——
  /// 否则每帧都要为 2400 个顶点重算三条颜色插值。
  void _computeBaseColors() {
    for (var vi = 0; vi < vertexCount; vi++) {
      final depth = vertexDepth[vi];
      final lateral = vertexLateral[vi];

      final deepT = (depth / 1.8).clamp(0.0, 1.0);
      final t1 = (deepT * 2.0).clamp(0.0, 1.0);
      var r = 0.26 + (0.08 - 0.26) * t1;
      var g = 0.46 + (0.26 - 0.46) * t1;
      var b = 0.44 + (0.40 - 0.44) * t1;

      final t2 = ((deepT - 0.5) * 2.0).clamp(0.0, 1.0);
      r += (0.03 - r) * t2;
      g += (0.11 - g) * t2;
      b += (0.26 - b) * t2;

      // 岸边（横向接近 1 或水很浅）提亮成泡沫/湿沙，消除水面与陆地的硬边。
      final shoreT =
          math.max(1.0 - (1.0 - lateral) / 0.18, 1.0 - depth / 0.22)
              .clamp(0.0, 1.0);
      final st = shoreT * 0.75;
      r += (0.58 - r) * st;
      g += (0.66 - g) * st;
      b += (0.68 - b) * st;

      baseR[vi] = r;
      baseG[vi] = g;
      baseB[vi] = b;

      // 不透明度：浅处透（看得见河床、水草、鱼），深槽实（水色压住底）。
      // 这条曲线是"水下生态能不能被看见"的总开关 —— 水面若全不透明，
      // 水下那一整层（水草/鱼/虾）在画面上等于不存在。
      //
      // 下限 0.40 而不是更低：水面还有自己的一层泡沫条纹与法线高光，
      // 太透会让那层动效"立不住"，读成一层薄膜而不是水。
      baseA[vi] = (0.40 + 0.44 * (depth / 1.5).clamp(0.0, 1.0)).clamp(0.0, 1.0);
    }
  }

  // ------------------------------------------------------------------
  // 每帧更新
  // ------------------------------------------------------------------

  /// 推进到 [time]，原地重写 positions / colors / normals。
  ///
  /// 约定：世界层每 3 帧调一次（约 13Hz）。这里不做任何时间平滑 ——
  /// 波是严格由 time 决定的解析函数，跳帧只会让相位跳一点，不会积累误差。
  void update(double time) {
    _now = time;
    _pruneRipples();
    _fillPositions(time);
    _fillColors(time);
    _fillNormals();
  }

  void _fillPositions(double time) {
    for (var i = 0; i < rows; i++) {
      final z = rowZ[i];
      final wy = rowWaterY[i];
      // flowPhase 只依赖 z，按行算一次即可（省掉每顶点一次表查找）。
      final p1 = flow.flowPhase(z, time, omega1);
      final p2 = flow.flowPhase(z, time, omega2);

      for (var j = 0; j < cols; j++) {
        final vi = i * cols + j;
        final amp = _amplitude(vertexDepth[vi], vertexLateral[vi],
            vertexTurb[vi], vertexSpeedFactor[vi]);
        final wave = _combine(amp, vertexUSign[vi], vertexTurb[vi],
            vertexRand[vi], p1, p2, time);
        final ripple =
            _rippleOffset(vertexX[vi], z, time) * _shoreDamp(vertexLateral[vi]);

        final o = vi * 3;
        positions[o] = vertexX[vi];
        positions[o + 1] = wy + wave + ripple;
        positions[o + 2] = z;
      }
    }
  }

  /// 由位移后的网格做有限差分求单位法线。
  ///
  /// 这是整块水面"活起来"的关键：flutter_scene 不支持自定义着色器，
  /// 顶点的上下起伏本身在光照里几乎看不出来（水面法线一直朝上就永远是同一个
  /// 高光），只有让**法线跟着波一起摆**，波纹才会随光照闪动。振幅调到再大，
  /// 不做这一步也只是一张贴图在动。
  ///
  /// 网格是结构化的（行 × 列），相邻关系已知，直接取上下左右四个邻居做
  /// 中心差分；边界退化成单侧差分。水面是高度场，法线必然朝 +Y，
  /// 退化（长度为零）或算反时直接退回 (0,1,0)。
  void _fillNormals() {
    for (var i = 0; i < rows; i++) {
      final i0 = i > 0 ? i - 1 : i;
      final i1 = i < rows - 1 ? i + 1 : i;
      for (var j = 0; j < cols; j++) {
        final j0 = j > 0 ? j - 1 : j;
        final j1 = j < cols - 1 ? j + 1 : j;

        final a = (i * cols + j0) * 3;
        final b = (i * cols + j1) * 3;
        final c = (i0 * cols + j) * 3;
        final d = (i1 * cols + j) * 3;

        // tU：沿列（+x 方向）；tV：沿行（z 方向）。
        final ax = positions[b] - positions[a];
        final ay = positions[b + 1] - positions[a + 1];
        final az = positions[b + 2] - positions[a + 2];
        final bx = positions[d] - positions[c];
        final by = positions[d + 1] - positions[c + 1];
        final bz = positions[d + 2] - positions[c + 2];

        final nx = ay * bz - az * by;
        final ny = az * bx - ax * bz;
        final nz = ax * by - ay * bx;
        final len = math.sqrt(nx * nx + ny * ny + nz * nz);

        final o = (i * cols + j) * 3;
        if (len < 1e-9 || ny < 0.0) {
          normals[o] = 0.0;
          normals[o + 1] = 1.0;
          normals[o + 2] = 0.0;
        } else {
          final inv = 1.0 / len;
          normals[o] = nx * inv;
          normals[o + 1] = ny * inv;
          normals[o + 2] = nz * inv;
        }
      }
    }
  }

  void _fillColors(double time) {
    for (var i = 0; i < rows; i++) {
      final z = rowZ[i];
      final pStreak = flow.flowPhase(z, time, streakOmega);

      for (var j = 0; j < cols; j++) {
        final vi = i * cols + j;

        // 顺流滚动的泡沫条纹：相位同样由 flowPhase 驱动，于是明暗带自然
        // 顺着水流往下游漂 —— 这是"看得出往哪边流"最便宜的手段。
        final streakPhase =
            pStreak + vertexUSign[vi] * 1.6 + vertexRand[vi] * 0.5;
        final streak = 0.5 + 0.5 * math.sin(streakPhase);

        final lift = streak * vertexStreakGain[vi] +
            _foamCore(vertexX[vi], z, time, vertexTurb[vi]);

        final o = vi * 4;
        colors[o] = (baseR[vi] + lift).clamp(0.0, 1.0);
        colors[o + 1] = (baseG[vi] + lift).clamp(0.0, 1.0);
        colors[o + 2] = (baseB[vi] + lift * 0.85).clamp(0.0, 1.0);
        // 白水/泡沫处更不透明：泡沫本来就挡住水下（这也是"急滩看不见底"的
        // 由来），顺带把水面的动效钉牢，不至于因为半透明而读成一层薄膜。
        colors[o + 3] = (baseA[vi] + lift * 0.4).clamp(0.0, 1.0);
      }
    }
  }

  /// 某处的泡沫亮度贡献（0–0.55）。湍流越高越亮、噪点越细密。
  ///
  /// 公开出来是为了让单测能直接把"泡沫亮度"和 [RiverFlow.turbulenceAt]
  /// 对上，而不是靠颜色缓冲反推（那样基色深浅会干扰判断）。
  double foamAt(double x, double z, double time) =>
      _foamCore(x, z, time, flow.turbulenceAt(x, z));

  double _foamCore(double x, double z, double time, double turb) {
    if (turb <= 0.02) return 0.0;
    // 越急的水，泡沫噪点空间频率越高 —— "浅滩碎、深潭静"的主要来源。
    final freq = 1.4 + 2.8 * turb;
    final n =
        _noise.fbm2(x * freq + 3.1, z * freq - time * 1.6, octaves: 2) * 0.5 +
            0.5;
    final density = turb * turb; // 只有足够急的水才翻白花
    return density * (0.30 + 0.70 * n) * 0.70;
  }

  // ------------------------------------------------------------------
  // 波场：给任意 (x, z, time) 的垂向位移（单测与涟漪共用同一条公式）
  // ------------------------------------------------------------------

  /// 某点某时刻的垂向位移（不含涟漪，米）。纯函数。
  double waveAt(double x, double z, double time) {
    final (left, right) = flow.banksAt(z);
    final halfW = math.max((right - left) * 0.5, 0.25);
    final cx = (left + right) * 0.5;
    final uSign = ((x - cx) / halfW).clamp(-1.2, 1.2);
    final lateral = (x - cx).abs() / halfW;
    final depth = math.max(flow.depthAt(x, z), 0.0);
    final turb = flow.turbulenceAt(x, z);
    final amp = _amplitude(depth, lateral, turb, _speedFactor(z));
    final rand = _phaseNoise(x, z);
    return _combine(amp, uSign, turb, rand, flow.flowPhase(z, time, omega1),
        flow.flowPhase(z, time, omega2), time);
  }

  /// 某点某时刻的垂向位移（含涟漪，米）。测试与调试用。
  double heightOffsetAt(double x, double z, double time) =>
      waveAt(x, z, time) +
      _rippleOffset(x, z, time) * _shoreDamp(flow.lateralAt(x, z));

  /// 只算涟漪那一部分的垂向位移（米），把基础行波剥掉，便于单测。
  double rippleOffsetAt(double x, double z, double time) =>
      _rippleOffset(x, z, time);

  /// 把行波（两个频率）、横向干涉、湍流碎波按权重叠起来，再归一化到
  /// |结果| ≤ amp。
  ///
  /// 除数 2.52 = 1.0 + 0.6 + 0.42 + 0.5 是四项振幅之和（湍流项满值时的上界），
  /// 于是**峰值位移严格不超过 [amp]** —— 这是"波峰不越过岸线"能成立的前提，
  /// 否则叠加波会在某个相位偷偷超出去。
  double _combine(double amp, double uSign, double turb, double rand, double p1,
      double p2, double time) {
    final w1 = math.sin(p1 + rand);
    final w2 = 0.6 * math.sin(p2 + rand * 1.7 + 1.0);
    // 横向干涉：中心与岸边反相，让水面出现"人"字形交叉而不是一整片平移。
    final w3 = 0.42 * math.sin(uSign * 4.2 - time * crossOmega + rand * 0.6);
    // 湍流白水：高频细碎起伏，与行波波长无关。
    final chop = turb * 0.5 * math.sin(uSign * 9.0 + p2 * 1.9 + rand * 2.3);
    return amp * (w1 + w2 + w3 + chop) * (1.0 / 2.52);
  }

  /// 局部振幅（米）。
  ///
  ///   * 中心振幅随**湍流**增强（浅滩更颠簸）；
  ///   * 再乘**流速因子**（快的地方起伏更大）—— 这条把动画和流场绑在一起，
  ///     是"相邻两帧位移变化量 ∝ 当地流速"的来源；
  ///   * 横向 + 水深双衰减，保证岸线处振幅为 0。
  double _amplitude(double depth, double lateral, double turb, double speedF) {
    // 0.15–0.26 是"河面尺度上看得见"的量级；换成静水 0.045m 那档，
    // 无论法线怎么更新都读成一张在动的贴图。
    final center = 0.15 + 0.11 * turb;
    final lt = (1.0 - lateral).clamp(0.0, 1.0);
    final lateralDecay = lt * lt * (3.0 - 2.0 * lt);
    final dt = (depth / 0.30).clamp(0.0, 1.0);
    final depthDecay = dt * dt * (3.0 - 2.0 * dt);
    final decay = math.min(lateralDecay, depthDecay);
    return (center * speedF * decay).clamp(0.0, maxAmplitude);
  }

  /// 断面流速相对全河的快/慢因子。
  ///
  /// 下限 0.7（最慢的深潭也别读成死水）、上限 1.7（最急的浅滩别把水面掀翻），
  /// 两端拉出约 2.4× 的差距 —— 这正是"相邻两帧位移变化量 ∝ 当地流速"的来源。
  double _speedFactor(double z) =>
      (flow.sectionSpeedAt(z) / _meanSpeed).clamp(0.7, 1.7);

  /// 涟漪的岸边阻尼（涟漪也不该拍上岸）。
  double _shoreDamp(double lateral) => (1.0 - 0.7 * lateral).clamp(0.0, 1.0);

  /// 位置哈希出的随机相位（[−π, π]）。用噪声而不是 `Random`，
  /// 是为了让 [waveAt] 对任意 (x,z) 与网格顶点算出一致的结果。
  double _phaseNoise(double x, double z) =>
      _noise.value2(x * 0.85 + 7.1, z * 0.85 - 3.4) * math.pi;

  // ------------------------------------------------------------------
  // 点源涟漪
  // ------------------------------------------------------------------

  /// 在 (x, z) 触发一个强度为 [strength]（约 0.1–0.4）的点源涟漪。
  ///
  /// 鱼的跃出、雨滴落水都调它。出生时间取最近一次 [update] 的 time，
  /// 所以调用方只管在两次 tick 之间触发即可。
  ///
  /// 合并规则：附近 [rippleMergeRadius] 内已有活跃涟漪时，**增强它并重新起振**，
  /// 而不是新增一个 —— 否则同一处连续落雨会堆出几百个同心圆，既卡又糊。
  void addRipple(double x, double z, double strength) {
    if (strength <= 0.0) return;

    var best = -1;
    var bestD2 = rippleMergeRadius * rippleMergeRadius;
    for (var k = 0; k < _rippleCount; k++) {
      final dx = x - _rippleX[k];
      final dz = z - _rippleZ[k];
      final d2 = dx * dx + dz * dz;
      if (d2 < bestD2) {
        bestD2 = d2;
        best = k;
      }
    }
    if (best >= 0) {
      _rippleStrength[best] =
          math.min(_rippleStrength[best] + strength, rippleMaxStrength);
      _rippleStart[best] = _now;
      return;
    }

    if (_rippleCount >= rippleCapacity) {
      // 满了就顶掉最弱的那个，而不是丢弃新事件 —— 新落的水花总是更该被看见。
      var weakest = 0;
      for (var k = 1; k < _rippleCount; k++) {
        if (_rippleStrength[k] < _rippleStrength[weakest]) weakest = k;
      }
      _rippleX[weakest] = x;
      _rippleZ[weakest] = z;
      _rippleStart[weakest] = _now;
      _rippleStrength[weakest] = math.min(strength, rippleMaxStrength);
      return;
    }

    _rippleX[_rippleCount] = x;
    _rippleZ[_rippleCount] = z;
    _rippleStart[_rippleCount] = _now;
    _rippleStrength[_rippleCount] = math.min(strength, rippleMaxStrength);
    _rippleCount++;
  }

  void _pruneRipples() {
    var k = 0;
    while (k < _rippleCount) {
      if (_now - _rippleStart[k] > rippleLifetime) {
        // swap-remove：原地压缩，不分配新列表。
        final last = _rippleCount - 1;
        _rippleX[k] = _rippleX[last];
        _rippleZ[k] = _rippleZ[last];
        _rippleStart[k] = _rippleStart[last];
        _rippleStrength[k] = _rippleStrength[last];
        _rippleCount = last;
      } else {
        k++;
      }
    }
  }

  /// 所有活跃涟漪在 (x, z) 处的垂向位移之和。
  ///
  /// 单个涟漪 = 一圈以 [rippleSpeed] 外扩的环形行波（波前附近包络最强）
  /// × 径向衰减 × 时间衰减，再加源头一个快速衰减的"水花"凸起 ——
  /// 后者保证 [addRipple] 之后该点位移**立刻**变化，而不是等波前扫回来。
  double _rippleOffset(double x, double z, double time) {
    if (_rippleCount == 0) return 0.0;
    var sum = 0.0;
    for (var k = 0; k < _rippleCount; k++) {
      final age = time - _rippleStart[k];
      if (age < 0.0 || age > rippleLifetime) continue;

      final dx = x - _rippleX[k];
      final dz = z - _rippleZ[k];
      final r = math.sqrt(dx * dx + dz * dz);
      // 径向衰减到 16m 处已不足 0.4%，更远的顶点直接跳过（省掉 exp/sin）。
      if (r > 16.0) continue;

      final life = math.exp(-age / 1.2);
      final radial = math.exp(-r * rippleRadialAtten);

      final front = rippleSpeed * age;
      final dr = r - front;
      final env = math.exp(-(dr * dr) / (2.0 * rippleSigma * rippleSigma));
      final ring = math.sin(rippleK * r - rippleOmega * age);
      final splash =
          math.exp(-(r * r) / (2.0 * 0.35 * 0.35)) * math.exp(-age / 0.30);

      sum += _rippleStrength[k] * life * (env * ring + 0.9 * splash) * radial;
    }
    return sum;
  }
}
