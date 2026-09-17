/// 解析式蜿蜒河道。
///
/// ## 为什么是"解析式"而不是折线
///
/// 河道要参与**每一处**地形查询：`heightAt` 会被地形网格、法线、草地/灌木/
/// 乔木/石块的落点各调用几万次。折线需要空间索引才能在 O(1) 求"到中心线
/// 的距离"，而这里把河道写成 **x = f(z)** 的函数形式：
///   * 距离 ≈ |x − f(z)| · cos θ（θ 是中心线切向与 z 轴的夹角），一次求值即可；
///   * 参数 t 直接就是 z，水面高程、河宽、岸带都能沿 z 平滑变化；
///   * 没有离散采样，也就没有"折线段之间的接缝"。
///
/// 形态上用两个不同频率的正弦叠加：低频给大弯，高频给小摆，
/// 得到的蜿蜒比单频正弦自然得多（单频会明显周期重复）。
///
/// 河床高程由 [Terrain] 在雕刻时决定（取"坡降基准"与"局部地形 − 下切深度"
/// 的较小值），本类只负责提供几何与坡降基准。
library;
import 'dart:math' as math;

class River {
  const River({
    this.centerBase = 32.0,
    this.meanderAmplitude = 6.5,
    this.meanderSecondary = 2.5,
    this.halfWidthBase = 3.4,
    this.halfWidthVariation = 1.1,
    this.upstreamElevation = 2.2,
    this.downstreamElevation = -5.5,
    this.zStart = 78.0,
    this.zEnd = -78.0,
    this.valleyRadius = 15.0,
    this.waterDepth = 0.8,
  });

  /// 河道中心线离世界原点的基础距离（米）。
  ///
  /// 32m ± 9m：摆动后中心线离原点最近约 23m —— 既在玩法区
  /// （[Terrain.playRadius] = 17m + 过渡带）之外，又落在草地外沿之内。
  /// 再近的话河谷会啃到玩法区（实测 19m 时就会开始削平场地边缘）。
  final double centerBase;

  /// 主/次蜿蜒振幅（米）：低频大弯 + 高频小摆。
  final double meanderAmplitude;
  final double meanderSecondary;

  /// 水面半宽的基础值与变化幅度（米）。
  final double halfWidthBase;
  final double halfWidthVariation;

  /// 上下游河床高程（米）：水源在 +z，出水在 −z，**单调下降**才有合理流向。
  final double upstreamElevation;
  final double downstreamElevation;

  /// 河道起止 z。
  final double zStart;
  final double zEnd;

  /// 河谷影响半径（米）：超出此距离地形不再被河道改动。
  final double valleyRadius;

  /// 水深（米）：水面 = 河床 + 水深。
  final double waterDepth;

  /// 中心线 x 坐标（z 的函数）。
  double centerX(double z) =>
      centerBase +
      meanderAmplitude * math.sin(z * 0.05) +
      meanderSecondary * math.sin(z * 0.13 + 1.1);

  /// 中心线切向 dx/dz（用于把横向距离修正为垂直距离）。
  double centerSlope(double z) =>
      meanderAmplitude * 0.05 * math.cos(z * 0.05) +
      meanderSecondary * 0.13 * math.cos(z * 0.13 + 1.1);

  /// 水面半宽（米），沿程缓慢变化 —— 宽窄交替才有"浅滩/深潭"的读感。
  double halfWidth(double z) => halfWidthBase + halfWidthVariation * math.sin(z * 0.07 + 0.6);

  /// 河床坡降基准（米）：从上游线性下降到下游。
  ///
  /// 这是"理想河床"，实际河床还要保证低于两侧地形（见 Terrain 的雕刻）。
  double bedRamp(double z) {
    final t = ((zStart - z) / (zStart - zEnd)).clamp(0.0, 1.0);
    // smoothstep：两端与地形衔接更平缓，避免河道进出口出现台阶。
    final eased = t * t * (3.0 - 2.0 * t);
    return upstreamElevation +
        (downstreamElevation - upstreamElevation) * eased;
  }

  /// 到中心线的**垂直**距离（米）。
  ///
  /// 横向偏移 |x − f(z)| 除以切向长度得到垂直距离；
  /// 蜿蜒很缓（|dx/dz| ≪ 1）时两者几乎相同，这里做精确修正是为了
  /// 让河宽在急弯处不至于被拉伸。
  double distanceToCenter(double x, double z) {
    final dx = x - centerX(z);
    final slope = centerSlope(z);
    return dx.abs() / math.sqrt(1.0 + slope * slope);
  }

  /// 河谷权重：0 = 河谷中心，1 = 完全不受河道影响。
  ///
  /// 用 smootherstep（5 次）而不是线性：河岸到原有地形之间是**平滑抬升**，
  /// 这正是"不要突兀拼接"的要求。
  double valleyWeightAt(double normalizedDistance) {
    final t = normalizedDistance.clamp(0.0, 1.0);
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
  }

  /// [valleyWeightAt] 的便捷版本：按实际距离归一化。
  double valleyWeight(double distance) => valleyWeightAt(distance / valleyRadius);
}
