/// 河流音效的**合成器 + 混音参数**：不依赖任何音频库、不读任何音频文件，
/// 只吐 PCM 字节。是本项目"零音频资产"约束下河流那一层声音的全部来源。
///
/// ## 一次烘焙多档，实时只做混合
///
/// [RiverSoundSynth.flowLoop] 每条循环对应"这条河有多急"轴上的一个采样点
/// （[RiverSoundMix.bandSpec]）。播放侧把所有档一起喂给音频引擎（都是无缝循环、
/// 由引擎保证接缝），实时只做两件事：**相邻两档的等功率交叉淡化** +
/// **轻微的速率调整**。
///
/// 这样做的好处不只是音色能变 —— 还顺手把"实时合成"的风险全避开了：音频数据
/// 全部预烘焙在内存里，不依赖每帧喂 PCM，于是**帧冻结/掉帧不会造成断流**。
///
/// ## 流水声是什么声音
///
/// 湍流把水流的动能摊成**宽带噪声**，气泡在溃灭瞬间发出**阻尼单音**，水体的
/// 质量感则是低频段。所以合成器由三层构成，每一层对应一个可听出来的物理量：
///
///   1. **粉噪声底**（三个截止频率递增的一阶低通之和）：水体的"沙沙"底噪。
///   2. **高频亮层**：增益随 `turbulence` 上升。这是"急滩"的听觉标记，
///      也是水流动态在音色上的落点。
///   3. **气泡**：稀疏的阻尼正弦（泊松分布撒点，密度随湍流上升）。
///      没有它，剩下的就是一坨噪声 —— 气泡是"水"与"风"的分界线。
///
/// 再叠一层**快而浅**的振幅调制（0.9–3.5Hz，不是 0.1–0.5Hz 的"呼吸"）：
/// 真实溪流的底噪是持续不断的，起伏来自细碎的气泡与小浪，频率远高于"呼吸"。
/// 所有周期性成分都吸附到循环长度的整数个周期上，否则包络会在每个循环边界
/// 重置一次 —— 那正是"断断续续"的来源。
library;
import 'dart:math' as math;
import 'dart:typed_data';

import '../pcm.dart';
import '../recipe.dart';
import 'oneshot.dart';

/// 一次合成的参数。都是"可听出来的量"，不是玄学旋钮：
/// [speed] 0–1（当地流速归一化）、[turbulence] 0–1（白水强度）。
class RiverSoundSpec {
  const RiverSoundSpec({
    required this.seconds,
    required this.speed,
    required this.turbulence,
  });

  final double seconds;
  final double speed;
  final double turbulence;

  /// 主要用于测试："同一档音色，换个循环长度"（短循环能让单测快很多，
  /// 而音色的对比结论不受长度影响）。
  RiverSoundSpec copyWith({double? seconds, double? speed, double? turbulence}) =>
      RiverSoundSpec(
        seconds: seconds ?? this.seconds,
        speed: speed ?? this.speed,
        turbulence: turbulence ?? this.turbulence,
      );
}

/// 把水动力参数翻译成 PCM 的合成器。
class RiverSoundSynth {
  RiverSoundSynth({this.sampleRate = 22050, int seed = 5150})
      : _rng = PcmRng(seed);

  /// 22.05kHz 够用：流水声的能量几乎全在 8kHz 以下，采样率再高只是把
  /// 循环缓冲白白放大一倍，而这段缓冲要在起播前一次性合成出来。
  /// （播放层用 44.1kHz 与引擎对齐，见 `engine.dart` 的说明。）
  final int sampleRate;

  final PcmRng _rng;

  double _alpha(double cutoffHz) => onePoleAlpha(cutoffHz, sampleRate);

  /// 合成一段无缝循环的流水声，样本范围 [-1, 1]。
  Float64List flowLoop(RiverSoundSpec spec) {
    final speed = spec.speed.clamp(0.0, 1.0);
    final turb = spec.turbulence.clamp(0.0, 1.0);

    // 三层粉噪声：低频给"体量"、中频给"存在感"、高频给"急"。
    final aLow = _alpha(170.0);
    final aMid = _alpha(760.0 + 420.0 * speed);
    final aHigh = _alpha(2800.0 + 3200.0 * turb);
    final aOut = _alpha(6800.0);

    // 频段配比：**持续的高频"沙沙"才是"水在流"的主角**，低频只给体量。
    final midGain = 0.44 + 0.26 * speed;
    final highGain = 0.16 + 0.58 * turb;
    final hissGain = 0.08 + 0.26 * turb;

    final f1 = loopLockedFreq(0.9 + 0.9 * speed, spec.seconds);
    final f2 = loopLockedFreq(2.3 + 1.7 * speed, spec.seconds);
    final p1 = _rng.unit() * math.pi * 2;
    final p2 = _rng.unit() * math.pi * 2;
    final m1 = 0.055 + 0.035 * speed;
    final m2 = 0.030;

    final out = seamlessLoop(
      seconds: spec.seconds,
      sampleRate: sampleRate,
      rng: _rng,
      peak: 0.92,
      generate: (buf, total, rng) {
        var lpLow = 0.0, lpMid = 0.0, lpHigh = 0.0, lpOut = 0.0;
        for (var i = 0; i < total; i++) {
          final t = i / sampleRate;
          final w = rng.white();

          lpLow += (w - lpLow) * aLow;
          lpMid += (w - lpMid) * aMid;
          lpHigh += (w - lpHigh) * aHigh;

          var s = lpLow * 1.0 + lpMid * midGain + lpHigh * highGain + w * hissGain;
          s *= 1.0 +
              m1 * math.sin(2.0 * math.pi * f1 * t + p1) +
              m2 * math.sin(2.0 * math.pi * f2 * t + p2);

          lpOut += (s - lpOut) * aOut;
          buf[i] = lpOut;
        }
        _addBubbles(buf, total, turb, rng);
      },
    );
    return out;
  }

  /// 短促的水花声（鱼跃出水面后落回）。**不是**循环音，播放一次就完。
  ///
  /// 实现已统一到 `synth/oneshot.dart` 的 [splashPcm]（它属于"一次性音效"
  /// 那一族，与水声循环不是一类东西）。这里保留这个方法只是为了不打断既有的
  /// 单测与调用方。
  Float64List splash({required double size, double seconds = 0.55}) =>
      splashPcm(size: size, sampleRate: sampleRate, seconds: seconds);

  /// 往缓冲里叠加气泡：泊松撒点 + 阻尼正弦。
  void _addBubbles(Float64List buf, int total, double turb, PcmRng rng) {
    final seconds = total / sampleRate;
    // 每秒多少个。细碎的"咕嘟"是活水的颗粒感来源 —— 稀疏的气泡会读成
    // "偶尔有东西掉进水里"，密一点才像水流自己发出来的。
    final density = 3.5 + 14.0 * turb;
    var at = 0.0;

    while (true) {
      // 指数分布的间隔 —— 泊松过程的正确取样方式（等间隔会听出节拍）。
      at += -math.log(1.0 - rng.unit() * 0.999999) / density;
      if (at >= seconds) break;

      final start = (at * sampleRate).round();
      final freq = 420.0 + rng.unit() * 1150.0;
      final amp = (0.05 + rng.unit() * 0.16) * (0.6 + 0.8 * turb);
      final tau = 0.016 + rng.unit() * 0.042;
      final omega = 2.0 * math.pi * freq;
      final last = math.min(total, start + (tau * 6.0 * sampleRate).round());

      for (var i = start; i < last; i++) {
        final t = (i - start) / sampleRate;
        buf[i] += math.sin(omega * t) * amp * math.exp(-t / tau);
      }
    }
  }

  /// 编码成 16-bit 单声道 PCM 的 WAV 字节。
  Uint8List toWav16(Float64List samples) =>
      encodeWav16(samples, sampleRate: sampleRate);
}

/// 播放参数：把"玩家在哪、那段河有多急"翻译成**音色档权重 + 3D 参数**。
///
/// ## 为什么是"音色档"而不是单一循环 + 变速率
///
/// 旧版只有一条按**全河平均**速度烘焙的循环，实时变化的只有播放速率。
/// 两个毛病：**速率变的是音高/节奏而不是音色**（而"湍急"的听觉本质是频谱
/// 变化），以及播放器的变速支持并不牢靠。现在沿"这条河有多急"这条轴预先烘焙
/// [bandCount] 条无缝循环，播放时取相邻两档等功率交叉淡化。
///
/// ## 为什么全是纯函数
///
/// 音效最难测的就是"到底该多响、音色对不对"，而这两件事完全不依赖音频库。
/// 抽成纯函数之后可以在单测里钉死：等功率淡化不会塌音量、档位对急缓单调、
/// 档与档之间真的换音色、速率范围不夸张。
class RiverSoundMix {
  const RiverSoundMix({
    required this.intensity,
    required this.bandA,
    required this.bandB,
    required this.weightA,
    required this.weightB,
    required this.playbackRate,
    required this.flowGain,
    required this.distance,
  });

  /// 音色档数量：5 档配合等功率交叉淡化，听感上是连续变化
  /// （相邻档之间的音色差被 50% 混合填满，不会听出"台阶"）。
  static const int bandCount = 5;

  /// 每条档的循环长度（秒）。
  ///
  /// 8 秒是"听不出重复"与"起播前合成不卡"之间的折中：
  /// `bandCount` 条都要烘焙好，总样本数 = 5 × 8 × 采样率。
  static const double bandSeconds = 8.0;

  /// "这条河有多急"的位置 0–1。0 = 深潭，1 = 急滩。
  final double intensity;

  /// 参与交叉淡化的相邻两档（[bandA] ≤ [bandB]）。
  final int bandA;
  final int bandB;

  /// 两档的**线性幅度**权重（不是功率）。等功率淡化意味着
  /// `weightA² + weightB² == 1` —— 这样两档淡化的中点响度不会塌。
  final double weightA;
  final double weightB;

  /// 播放速率：只做"节奏"的细调，范围刻意很窄。
  final double playbackRate;

  /// 该层的**层内**配平（0–1）。
  ///
  /// 注意它**不含**总线、距离与天气 —— 那些由 `mix.dart` 的
  /// `AmbienceMix` 统一决定。上一版把所有配平都塞在这一个常数里（0.85），
  /// 于是"离河远近""河急河缓"都影响不到它，听感恒定，像瀑布。
  final double flowGain;

  /// 玩家（角色）到声源的距离（米），仅用于诊断。
  final double distance;

  /// 速率下限/上限。旧版是 0.78–1.32，现在音色已经承担了主要表达，
  /// 速率再拉那么大只会让人听出"播放器在变速"。
  static const double _rateMin = 0.90;
  static const double _rateMax = 1.14;

  /// [flowGain] 的层内基准。距离/急缓/总线在别处相乘。
  static const double baseFlowGain = 0.55;

  /// 第 [i] 档的合成参数（u = i / (bandCount - 1)）。
  ///
  /// 两个轴不取同一条曲线是刻意的：
  ///   * `speed` 控制中频与起伏的快慢 → 用 `u^0.85` 起步就有点"水在动"；
  ///   * `turbulence` 控制高频白水与气泡密度 → 用 `u^0.9`，
  ///     让高档明显更"嘶"，而低档几乎是干净的水声（没有白花花的噪声）。
  static RiverSoundSpec bandSpec(int i) {
    final u = (i / (bandCount - 1)).clamp(0.0, 1.0);
    return RiverSoundSpec(
      seconds: bandSeconds,
      speed: 0.30 + 0.70 * math.pow(u, 0.85).toDouble(),
      turbulence: math.pow(u, 0.90).toDouble(),
    );
  }

  /// 把"流速 + 湍流"折成一个 0–1 的"有多急"。
  ///
  /// 湍流权重更高（0.6）：听感上"急"主要来自白水的嘶声，
  /// 而不是低频体量的涨落。速度用**全河平均**做归一化，
  /// 于是这条河自己的快慢分布就落进 0–1，换一张地图不用重调。
  static double intensityFor({
    required double sectionSpeed,
    required double meanSpeed,
    required double sectionTurbulence,
  }) {
    final speedNorm =
        (sectionSpeed / math.max(meanSpeed, 0.05)).clamp(0.0, 2.0) / 2.0;
    final turb = sectionTurbulence.clamp(0.0, 1.0);
    return (0.40 * speedNorm + 0.60 * turb).clamp(0.0, 1.0);
  }

  /// 评估播放参数。
  ///
  /// [distanceToRiver] 角色到河道中心线的垂直距离（米），仅用于诊断；
  /// [sectionSpeed] 声源处的断面平均流速；
  /// [meanSpeed] 全河平均流速（归一化基准）；
  /// [sectionTurbulence] 声源处的湍流强度 0–1。
  static RiverSoundMix evaluate({
    required double distanceToRiver,
    required double sectionSpeed,
    required double meanSpeed,
    required double sectionTurbulence,
  }) {
    final u = intensityFor(
      sectionSpeed: sectionSpeed,
      meanSpeed: meanSpeed,
      sectionTurbulence: sectionTurbulence,
    );

    // 把 0–1 映射到"档空间"并取相邻两档的等功率权重（与雨/风/夜共用同一份
    // 实现，见 `recipe.dart` 的 `bandBlend` —— 等功率意味着淡化过程中响度是平的）。
    final blend = bandBlend(u, bandCount);

    final speedNorm =
        (sectionSpeed / math.max(meanSpeed, 0.05)).clamp(0.0, 2.0) / 2.0;

    return RiverSoundMix(
      intensity: u,
      bandA: blend.a,
      bandB: blend.b,
      weightA: blend.wa,
      weightB: blend.wb,
      playbackRate: _rateMin + (_rateMax - _rateMin) * speedNorm,
      flowGain: baseFlowGain,
      distance: math.max(distanceToRiver, 0.0),
    );
  }
}

/// 河流作为一层环境音的配方：5 档音色，强度 = "那段水有多急"。
class RiverAmbienceRecipe implements AmbienceRecipe {
  const RiverAmbienceRecipe();

  @override
  String get id => 'river';

  @override
  int get variantCount => RiverSoundMix.bandCount;

  @override
  double get seconds => RiverSoundMix.bandSeconds;

  @override
  Float64List bake(int i, int sampleRate, int seed) {
    final synth = RiverSoundSynth(sampleRate: sampleRate, seed: seed + i * 7717);
    return synth.flowLoop(RiverSoundMix.bandSpec(i));
  }

  @override
  BandBlend blend(double strength) => bandBlend(strength, variantCount);
}
