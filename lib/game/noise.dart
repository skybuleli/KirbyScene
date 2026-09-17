/// 跨平台确定性噪声。
///
/// 刻意**不用** `FastNoiseLite`：flutter_scene 的 `procedural` skill 明确警告，
/// 它的 32 位整数哈希在 web（dart2js 把 `int` 当 double，只有 53 位精确）上会丢低位，
/// 3D 噪声溢出并**静默**产出一个"看起来合理但是错的"场。本项目要走 Web 预览，
/// 一旦地形在 web 与原生上不一致，放置的草/道具/角色落点全会错位。
///
/// 这里的做法：所有整数运算都保持 32 位以内并用 `& 0xFFFFFFFF` 掩码
/// （JS 的位运算符本身就是 32 位整数语义），插值只用 IEEE double 四则运算，
/// 因此 Dart VM 与 dart2js 的结果完全一致。

library;
import 'dart:math' as math;

class ValueNoise {
  const ValueNoise({this.seed = 1337});

  final int seed;

  /// 32 位终结混淆（xorshift-multiply 风格），全程掩码在 32 位内。
  static int _mix(int h) {
    var x = h & 0xFFFFFFFF;
    x ^= x >> 16;
    x = (x * 0x7feb352d) & 0xFFFFFFFF;
    x ^= x >> 15;
    x = (x * 0x846ca68b) & 0xFFFFFFFF;
    x ^= x >> 16;
    return x & 0xFFFFFFFF;
  }

  int _hash2(int x, int y) {
    var h = (x * 0x27d4eb2d) & 0xFFFFFFFF;
    h = (h + (y * 0x165667b1)) & 0xFFFFFFFF;
    h = (h + (seed * 0x9e3779b1)) & 0xFFFFFFFF;
    return _mix(h);
  }

  /// 格点随机值，范围 [-1, 1]。
  double _lattice(int x, int y) => _hash2(x, y) / 0xFFFFFFFF * 2.0 - 1.0;

  /// 二维值噪声，范围约 [-1, 1]。
  double value2(double x, double y) {
    final xi = x.floor();
    final yi = y.floor();
    final u = _smooth(x - xi);
    final v = _smooth(y - yi);

    final a = _lattice(xi, yi);
    final b = _lattice(xi + 1, yi);
    final c = _lattice(xi, yi + 1);
    final d = _lattice(xi + 1, yi + 1);

    return _lerp(_lerp(a, b, u), _lerp(c, d, u), v);
  }

  /// 分形叠加（fbm）：高频叠在低频上，得到自然起伏。范围约 [-1, 1]。
  double fbm2(
    double x,
    double y, {
    int octaves = 5,
    double lacunarity = 2.0,
    double gain = 0.5,
  }) {
    var amplitude = 1.0;
    var frequency = 1.0;
    var sum = 0.0;
    var norm = 0.0;
    for (var i = 0; i < octaves; i++) {
      sum += amplitude * value2(x * frequency, y * frequency);
      norm += amplitude;
      amplitude *= gain;
      frequency *= lacunarity;
    }
    return norm == 0 ? 0 : sum / norm;
  }

  /// 脊状噪声：制造尖锐的侵蚀折痕，用于山脊与崖壁。
  /// （`procedural` skill：连续 fbm 只会得到圆滚滚的土包，山体要用 ridged。）
  double ridged2(double x, double y, {int octaves = 4}) {
    var amplitude = 1.0;
    var frequency = 1.0;
    var sum = 0.0;
    var norm = 0.0;
    for (var i = 0; i < octaves; i++) {
      final n = 1.0 - value2(x * frequency, y * frequency).abs();
      sum += amplitude * n * n;
      norm += amplitude;
      amplitude *= 0.5;
      frequency *= 2.0;
    }
    if (norm == 0) return 0;
    return (sum / norm) * 2.0 - 1.0;
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  /// 5 次平滑插值（smootherstep），比线性插值少很多格子感。
  static double _smooth(double t) => t * t * t * (t * (t * 6 - 15) + 10);
}

/// 泊松盘采样：让草与道具分布自然（不聚堆、不留大空白），
/// 对应 `kit` skill 里的 `PoissonDiscSampler` 的思路；这里保持纯 Dart 以便复用。
List<math.Point<double>> poissonDisc(
  int count,
  double radius,
  math.Random rng, {
  int attempts = 24,
}) {
  final cell = radius / math.sqrt2;
  final grid = <String, math.Point<double>>{};
  final points = <math.Point<double>>[];

  String key(int gx, int gy) => '$gx:$gy';

  bool fits(double x, double y) {
    final gx = (x / cell).floor();
    final gy = (y / cell).floor();
    for (var dx = -2; dx <= 2; dx++) {
      for (var dy = -2; dy <= 2; dy++) {
        final other = grid[key(gx + dx, gy + dy)];
        if (other == null) continue;
        final ddx = other.x - x;
        final ddy = other.y - y;
        if (ddx * ddx + ddy * ddy < radius * radius) return false;
      }
    }
    return true;
  }

  points.add(math.Point<double>(rng.nextDouble() * radius, rng.nextDouble() * radius));
  grid[key((points.first.x / cell).floor(), (points.first.y / cell).floor())] = points.first;

  var guard = 0;
  while (points.length < count && guard < count * attempts) {
    guard++;
    final base = points[rng.nextInt(points.length)];
    final angle = rng.nextDouble() * math.pi * 2;
    final dist = radius * (1 + rng.nextDouble());
    final x = base.x + math.cos(angle) * dist;
    final y = base.y + math.sin(angle) * dist;
    if (!fits(x, y)) continue;
    final p = math.Point<double>(x, y);
    points.add(p);
    grid[key((x / cell).floor(), (y / cell).floor())] = p;
  }
  return points;
}
