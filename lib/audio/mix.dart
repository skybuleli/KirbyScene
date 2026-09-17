/// 音频的**总线**与**混音决策**：这一层全是纯函数/纯状态机，不碰音频设备。
///
/// 拆成两件事：
///
///   1. [BusMix] —— 总线电平。声音按用途分成若干**总线**（环境 / 音效 / UI），
///      每条有独立的音量与平滑时间常数，最后乘到 master 上。SoLoud 没有总线
///      概念，所以总线是**在 Dart 侧做乘法**实现的；这样做的好处是它可单测、
///      可随时读回，也不必为每条总线各开一个引擎实例。
///   2. [AmbienceMix] —— "当前场景该听到什么"。给定天气与场景快照，算出每个
///      环境音层的目标音量。**这是"雨声不会在晴天响"的唯一判据来源**：
///      一层的起播/停播由它的目标音量是否为 0 决定，而不是由散落各处的
///      `if (weather == rain)` 决定 —— 后者正是这类 bug（音效在错误状态被播放）
///      的温床。
///
/// ## 为什么用"目标音量"而不是直接的"启停开关"
///
/// 需求要的是"各自可单独控制音量、启停与淡入淡出，互不干扰又能自然融合"。
/// 把它统一成**一个连续的标量目标**之后，三件事变成同一件事：
///
///   * 启停 = 目标从 0 变正 / 从正变 0；
///   * 淡入淡出 = 逼近这个目标时用的时间常数（见 [LayerLevel]）；
///   * 音量 = 目标本身。
///
/// 于是天气过渡期间雨由小变大，雨声是**连续跟上**的（目标按 `rainAmount`
/// 插值），而不是在过渡结束的那一帧突然切进来。
library;
import 'dart:math' as math;

/// 声音的用途分类。每一条是一个独立的**总线**。
///
/// 分类的依据是"谁会想要单独调它"，而不是"声音长什么样"：
/// 玩家会想调低环境音但保留拾取的反馈音，所以环境与音效必须分开。
enum AudioBus {
  /// 环境音（河流 / 雨 / 风 / 夜）。长时间连续播放，通常要压得比音效低。
  ambience('环境音', 0.60),

  /// 玩法音效（脚步 / 水花 / 落地 / 拾取）。需要清晰、不能被环境音盖住。
  sfx('音效', 0.90),

  /// 界面音效（切天气 / 重开 / 提示）。比玩法音效更靠前一点点，但更干。
  ui('界面', 0.75);

  const AudioBus(this.label, this.defaultGain);

  final String label;

  /// 该总线的默认音量。数值来自"混音阶梯"：
  ///
  ///   * 环境音 0.60 —— 它是**底盘**，不该抢戏。上一版把河流当唯一声源、
  ///     以 0.85 直接下发，加上每秒约 3 声水花，整体听感就是"站在瀑布旁"；
  ///   * 音效 0.90 —— 反馈音要让玩家听清（采集、落地）；
  ///   * 界面 0.75 —— 界面音比玩法音更"干"、更轻。
  final double defaultGain;
}

/// 一个可以连续包络的音量（总线 / 层 / 单个声源都用它）。
///
/// 用法固定为"每帧 [to] 一次目标值，然后读 [value]"。**所有音量变化都必须经过
/// 它** —— 直接把新音量赋给声源会在波形上留下台阶，听感上就是"咔"的一声，
/// 这正是需求里"不能有突兀的切入切出"要防的东西。
class LayerLevel {
  LayerLevel({
    required this.fadeSeconds,
    this.value = 0.0,
    this.tauOverride,
  });

  /// 淡变时长（秒）。0 → 立即到位（只用于彻底静音的收尾）。
  final double fadeSeconds;

  /// 显式时间常数（秒）。给"平滑"（不是"淡变"）场景用，比如流速驱动的响度。
  final double? tauOverride;

  /// 当前值。
  double value;

  double get tau => tauOverride ?? math.max(fadeSeconds / 3.0, 1e-4);

  /// 朝 [target] 逼近一步。
  void to(double target, double dt) {
    if (fadeSeconds <= 0 && tauOverride == null) {
      value = target;
      return;
    }
    final k = 1.0 - math.exp(-dt / tau);
    value += (target - value) * k;
    // **收尾吸附**：指数逼近永远不会"到"0，只会无限靠近。
    //
    // 这一行不是优化，是正确性：调用方唯一的启停判据是"目标音量是不是 0"
    // （见 `ambience.dart` 里释放声部的条件）。没有它，一层淡出到 0.0004
    // 之后就永远停在"目标 0.0004"上 —— 声部永不释放、引擎侧音量永不归零，
    // 于是**晴天也挂着一层几乎听不见但确实在响的雨**、诊断里 `playing` 永远
    // 是 true。实测就是这么被卡住的。
    if (target == 0 && value < _snapToZero) value = 0;
  }

  /// 目标为 0 时的落地下限。取 1e-3（约为满量程的 -60dB）：听感上早已是静音，
  /// 但足以让"到底停没停"变成一个**可判定**的问题。
  static const double _snapToZero = 1e-3;

  /// 是否已经完全静音（可以用来决定"到底要不要启播"）。
  bool get isSilent => value < 1e-4;

  /// 是否已经到位（诊断用）。
  bool settled(double target, {double eps = 1e-3}) => (value - target).abs() < eps;
}

/// 整个混音台的电平状态。
///
/// 三层相乘，缺一不可：
///   `最终音量 = master × 总线音量 × 层音量（单声源再乘自己的包络）`
///
/// 分开的理由是它们变化的**时间尺度完全不同**：master 几乎不变、总线是设置项、
/// 层音量每帧都在跟天气/流速走。混在一个数里就没法在诊断里看出"是整体被调小了
/// 还是这一层被压掉了"。
class BusMix {
  BusMix({
    double master = 0.90,
    Map<AudioBus, double>? overrides,
    double fadeSeconds = 0.9,
  })  : _master = LayerLevel(fadeSeconds: fadeSeconds, value: master),
        _buses = {
          for (final b in AudioBus.values)
            b: LayerLevel(
              fadeSeconds: fadeSeconds,
              value: overrides?[b] ?? b.defaultGain,
            ),
        };

  final LayerLevel _master;
  final Map<AudioBus, LayerLevel> _buses;

  double get master => _master.value;

  /// 直接设置 master（会走淡变）。
  void setMaster(double v) => _masterTarget = v;
  double? _masterTarget;
  double get masterTarget => _masterTarget ?? _master.value;

  /// 设置某条总线的音量（会走淡变）。
  void setGain(AudioBus bus, double v) => _targets[bus] = v;
  final Map<AudioBus, double> _targets = {};

  double gainOf(AudioBus bus) => _buses[bus]!.value;
  double targetOf(AudioBus bus) => _targets[bus] ?? _buses[bus]!.value;

  /// 某条总线的最终系数（master × 总线）。
  double coefficient(AudioBus bus) => _master.value * _buses[bus]!.value;

  void update(double dt) {
    final mt = _masterTarget;
    if (mt != null) _master.to(mt, dt);
    for (final e in _buses.entries) {
      e.value.to(_targets[e.key] ?? e.value.value, dt);
    }
  }

  Map<String, Object?> diagnostics() => {
        'master': double.parse(_master.value.toStringAsFixed(3)),
        for (final b in AudioBus.values)
          b.name: {
            'now': double.parse(gainOf(b).toStringAsFixed(3)),
            'target': double.parse(targetOf(b).toStringAsFixed(3)),
          },
      };
}

/// 环境音的**层**。每层是一条（或一组）独立循环声源，有自己的一整套
/// 音量 / 启停 / 淡变，互不干扰。
enum AmbienceLayer {
  /// 河水（3D 声源，跟着河道中心线上离角色最近的点）。
  river('河'),

  /// 雨（跟随相机的全场音）。
  rain('雨'),

  /// 风（跟随相机的全场音）。
  wind('风'),

  /// 夜（虫鸣，只在夜色里出现）。
  night('夜');

  const AmbienceLayer(this.label);

  final String label;
}

/// 一帧的"场景快照"：环境音分层决策的**唯一输入**。
///
/// 刻意做成一个不可变值对象而不是让 [AmbienceMix] 去读 `SkySystem` /
/// `RiverFlow`：这样"什么天气该听到什么"可以在单测里枚举全部组合来断言，
/// 不必先造一个世界出来。上一版把天气判断散在播放层里，于是"晴天响雨声"
/// 这类错误没有地方可以被断言住。
class AmbienceState {
  const AmbienceState({
    required this.rainAmount,
    required this.windAmount,
    required this.nightAmount,
    required this.riverIntensity,
    required this.riverDistance,
  });

  /// 雨势 0–1（来自天气档案的 `rainAmount`，**过渡期间是插值中的值**）。
  /// 只有它大于 0 雨层才有音量 —— 这就是"没切到雨天就不该有雨声"的落点。
  final double rainAmount;

  /// 风/草摆强度 0–1。
  final double windAmount;

  /// 夜色 0–1。
  final double nightAmount;

  /// 河有多急 0–1（与画面波纹推进同源）。
  final double riverIntensity;

  /// 角色到河道中心线最近点的距离（米）。
  final double riverDistance;

  static const AmbienceState silent = AmbienceState(
    rainAmount: 0,
    windAmount: 0,
    nightAmount: 0,
    riverIntensity: 0,
    riverDistance: 999,
  );
}

/// 把 [AmbienceState] 翻译成每层的目标音量。**全部是纯函数**。
///
/// ## 混音阶梯（为什么是这些数）
///
/// 上一版的问题是"河流 + 每秒约 3 声水花"构成全部听感，而河流被以一个恒定
/// 0.85 的音量下发 —— 无论那条河是急滩还是深潭、无论角色离河 3m 还是 40m。
/// 于是**平缓的河段也像瀑布**。现在改成四个因子相乘：
///
///   `层音量 = 基准 × 强度因子 × 距离因子 × 掩蔽因子`
///
///   * **强度因子**：深潭听上去就该比急滩轻得多（[calmFloor] 是"平缓时还剩
///     多少"）。这是"与实际平缓的水流状态相符"的直接落点。
///   * **距离因子**：显式的反比距离曲线（[distanceGain]），**替代**引擎的 3D
///     衰减（见 `engine.dart` 里把衰减模型设为 NO_ATTENUATION 的原因：两处
///     同时衰减会把"离河多远"算成平方，河边反而听不见）。
///   * **掩蔽因子**：真实的声景里在下大雨时风声会被雨声掩掉、虫鸣会停
///     （[masking]）。这一条是"自然融合"而不是"各响各的"。
abstract final class AmbienceMix {
  /// 平缓河段的音量下限（占急滩的比例）。
  ///
  /// 0.26 而不是 0：一眼泉水也还是有声音的；但也不能高，否则"流速感"就没了。
  /// 公开是为了可断言（"深潭必须比急滩轻得多"是一条需求）。
  static const double calmFloor = 0.26;

  /// 各层的基准音量（**已包含"它相对别的层多重要"的判断**）。
  ///
  /// 这些数是"混音"，不是"物理量"：河水是底盘所以最高但仍有上限，雨比风
  /// 更有存在感，虫鸣只是点缀。
  static const Map<AmbienceLayer, double> baseGain = {
    AmbienceLayer.river: 0.42,
    AmbienceLayer.rain: 0.50,
    AmbienceLayer.wind: 0.34,
    AmbienceLayer.night: 0.22,
  };

  /// 距离曲线的半衰尺度（米）：距离等于它时降到一半。
  static const double _distanceHalfAt = 12.0;

  /// 距离曲线的陡度。1.3 略陡于 1/r：草原尺度比真实河流小，
  /// 用物理值会让"站在场地中央"仍然清清楚楚地听见河。
  static const double _distancePower = 1.3;

  /// 反比距离增益 0–1。0 距离为 1，随距离单调下降到趋近 0。
  ///
  /// 刻意**没有**"近场平台"（上一版 `minDistance = 5m` 让 5m 以内全量输出，
  /// 于是走到岸边音量就到顶了）。这里是连续的，走到水边只是更响一点。
  static double distanceGain(double meters) {
    final d = math.max(meters, 0.0) / _distanceHalfAt;
    return 1.0 / (1.0 + math.pow(d, _distancePower).toDouble());
  }

  /// 掩蔽关系：某层的实际容不容易被别层盖住。
  ///
  /// 返回每层的掩蔽乘子 0–1。
  static Map<AmbienceLayer, double> masking(AmbienceState s) {
    final rain = s.rainAmount.clamp(0.0, 1.0);
    final night = s.nightAmount.clamp(0.0, 1.0);
    return {
      // 雨声把风声掩掉一大半：真实的下雨天几乎听不到风。
      AmbienceLayer.wind: 1.0 - 0.70 * rain,
      // 大雨里虫子不叫（真的不叫，不是懒得做）。
      AmbienceLayer.night: (1.0 - 0.95 * rain),
      // 夜里整体更安静，河显得更突出一点点，但不上调（夜里没有白天的
      // 风声掩盖，本来就已经更突出）。
      AmbienceLayer.river: 1.0 - 0.10 * night,
      AmbienceLayer.rain: 1.0,
    };
  }

  /// 单层的目标音量 0–1（**不含总线系数**；总线在 [BusMix] 里乘）。
  ///
  /// 河用角色到河的距离，雨/风/夜是全场音所以距离因子恒为 1。
  static double targetGain(AmbienceLayer layer, AmbienceState s) {
    final base = baseGain[layer] ?? 0.0;
    final mask = masking(s)[layer] ?? 1.0;
    switch (layer) {
      case AmbienceLayer.river:
        final intensity = s.riverIntensity.clamp(0.0, 1.0);
        final level = calmFloor + (1.0 - calmFloor) * intensity;
        return base * level * distanceGain(s.riverDistance) * mask;
      case AmbienceLayer.rain:
        // ^0.75：小雨也要听得出来（听觉上雨势的感知本来就不线性）。
        final amount = math.pow(s.rainAmount.clamp(0.0, 1.0), 0.75).toDouble();
        return base * amount * mask;
      case AmbienceLayer.wind:
        // 无风时仍然留一点底噪：完全静音会让场景"死掉"。
        final w = 0.18 + 0.82 * s.windAmount.clamp(0.0, 1.0);
        return base * w * mask;
      case AmbienceLayer.night:
        return base * s.nightAmount.clamp(0.0, 1.0) * mask;
    }
  }

  /// 全部层的目标音量。
  static Map<AmbienceLayer, double> all(AmbienceState s) => {
        for (final l in AmbienceLayer.values) l: targetGain(l, s),
      };

  /// 该层当前是否应当出声（目标音量是否非零）。
  ///
  /// 启停判据只有这一处。它同时回答了需求里"避免非当前状态的音效被误播放"：
  /// 晴天时 `rainAmount == 0` → 雨层目标恒为 0 → **永不启播**。
  static bool shouldPlay(AmbienceLayer layer, AmbienceState s) =>
      targetGain(layer, s) > 1e-4;
}
