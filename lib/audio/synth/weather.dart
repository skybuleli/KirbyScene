/// 天气驱动的环境音**合成配方**：雨、风、夜（虫鸣）。
///
/// 三者与河流共用同一套机制（N 条无缝循环 + 等功率交叉淡化），只是波形与
/// "强度"的语义不同。全部是纯函数，可以在 `flutter test` 里断言频谱/包络，
/// 不需要扬声器。
///
/// ## 雨声为什么不能是"稀疏的水滴"
///
/// 这是本项目踩过的一个真实坑：上一版没有雨声层，玩家听到的"滴滴答答"其实来自
/// 每秒约 3 声的**鱼跃水花**一次性音效。反过来，如果照直觉去做"雨 = 稀疏的
/// 水滴声"，会得到同一个错误听感 —— 稀疏的水滴听起来是**漏水的水龙头**，不是雨。
///
/// 真实雨声是**致密到颗粒感融化成幕**的宽频噪声：
///
///   1. **雨幕**：高通后的白噪声（几百 Hz 以上），小雨偏"嘶"、大雨往下沉；
///   2. **体量**：大雨才有的低中频（400–800Hz），这是"雨大"的听觉重量；
///   3. **致密颗粒**：每秒 240–1600 次的微冲击（每次 2–8ms 的衰减）——
///      密度必须远高于人耳能分辨单个事件的速率（约 20/s），它们才会**融成**
///      一层砂质纹理。低于这个密度就退化成"滴水"。
///
/// 三者都随雨势变化，于是"雨势的视觉强度"与"听觉颗粒的粗细"是同一条参数。
library;
import 'dart:math' as math;
import 'dart:typed_data';

import '../pcm.dart';
import '../recipe.dart';

/// 雨：3 档（小雨 / 中雨 / 大雨），强度 = 雨势 0–1。
class RainAmbienceRecipe implements AmbienceRecipe {
  const RainAmbienceRecipe({this.seconds = 6.0});

  @override
  String get id => 'rain';

  @override
  int get variantCount => 3;

  @override
  final double seconds;

  @override
  Float64List bake(int i, int sampleRate, int seed) {
    final u = variantStrength(i, variantCount);
    final rng = PcmRng(seed + i * 9001);

    // 三个频层，比例随雨势移动。
    //
    // ⚠️ 方向必须对：**小雨几乎全是高频"嘶"，大雨往中低频沉**。
    // 第一版把高通截止随雨势上调（小雨 760Hz → 大雨 1280Hz），等于"雨越大越低频"
    // 写反了 —— 实测大雨的 300Hz 以下能量占比反而比小雨更低（0.172 vs 0.174），
    // 听感上小雨比大雨还闷。现在高频层的**增益**随雨势下降、低中频层的**增益**
    // 随雨势上升，方向就对了。
    final hissA = onePoleHighPassAlpha(1500.0, sampleRate);
    final bodyA = onePoleAlpha(300.0 + 420.0 * u, sampleRate);
    // 统一的柔化：不做的话 8kHz 以上的颗粒会很刺耳。
    final topA = onePoleAlpha(6500.0, sampleRate);

    final hissGain = 0.62 - 0.22 * u;
    final bodyGain = 0.10 + 0.58 * u;

    // 致密颗粒：每秒次数与单次衰减。
    final density = 240.0 + 1600.0 * u;
    final grainAmp = 0.035 + 0.060 * u;
    final grainDecay = math.exp(-1.0 / (0.004 * sampleRate));

    // 阵性起伏（慢、浅）——雨势的呼吸。
    final gustHz = loopLockedFreq(0.11 + 0.21 * u, seconds);
    final gustDepth = 0.09 + 0.09 * u;
    final gustPhase = rng.unit() * math.pi * 2;

    return seamlessLoop(
      seconds: seconds,
      sampleRate: sampleRate,
      rng: rng,
      peak: 0.90,      generate: (buf, total, r) {
        var hpPrevIn = 0.0, hpPrevOut = 0.0, body = 0.0, top = 0.0;
        var grainEnv = 0.0;
        var nextGrain = 0;
        for (var i = 0; i < total; i++) {
          final w = r.white();

          // 一阶高通取雨幕的高频段（低频要削：不削的话电平表被低频吃掉，
          // 高频细节全被压没，而且那层低频会和体量层重复计算）。
          hpPrevOut = hissA * (hpPrevOut + w - hpPrevIn);
          hpPrevIn = w;
          body += (w - body) * bodyA;

          // 致密颗粒：O(n) 的泊松冲击（指数间隔），融成砂质纹理而不是"滴水"。
          if (i >= nextGrain) {
            grainEnv = 1.0;
            nextGrain = i + math.max(1, (-math.log(1.0 - r.unit() * 0.999999) /
                    density * sampleRate).round());
          }
          grainEnv *= grainDecay;

          final t = i / sampleRate;
          final gust = 1.0 + gustDepth * math.sin(2 * math.pi * gustHz * t + gustPhase);
          final mixed =
              hpPrevOut * hissGain + body * bodyGain + grainEnv * w * grainAmp;
          top += (mixed - top) * topA;
          buf[i] = gust * top;
        }
      },
    );
  }

  @override
  BandBlend blend(double strength) => bandBlend(strength, variantCount);
}

/// 风：3 档（轻风 / 中风 / 强风），强度 = 风力 0–1。
///
/// 风与水在合成上的根本区别是**包络的时间尺度**：水是持续不断的，风是**一阵一阵**
/// 的。所以风声的主体是几个低频正弦包络（0.09–0.5Hz，深度随风力加深），
/// 而不是恒定噪声。
///
/// 另外单独一层"叶隙哨音"：高频（1.8kHz 以上）噪声乘以**阵性包络的平方** ——
/// 阵风来的时候声音才"沙"起来。这一层让风听起来是**穿过草地**的风，
/// 而不是一条白噪声带。
class WindAmbienceRecipe implements AmbienceRecipe {
  const WindAmbienceRecipe({this.seconds = 8.0});

  @override
  String get id => 'wind';

  @override
  int get variantCount => 3;

  @override
  final double seconds;

  @override
  Float64List bake(int i, int sampleRate, int seed) {
    final u = variantStrength(i, variantCount);
    final rng = PcmRng(seed + i * 4327);

    final rumbleA = onePoleAlpha(85.0 + 80.0 * u, sampleRate);
    final whistleA = onePoleAlpha(380.0 + 760.0 * u, sampleRate);
    final leafA = onePoleHighPassAlpha(1700.0 + 900.0 * u, sampleRate);

    // 三个阵性分量：周期成分必须吸附到循环长度的整数周期，否则每次循环包络会
    // "重置"一下（听感就是断断续续）。
    final g1 = loopLockedFreq(0.09 + 0.07 * u, seconds);
    final g2 = loopLockedFreq(0.19 + 0.13 * u, seconds);
    final g3 = loopLockedFreq(0.34 + 0.22 * u, seconds);
    final p1 = rng.unit() * math.pi * 2;
    final p2 = rng.unit() * math.pi * 2;
    final p3 = rng.unit() * math.pi * 2;
    final d1 = 0.34 + 0.18 * u;
    final d2 = 0.22 + 0.14 * u;
    final d3 = 0.12 + 0.10 * u;

    return seamlessLoop(
      seconds: seconds,
      sampleRate: sampleRate,
      rng: rng,
      peak: 0.88,
      generate: (buf, total, r) {
        var rumble = 0.0, whistle = 0.0, leafPrevIn = 0.0, leafPrevOut = 0.0;
        for (var j = 0; j < total; j++) {
          final t = j / sampleRate;
          final w = r.white();

          rumble += (w - rumble) * rumbleA;
          whistle += (w - whistle) * whistleA;
          leafPrevOut = leafA * (leafPrevOut + w - leafPrevIn);
          leafPrevIn = w;

          final gust = 1.0 +
              d1 * math.sin(2 * math.pi * g1 * t + p1) +
              d2 * math.sin(2 * math.pi * g2 * t + p2) +
              d3 * math.sin(2 * math.pi * g3 * t + p3);
          final g = math.max(gust, 0.05);
          // 平方项：叶隙哨音只在阵风峰上出现。
          final rustle = leafPrevOut * g * g * (0.10 + 0.26 * u);

          buf[j] = g * (rumble * (0.55 + 0.30 * u) + whistle * (0.20 + 0.26 * u)) +
              rustle;
        }
      },
    );
  }

  @override
  BandBlend blend(double strength) => bandBlend(strength, variantCount);
}

/// 夜：虫鸣（单档，靠层音量淡入淡出）。
///
/// 合成方式是一群**互相错拍的蟋蟀**：每只一个被吸附到循环整数周期的鸣叫频率
/// （2.4–5.6Hz）与自己的载频（3.4–4.8kHz），幅度用 `sin^6` 塑形 —— 于是它读起来
/// 是"此起彼伏的虫声"，而不是一条持续的蜂鸣。
///
/// 夜层的价值不只是"多一点声音"：夜里风与雨通常很小，没有它整座草原会是静的，
/// 反而显得夜景像没做完。
class NightAmbienceRecipe implements AmbienceRecipe {
  const NightAmbienceRecipe({this.seconds = 8.0, this.crickets = 9});

  @override
  String get id => 'night';

  @override
  int get variantCount => 1;

  @override
  final double seconds;

  /// 蟋蟀只数。够多才像"一片"虫声，太多则变成蜂鸣。
  final int crickets;

  @override
  Float64List bake(int i, int sampleRate, int seed) {
    final rng = PcmRng(seed + 6613);
    final n = math.max(1, (seconds * sampleRate).round());

    // 每只虫：鸣叫频率（吸附整数周期）+ 载频 + 相位。
    final chirpH = List<double>.generate(
        crickets, (k) => loopLockedFreq(2.4 + rng.unit() * 3.2, seconds));
    final carrier = List<double>.generate(
        crickets, (k) => 3400.0 + rng.unit() * 1400.0);
    final phase = List<double>.generate(crickets, (k) => rng.unit() * math.pi * 2);
    final level = List<double>.generate(crickets, (k) => 0.25 + rng.unit() * 0.75);

    final buf = Float64List(n);
    // 背景空气声（极轻的低频），让虫声不是悬在真空里。
    final airA = onePoleAlpha(300.0, sampleRate);
    var air = 0.0;

    for (var j = 0; j < n; j++) {
      final t = j / sampleRate;
      var s = 0.0;
      for (var k = 0; k < crickets; k++) {
        // sin^6 塑形：短暂而清脆的一声声"唧"，不是连续的鸣叫。
        final e = math.sin(2 * math.pi * chirpH[k] * t + phase[k]);
        if (e <= 0) continue;
        final env = e * e * e * e * e * e;
        s += math.sin(2 * math.pi * carrier[k] * t) * env * level[k];
      }
      final w = rng.white();
      air += (w - air) * airA;
      buf[j] = s * 0.42 + air * 0.05;
    }

    normalizePeak(buf, 0.70);
    return buf;
  }

  @override
  BandBlend blend(double strength) => const BandBlend(0, 0, 1, 0, 0);
}

/// 第 [i] 档（共 [count] 档）代表的强度 0–1。
double variantStrength(int i, int count) =>
    count <= 1 ? 1.0 : (i / (count - 1)).clamp(0.0, 1.0);
