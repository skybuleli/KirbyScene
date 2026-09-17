/// 一层环境音的**烘焙配方**与**档位交叉淡化**。
///
/// 把"一层环境音"抽象成"N 条无缝循环 + 一个由层强度决定的档权重"，是因为
/// 四层（河 / 雨 / 风 / 夜）需要的机制完全相同，只有波形与"强度"的语义不同：
///
///   河：强度 = 那段水有多急（深潭 → 急滩）
///   雨：强度 = 雨势（小雨 → 大雨）
///   风：强度 = 风力（轻风 → 强风）
///   夜：强度 = 夜色（只是淡入淡出，单档）
///
/// 于是"加一层新的环境音"= 写一个 [AmbienceRecipe]，播放侧一行都不用改。
library;
import 'dart:math' as math;
import 'dart:typed_data';

import 'pcm.dart';

/// 一次交叉淡化的结果：参与的两档与它们**线性幅度**权重。
class BandBlend {
  const BandBlend(this.a, this.b, this.wa, this.wb, this.fraction);

  /// 低档 / 高档索引（`a <= b`）。
  final int a;
  final int b;

  /// 两档的线性幅度权重。等功率：`wa² + wb² == 1`。
  final double wa;
  final double wb;

  /// 落在 a 与 b 之间的位置 0–1（仅用于诊断与测试）。
  final double fraction;

  @override
  String toString() => 'BandBlend($a,$b wa=${wa.toStringAsFixed(3)} '
      'wb=${wb.toStringAsFixed(3)})';
}

/// 把 0–1 的强度映射到 [count] 档里相邻两档的等功率权重。
///
/// 等功率（`cos/sin`）而不是线性（0.5/0.5）：两条**不相关**的噪声叠加时总功率
/// 相加，线性淡化会让中点的总功率掉 3dB —— 听感上就是"经过档位时音量顿一下"。
/// 这是"切换档位不能有突兀感"这条需求的数学落点。
BandBlend bandBlend(double strength, int count) {
  if (count <= 1) return const BandBlend(0, 0, 1, 0, 0);
  final u = strength.clamp(0.0, 1.0) * (count - 1);
  final a = u.floor().clamp(0, count - 1);
  final b = math.min(a + 1, count - 1);
  final f = a == b ? 0.0 : (u - a).clamp(0.0, 1.0);
  final w = equalPower(f);
  return BandBlend(a, b, w.a, w.b, f);
}

/// 一层环境音的烘焙配方。
///
/// **注意这里没有"资源名"这个概念** —— 这是刻意的。资源名以前由配方自己提供
/// （`variantName`），结果配方写 `river_band_$i`、而烘焙任务按 `id_$i` 生成，
/// 两边对不上：资产烘好了、却永远装不进对应的层（实测"河一整层没有声音"）。
/// 现在名字只有 [ambienceAsset] 一个来源。
abstract interface class AmbienceRecipe {
  /// 稳定标识（同时用作引擎里的资源名前缀，便于诊断看清"哪一层在播"）。
  String get id;

  /// 档数。1 = 单档（只做淡入淡出）。
  int get variantCount;

  /// 每条循环的长度（秒）。越长越不容易听出重复，但烘焙越贵。
  double get seconds;

  /// 档 [i] 的波形。
  Float64List bake(int i, int sampleRate, int seed);

  /// 层强度 0–1 → 档权重。
  BandBlend blend(double strength);
}

/// 环境音变体在引擎资源表里的**唯一**命名规则。
String ambienceAsset(String recipeId, int variant) => '${recipeId}_$variant';
