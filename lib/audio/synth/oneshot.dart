/// **一次性音效**的合成配方：脚步 / 跳跃 / 落地 / 采集 / 界面 / 过关，
/// 以及水花（鱼跃出水面落回）。
///
/// 与循环类环境音的区别只在"怎么播"：这些是**短促的、事件驱动**的声音，播一次
/// 就完，所以不需要无缝循环那套 overlap-add。合成上它们都遵循同一条真实录音的
/// 结构 —— **一个瞬态 + 一个阻尼共振体**：
///
///   * 脚步 = 极短的宽带噪声（鞋与草/土的摩擦、踩断的细枝）+ 一个低沉的体量；
///   * 落地 = 更低更长的体量 + 噪声，**力度越大越响越低**（[landPcm] 的 impact）；
///   * 采集/界面 = 阻尼正弦（"叮"），谐波按 2.01 / 3.03 倍取（**刻意非整数**，
///     整倍数会听成风琴，非整数才是金属/玻璃的钟声）；
///   * 水花 = 宽带噪声爆发（水被撕开）+ 低频阻尼音（那声"咚"来自水体的质量）。
///
/// 所有函数都不依赖 Flutter / 音频库，可单测。
library;
import 'dart:math' as math;
import 'dart:typed_data';

import '../pcm.dart';

/// 水花声（鱼跃出水面落回）。
///
/// [size] 是肇事鱼的体长（米）：越大越响、衰减越慢、那声"咚"越低。
Float64List splashPcm({
  required double size,
  required int sampleRate,
  int seed = 991,
  double seconds = 0.55,
}) {
  final rng = PcmRng(seed);
  final n = math.max(1, (seconds * sampleRate).round());
  final buf = Float64List(n);

  final body = size.clamp(0.2, 1.0);
  final tau = 0.055 + 0.075 * body;
  final thumpHz = 150.0 - 45.0 * body;
  final aBand = onePoleAlpha(2200.0 + 1800.0 * body, sampleRate);
  var band = 0.0;

  for (var i = 0; i < n; i++) {
    final t = i / sampleRate;
    // 3ms 的起音，避免"啪"的一声爆音（扬声器上很刺耳）。
    final attack = (t / 0.003).clamp(0.0, 1.0);
    final decay = math.exp(-t / tau);

    final w = rng.white();
    band += (w - band) * aBand;

    final noise = (w * 0.35 + band * 0.75) * decay * attack;
    final thump = math.sin(2 * math.pi * thumpHz * t) *
        math.exp(-t / (tau * 1.6)) *
        (0.30 - 0.10 * body) *
        attack;
    buf[i] = noise * (0.55 + 0.45 * body) + thump;
  }

  normalizePeak(buf, 0.85);
  return buf;
}

/// 脚步踩在什么上。三者决定噪声的频段与尾巴的长短。
enum StepSurface {
  /// 草地：中高频的"沙"，尾巴很短。
  grass(highCut: 5200, lowCut: 900, seconds: 0.13),

  /// 沙土：更闷、更干，几乎没有高频。
  soil(highCut: 2600, lowCut: 420, seconds: 0.12),

  /// 浅水/水边：更亮更长，多一个"啪叽"的水声。
  water(highCut: 7000, lowCut: 1200, seconds: 0.22);

  const StepSurface({
    required this.highCut,
    required this.lowCut,
    required this.seconds,
  });

  final double highCut;
  final double lowCut;
  final double seconds;
}

/// 一声脚步。[variant] 只影响随机种子 —— 同一个表面准备 3–4 个变体轮换，
/// 否则连续几步会听出"同一段录音在重复"。
Float64List footstepPcm({
  required StepSurface surface,
  required int variant,
  required int sampleRate,
  int seed = 331,
}) {
  final rng = PcmRng(seed + variant * 131 + surface.index * 977);
  final n = math.max(1, (surface.seconds * sampleRate).round());
  final buf = Float64List(n);

  final lpA = onePoleAlpha(surface.highCut, sampleRate);
  final bodyA = onePoleAlpha(180.0 + rng.unit() * 90.0, sampleRate);
  // 起音 4–9ms：太陡会"啪"一声像拍手，太缓又不像踩下去。
  final attackSec = 0.004 + rng.unit() * 0.005;
  final tau = surface.seconds * (0.22 + rng.unit() * 0.16);

  var lp = 0.0, body = 0.0, hpPrevIn = 0.0, hpPrevOut = 0.0;
  final hpA = onePoleHighPassAlpha(surface.lowCut, sampleRate);

  for (var i = 0; i < n; i++) {
    final t = i / sampleRate;
    final attack = (t / attackSec).clamp(0.0, 1.0);
    final decay = math.exp(-t / tau);

    final w = rng.white();
    lp += (w - lp) * lpA;
    body += (w - body) * bodyA;
    hpPrevOut = hpA * (hpPrevOut + w - hpPrevIn);
    hpPrevIn = w;

    buf[i] = (lp * 0.55 + hpPrevOut * 0.35) * decay * attack +
        body * 0.22 * math.exp(-t / (tau * 0.6)) * attack;
  }

  normalizePeak(buf, surface == StepSurface.water ? 0.72 : 0.62);
  return buf;
}

/// 起跳。卡比是软的东西，所以不是"蹦床"，而是一声**上行的气音**。
Float64List jumpPcm({required int sampleRate, int seed = 777}) {
  final rng = PcmRng(seed);
  const seconds = 0.22;
  final n = (seconds * sampleRate).round();
  final buf = Float64List(n);

  final lpA = onePoleAlpha(3000, sampleRate);
  var lp = 0.0;

  for (var i = 0; i < n; i++) {
    final t = i / sampleRate;
    // 上行扫频 260 → 620Hz：方向性本身就是"往上跳"的听觉线索。
    final hz = 260.0 + 360.0 * (t / seconds);
    final env = math.exp(-t / (seconds * 0.38)) * (t / 0.008).clamp(0.0, 1.0);
    final w = rng.white();
    lp += (w - lp) * lpA;
    buf[i] = math.sin(2 * math.pi * hz * t) * env * 0.75 +
        lp * env * 0.32;
  }

  normalizePeak(buf, 0.70);
  return buf;
}

/// 落地。[impact] 0–1 由下落速度给出：越重越响、越低、尾巴越长。
Float64List landPcm({
  required double impact,
  required int sampleRate,
  int seed = 555,
}) {
  final rng = PcmRng(seed);
  final k = impact.clamp(0.0, 1.0);
  const seconds = 0.30;
  final n = (seconds * sampleRate).round();
  final buf = Float64List(n);

  final hz = 150.0 - 55.0 * k;
  final tau = 0.045 + 0.075 * k;
  final lpA = onePoleAlpha(1400.0 + 800.0 * k, sampleRate);
  var lp = 0.0;

  for (var i = 0; i < n; i++) {
    final t = i / sampleRate;
    final attack = (t / 0.004).clamp(0.0, 1.0);
    final w = rng.white();
    lp += (w - lp) * lpA;
    buf[i] = (math.sin(2 * math.pi * hz * t) * math.exp(-t / tau) * 0.85 +
            lp * math.exp(-t / (tau * 0.5)) * 0.35) *
        attack;
  }

  normalizePeak(buf, 0.60 + 0.30 * k);
  return buf;
}

/// 采集到星核：两个音的上行（短促、明亮、有金属尾）。
Float64List pickupPcm({required int sampleRate, int seed = 2024}) {
  return _bellChime(
    sampleRate: sampleRate,
    // 五声音阶的两个音（C6 → G6），听起来"采到了"而不是"报警了"。
    notes: const [
      (at: 0.00, hz: 1046.5, gain: 0.85, dur: 0.55),
      (at: 0.075, hz: 1568.0, gain: 0.70, dur: 0.60),
    ],
  );
}

/// 界面音（切天气 / 重开）：一个更干、更短的单音。
Float64List uiPcm({required int sampleRate, int seed = 88}) {
  return _bellChime(
    sampleRate: sampleRate,
    notes: const [(at: 0.0, hz: 880.0, gain: 0.55, dur: 0.16)],
    peak: 0.55,
  );
}

/// 过关：四个音的上行琶音。
Float64List fanfarePcm({required int sampleRate, int seed = 4242}) {
  return _bellChime(
    sampleRate: sampleRate,
    notes: const [
      (at: 0.00, hz: 784.0, gain: 0.70, dur: 0.45),
      (at: 0.12, hz: 1046.5, gain: 0.70, dur: 0.45),
      (at: 0.24, hz: 1318.5, gain: 0.70, dur: 0.50),
      (at: 0.36, hz: 1568.0, gain: 0.85, dur: 1.10),
    ],
  );
}

/// 把若干"钟音"叠加成一个缓冲。
///
/// 谐波比例刻意用 2.01 / 3.03 而不是 2.0 / 3.0：**整数倍泛音会听成风琴/方波**，
/// 轻微失谐才有金属或玻璃的质感（真实物体很难做到精确的整数倍）。
Float64List _bellChime({
  required int sampleRate,
  required List<({double at, double hz, double gain, double dur})> notes,
  double peak = 0.85,
}) {
  final end = notes
      .map((n) => n.at + n.dur)
      .reduce(math.max);
  final n = math.max(1, (end * sampleRate).round());
  final buf = Float64List(n);

  for (final note in notes) {
    final start = (note.at * sampleRate).round();
    final len = (note.dur * sampleRate).round();
    for (var i = 0; i < len; i++) {
      final idx = start + i;
      if (idx >= n) break;
      final t = i / sampleRate;
      final attack = (t / 0.005).clamp(0.0, 1.0);
      final env = math.exp(-t / (note.dur * 0.30)) * attack;
      buf[idx] += note.gain *
          env *
          (math.sin(2 * math.pi * note.hz * t) +
              0.34 * math.sin(2 * math.pi * note.hz * 2.01 * t) +
              0.14 * math.sin(2 * math.pi * note.hz * 3.03 * t));
    }
  }

  normalizePeak(buf, peak);
  return buf;
}
