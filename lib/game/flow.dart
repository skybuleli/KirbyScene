/// 河流的**流场**：把河道几何翻译成一组水动力参数，供四个子系统共用。
///
/// ## 为什么要单独抽一层
///
/// 让"动起来"和"住进去"是同一件事的两面：水面波纹往哪边走、水草朝哪边倒、
/// 鱼逆流游到哪里、水流声有多急，背后都是**同一个流速场**。如果各系统各自
/// 拍一个公式，就会出现"波纹往上游跑、水草往下游倒、鱼群绕着圈"这种
/// 自相矛盾的画面 —— 单看每个都对，合起来读不出同一条河。
///
/// 所以这里只做一件事：给定 (x, z)，回答"这里的水有多快、朝哪个方向、
/// 有多深、有多湍"。所有消费者都从这一个源头取数。
///
/// ## 流速怎么算出来的
///
/// 先沿河道建一张逐行（z）的**断面表**：水面高程、左右岸、河宽、平均水深、
/// 断面积。然后只用一条严格的物理关系把流量摊开：
///
///   **连续性方程**（Q = v·A 沿程守恒）。取河道中段的断面积为参考断面、
///   把它的流速钉在 [referenceSpeed]，于是 v(z) = Q_ref / A(z)：
///   **窄而浅的断面自动变快**（浅滩急流），宽而深的断面自动变慢（深潭缓流）。
///   这正是真实河流的节奏，也是"水里看得出哪里急哪里缓"的来源 ——
///   不需要额外编一套速度曲线。
///
/// 横向再叠一层边界层效应：越靠岸越慢（v ∝ 1 − lateral^1.8），河心最快；
/// 表层再乘 [surfaceFactor]（明渠流速沿深度呈对数分布，水面附近最快）。
/// 弯道处加一点离心偏移，让水往凹岸（外侧）挤。
///
/// ## 为什么参考流速是"钉"出来的，而不是曼宁公式算出来的
///
/// 曼宁公式 v = (1/n)·R^(2/3)·S^(1/2) 是这类计算的常规起点，但**这条河道
/// 用不了**：本关卡河道全长 156m、上下游落差 7.7m，比降约 5%。天然平原
/// 河流的比降通常在 0.05%–0.5%，5% 已经是大山涧。把 5% 代进去，
/// n=0.05、R=0.6m 会得到约 3 m/s —— 实测整条河全部顶到上限，
/// 水面读成"洪水过境"，和卡比草原的调子完全不搭。
///
/// 所以这里反过来做：**先定一条小溪该有的速度（0.5 m/s），再让严格的
/// 连续性方程把它分配到每一段**。物理上等价于"给定这条河的实际流量"，
/// 只是这个流量由场景基调选定而非由比降反推 —— 分布规律（窄快宽慢、
/// 急滩白水、深潭平静）一条都没丢，丢掉的是那个不可信的比降。
library;
import 'dart:math' as math;

import 'package:vector_math/vector_math.dart' as vm;

import 'noise.dart';
import 'river.dart';
import 'terrain.dart';

/// 流场的逐行断面（沿 z 均匀采样，任意 z 处线性插值）。
class _Section {
  double z = 0;
  double waterY = 0;
  double left = 0;
  double right = 0;

  /// 水面宽度（米）。
  double width = 0;

  /// 断面平均水深（米）。
  double meanDepth = 0;

  /// 过水断面积（m²），连续性方程用的就是它。
  double area = 1e-6;

  /// 断面平均流速（m/s）。
  double speed = 0;

  /// 从上游 zStart 流到这里所需的累计时间（秒）。
  ///
  /// 波形按它推进，于是空间波距 λ = 2π·v/ω 正比于当地流速：
  /// 急流段波纹被拉长、深潭里波纹挤密（见 [RiverFlow.flowPhase]）。
  double travelTime = 0;

  /// 该断面的湍流强度 0–1（浅 + 快 = 白花花的急滩）。
  double turbulence = 0;
}

class RiverFlow {
  RiverFlow(this.terrain, {this.sections = 320, int seed = 5150})
      : _noise = ValueNoise(seed: seed) {
    _build();
  }

  final Terrain terrain;
  River get river => terrain.river;

  /// 断面采样数。320 段覆盖 156m 河道 → 约 0.49m 一段，
  /// 足以跟上河宽（周期约 90m）与水深的沿程变化。
  final int sections;

  final ValueNoise _noise;

  /// 逐行断面表（下标沿 z 从上游到下游）。
  late final List<_Section> _table;

  /// 参考断面流量（m³/s）—— 全河唯一守恒量。
  late double _discharge;

  /// 参考断面的目标流速（m/s）—— 断面**平均**流速。
  ///
  /// 0.5 m/s ≈ 一条草原小溪：看得出在流，又不至于把水草全部压平。
  /// 推导与取舍见文件头的说明。
  static const double referenceSpeed = 0.5;

  /// 表层流速 / 断面平均流速。
  ///
  /// 明渠的流速沿深度呈对数分布，水面附近最快。水面动画与水草受力
  /// 都属于"表层"的事，所以 [speedAt] 在断面平均之上再乘这个系数；
  /// 而连续性方程用的是断面平均（[sectionSpeedAt]），两者不能混。
  static const double surfaceFactor = 1.15;

  /// 水面高程：与 [Terrain.waterSurfaceAt] **逐位相同**（同一条解析式）。
  ///
  /// 这里刻意不去插值断面表：河床坡降是 smoothstep，沿程二阶变化明显，
  /// 320 段线性插值会带来最大约 4cm 的高差（实测 z≈−68 处）。4cm 对水面
  /// 本身无所谓，但水草/鱼虾是**贴着水位**放的 —— 水位差 4cm 就会出现
  /// "草尖穿出水面"或"鱼贴着水面飞"的穿帮。宁可多花一次 heightAt。
  double waterYAt(double z) =>
      terrain.heightAt(river.centerX(z), z) + river.waterDepth;

  /// 水面左右岸的 x。返回 (left, right)。
  (double, double) banksAt(double z) {
    final t = _rowParam(z);
    final i = t.floor().clamp(0, sections - 1);
    final f = (t - i).clamp(0.0, 1.0);
    final a = _table[i];
    final b = _table[math.min(i + 1, sections)];
    return (
      a.left + (b.left - a.left) * f,
      a.right + (b.right - a.right) * f,
    );
  }

  /// 水面宽度（米）。
  double widthAt(double z) => _lerpField(z, (s) => s.width);

  /// 断面平均流速（m/s）。
  double sectionSpeedAt(double z) => _lerpField(z, (s) => s.speed);

  /// 断面湍流强度 0–1。
  double sectionTurbulenceAt(double z) => _lerpField(z, (s) => s.turbulence);

  /// 断面平均水深（米）。
  double sectionDepthAt(double z) => _lerpField(z, (s) => s.meanDepth);

  /// 水底高程（= 水面 − 断面平均水深，逐行）。
  double bedYAt(double z) => _lerpField(z, (s) => s.waterY - s.meanDepth);

  /// 从上游 zStart 流到 z 的累计时间（秒）。
  double travelTimeAt(double z) => _lerpField(z, (s) => s.travelTime);

  /// 任意点的水深（米）。负值表示已上岸 —— 调用方通常应当先判 [isInWater]。
  double depthAt(double x, double z) => waterYAt(z) - terrain.heightAt(x, z);

  /// 该点是否在水面以下。
  bool isInWater(double x, double z) => terrain.heightAt(x, z) < waterYAt(z);

  /// 横向归一化位置：0 = 河心，1 = 岸边（超出岸线则 > 1）。
  double lateralAt(double x, double z) {
    final (left, right) = banksAt(z);
    final half = math.max((right - left) * 0.5, 0.25);
    final cx = (left + right) * 0.5;
    return ((x - cx).abs() / half);
  }

  /// 河道中心线上离 (x, z) **最近**的点，返回 `(centerX, z)`。
  ///
  /// 给空间音频定位声源用：河是一条**线声源**，听感上"那股水在哪个方向"
  /// 就是最近点的方向，而不是"玩家所在 z 处的那一段"。两者在直河段重合，
  /// 但在弯道上差别很大 —— 玩家站在弯道内倒时，最近的点可能在斜后方。
  ///
  /// 两阶段搜索：先在河道上粗扫 [coarse] 段找谷值，再在它两侧各一个粗格内
  /// 细扫一轮。蜿蜒周期约 90m、河道共 156m，粗采样 24 段（6.5m）已足以
  /// 落到正确的局部区域内，细化后精度约 0.3m（误差远小于水面的听觉尺寸）。
  /// 纯几何运算，与噪声/时间无关，可直接断言。
  (double, double) nearestCenterPoint(double x, double z, {int coarse = 24}) {
    final zStart = river.zStart;
    final zEnd = river.zEnd;
    final lo = math.min(zStart, zEnd);
    final hi = math.max(zStart, zEnd);

    double dist2(double zi) {
      final dx = river.centerX(zi) - x;
      final dz = zi - z;
      return dx * dx + dz * dz;
    }

    final step = (hi - lo) / coarse;
    var bestZ = z.clamp(lo, hi);
    var bestD2 = dist2(bestZ);
    for (var i = 0; i <= coarse; i++) {
      final zi = lo + step * i;
      final d2 = dist2(zi);
      if (d2 < bestD2) {
        bestD2 = d2;
        bestZ = zi;
      }
    }

    // 细化：在最优粗格内再扫 coarse 次。
    final fineLo = math.max(lo, bestZ - step);
    final fineHi = math.min(hi, bestZ + step);
    final fineStep = (fineHi - fineLo) / coarse;
    for (var i = 0; i <= coarse; i++) {
      final zi = fineLo + fineStep * i;
      final d2 = dist2(zi);
      if (d2 < bestD2) {
        bestD2 = d2;
        bestZ = zi;
      }
    }

    return (river.centerX(bestZ), bestZ);
  }

  /// 点处的**表层**流速（m/s）：断面平均 × 横向边界层剖面 × 表层系数。
  ///
  /// 靠岸衰减用 1 − lateral^1.8：河心平坦、近岸陡降，
  /// 比线性剖面更像实测的横向流速分布。
  double speedAt(double x, double z) {
    final v = sectionSpeedAt(z) *
        _lateralProfile(lateralAt(x, z)) *
        surfaceFactor;
    return math.max(v, 0.02);
  }

  /// 流向（XZ 平面的单位向量，指向下游）。
  ///
  /// 河道中心线的切向 + 弯道离心偏移：过弯时主泓偏向凹岸，
  /// 所以水里漂的东西会自然甩向外侧，而不是像火车一样贴着轨道走。
  vm.Vector2 directionAt(double x, double z) {
    final slope = river.centerSlope(z);
    final norm = math.sqrt(1.0 + slope * slope);
    // z 减小的方向是下游，故切向取 (−slope, −1)/|·|。
    var dx = -slope / norm;
    var dz = -1.0 / norm;

    // 离心偏移：曲率 ∝ d²x/dz²，乘速度得到横向推力（弯道外侧流速更高）。
    final curvature = _curvature(z);
    final lateral = _bendPush(x, z, curvature) * 0.22;
    // 横向单位向量（指向凹岸，即 x 增大的外侧）。
    final nx = 1.0 / norm;
    final nz = slope / norm;

    dx += nx * lateral;
    dz += nz * lateral;

    final len = math.sqrt(dx * dx + dz * dz);
    return vm.Vector2(dx / len, dz / len);
  }

  /// 点处的湍流强度 0–1：浅 + 快 → 白水；深潭一律平静。
  ///
  /// 再叠一层低频噪声：真实的急滩是**成片**出现的（卵石坝、倒木、
  /// 河床起伏），不是沿程均匀撒的。这一层给的是"这里有一处哗哗的水声"。
  double turbulenceAt(double x, double z) {
    final v = speedAt(x, z);
    final depth = math.max(depthAt(x, z), 0.06);
    // 弗劳德数的粗略替代：v/√(g·d) 越大越接近临界流（起白浪）。
    final froudeish = v / math.sqrt(9.81 * depth);
    final patch =
        _noise.fbm2(x * 0.09 + 2.7, z * 0.11 - 5.1, octaves: 2) * 0.5 + 0.5;
    final base = (froudeish / 0.55).clamp(0.0, 1.0);
    return (base * (0.55 + 0.45 * patch)).clamp(0.0, 1.0);
  }

  /// 波形相位驱动：把"时间"和"沿程流时"合起来，得到随局部流速推进的相位。
  ///
  /// 用法：`wave = sin(flowPhase(z, time, omega) + 随机相位)`。
  ///
  /// 物理图像是：上游持续放出一列**同频率**的波，各自以当地流速漂下来。
  /// 由此得到的空间波距 λ = 2π·v/ω **正比于当地流速** —— 浅滩（快）上波纹
  /// 被拉长，深潭（慢）里波纹挤密。
  ///
  /// 这看起来和"浅滩应该更碎"的直觉相反，但两者不是一回事：浅滩的碎来自
  /// **湍流白水**（[turbulenceAt]，那里会叠上去高密度的泡沫噪点），
  /// 而这里管的是那列**行波**的波长。分开之后，浅滩读作"长波 + 白浪"、
  /// 深潭读作"密纹 + 平静"，两层合起来才是活水该有的样子。
  double flowPhase(double z, double time, double omega) =>
      omega * (time - travelTimeAt(z));

  /// 全河的平均流速（m/s）：给音效做"这条河整体多急"的基准。
  double get meanSpeed {
    var sum = 0.0;
    for (var i = 0; i <= sections; i++) {
      sum += _table[i].speed;
    }
    return sum / (sections + 1);
  }

  /// 全河的平均湍流强度 0–1。
  double get meanTurbulence {
    var sum = 0.0;
    for (var i = 0; i <= sections; i++) {
      sum += _table[i].turbulence;
    }
    return sum / (sections + 1);
  }

  /// 全河最大流速（m/s）。
  double get maxSpeed {
    var best = 0.0;
    for (final s in _table) {
      if (s.speed > best) best = s.speed;
    }
    return best;
  }

  /// 全河总流量（m³/s）。
  double get discharge => _discharge;

  /// 向 (x, z) 处"下游"再走 [distance] 米后的坐标。
  ///
  /// 水草/鱼虾要沿流走一段、漂浮物要往下游漂，都需要这个。
  /// 用流向一阶推进即可 —— 河道曲率不大，够用。
  (double, double) stepDownstream(double x, double z, double distance) {
    final dir = directionAt(x, z);
    return (x + dir.x * distance, z + dir.y * distance);
  }

  // ------------------------------------------------------------------
  // 构建
  // ------------------------------------------------------------------

  /// 横向流速剖面（河心 1.25 → 岸边 0），乘到断面平均流速上。
  ///
  /// 系数 1.25 让"河心 = 1.25 × 断面平均"：剖面的横向积分约 0.8，
  /// 剩下那 20% 视作岸边极浅水区不参与主流量，不影响读感。
  double _lateralProfile(double lateral) {
    final t = lateral.clamp(0.0, 1.4);
    return (1.25 * (1.0 - math.pow(t, 1.8).toDouble())).clamp(0.02, 1.3);
  }

  /// 中心线曲率 d²x/dz²（用于弯道离心偏移）。
  double _curvature(double z) =>
      -river.meanderAmplitude * 0.05 * 0.05 * math.sin(z * 0.05) -
      river.meanderSecondary * 0.13 * 0.13 * math.sin(z * 0.13 + 1.1);

  /// 弯道推力：曲率为正（河道向右弯）时把水推向外侧。
  double _bendPush(double x, double z, double curvature) {
    final (left, right) = banksAt(z);
    final cx = (left + right) * 0.5;
    final sign = x >= cx ? 1.0 : -1.0;
    // 系数 9：弯道最急处曲率约 0.06，乘 9 再乘 0.22 得到约 0.12 的横向分量
    // （≈7°）。再大就不是"水往凹岸挤"，而是漂移物横着撞岸了。
    return curvature * 9.0 * sign;
  }

  void _build() {
    final zStart = river.zStart;
    final zEnd = river.zEnd;
    _table = List<_Section>.generate(sections + 1, (i) {
      final s = _Section();
      s.z = zStart + (zEnd - zStart) * (i / sections);
      return s;
    });

    // 第一遍：几何量（水位 / 岸线 / 水深 / 断面积）。
    for (final s in _table) {
      _measureSection(s);
    }

    // 参考断面取河道中段：那里既不是进出口（受地形边界影响），
    // 也不一定是最宽处 —— 中段最能代表这条河的"设计断面"。
    final ref = _table[sections ~/ 2];
    _discharge = math.max(referenceSpeed * ref.area, 1e-4);

    // 第二遍：由连续性方程定流量 → 逐行流速、湍流、流时。
    // 下限 0.06：最宽最深的深潭也不该读成死水；上限 1.05：小溪不该出现
    // 1m/s 以上的流速（那是山涧）。
    var travel = 0.0;
    for (var i = 0; i <= sections; i++) {
      final s = _table[i];
      s.speed = (_discharge / s.area).clamp(0.06, 1.05);
      if (i > 0) {
        final dz = (s.z - _table[i - 1].z).abs();
        // 用相邻两段的平均流速积分流时（梯形法）。
        final vAvg = math.max((s.speed + _table[i - 1].speed) * 0.5, 0.06);
        travel += dz / vAvg;
      }
      s.travelTime = travel;
      // 断面湍流只看断面平均量：横向差异由 turbulenceAt 负责。
      final froudeish = s.speed / math.sqrt(9.81 * math.max(s.meanDepth, 0.06));
      s.turbulence = (froudeish / 0.55).clamp(0.0, 1.0);
    }
  }

  /// 测量一行的水面范围与断面积。
  ///
  /// 扫描步长 0.25m、搜索半径 = 4 × 基础半宽，与水面网格的岸线扫描同量级；
  /// 两者结果一致是"水面网格与流场不打架"的前提。
  void _measureSection(_Section s) {
    final z = s.z;
    final cx = river.centerX(z);
    // 水位直接用解析式：它必须与 Terrain.waterSurfaceAt 完全一致。
    final waterY = terrain.heightAt(cx, z) + river.waterDepth;
    final limit = (river.halfWidthBase + river.halfWidthVariation) * 4.0;
    const step = 0.25;

    var left = cx;
    for (var d = 0.0; d <= limit; d += step) {
      if (terrain.heightAt(cx - d, z) > waterY) break;
      left = cx - d;
    }
    var right = cx;
    for (var d = 0.0; d <= limit; d += step) {
      if (terrain.heightAt(cx + d, z) > waterY) break;
      right = cx + d;
    }
    if (right - left < 0.8) {
      left = cx - 0.4;
      right = cx + 0.4;
    }

    s.waterY = waterY;
    s.left = left;
    s.right = right;
    s.width = right - left;

    // 断面积 = ∫ 水深 dx。用同一个步长求矩形和，顺带得到平均水深。
    var area = 0.0;
    var count = 0;
    for (var x = left + step * 0.5; x < right; x += step) {
      final d = waterY - terrain.heightAt(x, z);
      if (d <= 0) continue;
      area += d * step;
      count++;
    }
    if (count == 0) {
      // 退化保护：至少给一个"半米宽、10cm 深"的断面，避免除零。
      area = 0.05;
      s.meanDepth = 0.1;
    } else {
      s.meanDepth = area / (count * step);
    }
    s.area = math.max(area, 1e-4);
  }

  /// 河床坡降 S = −d(bedRamp)/dz（中心差分）。
  ///
  /// 现在不参与流速计算（见文件头对曼宁公式的取舍），但保留为公开诊断量：
  /// 调河道形态时，"这条河的比降是多少"是第一个要看数。
  double bedSlopeAt(double z) {
    const h = 1.0;
    final up = river.bedRamp(z + h);
    final down = river.bedRamp(z - h);
    return ((up - down) / (2 * h)).clamp(0.0, 0.5);
  }

  /// 把 z 映射成断面表的下标参数（浮点）。
  double _rowParam(double z) {
    final zStart = river.zStart;
    final zEnd = river.zEnd;
    final t = ((zStart - z) / (zStart - zEnd)).clamp(0.0, 1.0);
    return t * sections;
  }

  /// 沿 z 的标量场插值。
  double _lerpField(double z, double Function(_Section) pick) {
    final t = _rowParam(z);
    final i = t.floor().clamp(0, sections - 1);
    final f = (t - i).clamp(0.0, 1.0);
    return pick(_table[i]) + (pick(_table[i + 1]) - pick(_table[i])) * f;
  }
}
