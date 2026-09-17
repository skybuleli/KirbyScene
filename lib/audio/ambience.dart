/// 一层环境音的**播放器**：N 条无缝循环 + 等功率交叉淡化 + 独立音量/启停/淡入淡出。
///
/// ## "分层独立"具体独立在哪
///
/// 四层（河 / 雨 / 风 / 夜）各自持有一份完整的播放状态：自己的声部句柄、自己的
/// 音量包络（[LayerLevel]）、自己的启停开关、自己的平滑时间常数。层与层之间
/// **没有任何共享的可变状态** —— 关掉雨不会碰到风的音量，这是"互不干扰"的字面
/// 含义。它们唯一的共同输入是每帧的 [AmbienceState]（天气 + 场景），
/// 而"该怎么融合"（掩蔽关系）集中在 `mix.dart` 里，写成可单测的纯函数。
///
/// ## 声部预算：只在需要时才起播
///
/// 一条 5 档的河如果像上一版那样**五条循环一起常驻播放**，就白占了 5 个声部
/// （引擎默认上限 16，水花一密就开始互相挤掉）。这里只在**当前参与交叉淡化的
/// 那一两档**上保留声部：档位变化时新档从 0 音量起播再淡入，旧档淡到静音后
/// 释放。于是每秒都在变的音色不会造成"咔"，而声部占用降到原来的 1/3。
///
/// ## 为什么音量变化一定要走包络
///
/// 直接把新音量 `setVolume` 给声源，会在波形上留下台阶 —— 听感上就是"咔"的
/// 一声。需求里"无卡顿、断裂或突兀的切入切出"要防的正是它。所以这一层只有
/// 一条写音量的路径：[LayerLevel.to] 每帧逼近目标，再把结果通过 `fadeVolume`
/// 下发（短淡变，让 30fps 的更新之间被引擎插值）。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'engine.dart';
import 'mix.dart';
import 'recipe.dart';

/// 一层环境音的运行时。
class AmbienceLayerPlayer {
  AmbienceLayerPlayer({
    required this.layer,
    required this.recipe,
    required this.engine,
    required this.is3d,
    double fadeSeconds = 1.4,
    double blendSeconds = 0.35,
  }) : level = LayerLevel(fadeSeconds: fadeSeconds),
       _strength = LayerLevel(fadeSeconds: 0, tauOverride: blendSeconds);

  /// 它代表哪一层（`mix.dart` 的 [AmbienceLayer]）。
  final AmbienceLayer layer;

  /// 烘焙配方（几条循环、怎么烘）。
  final AmbienceRecipe recipe;

  final AudioEngine engine;

  /// 是否 3D 声源（河）。雨/风/夜是全场音，居中播放。
  final bool is3d;

  /// 层音量包络 0–1（**不含总线系数**）。
  final LayerLevel level;

  final LayerLevel _strength;

  /// 手动停止（与"目标音量为 0"是两回事：这个是外部强制，比如静音整层）。
  bool muted = false;

  /// 每条变体当前的声部（null = 没在播）。
  final List<SoundHandle?> _handles = [];

  /// 每条变体上一次下发的音量（"变了才发"判据）。
  final List<double> _applied = [];

  final List<AudioSource> _sources = [];

  bool _prepared = false;
  Future<void>? _preparing;

  /// 当前参与交叉淡化的两档（诊断/测试用）。
  BandBlend blend = const BandBlend(0, 0, 1, 0, 0);

  /// 3D 声源位置（河用）。
  final vm.Vector3 sourcePoint = vm.Vector3.zero();

  int startedVoices = 0;

  /// 层是否在出声（有任何一个声部在播）。
  bool get isPlaying => _handles.any((h) => h != null);

  /// 当前在播的变体数（诊断：验证声部预算真的生效）。
  int get activeVariants => _handles.where((h) => h != null).length;

  bool get isPrepared => _prepared;

  /// 已装载的变体数。
  int get loadedVariants => _sources.length;

  /// 在播的声部句柄（管理侧需要统一下发播放速率等参数）。
  Iterable<SoundHandle> get handles => _handles.whereType<SoundHandle>();

  /// 按变体顺序装配。同一配方重复调用幂等，并发调用共用一次装配。
  /// 更换资源须先 release；不能清掉仍在播放的句柄，否则旧循环声会失去追踪。
  Future<void> prepare(List<Uint8List> wavs) {
    if (_prepared) return Future<void>.value();
    return _preparing ??= _prepare(wavs).whenComplete(() {
      _preparing = null;
    });
  }

  Future<void> _prepare(List<Uint8List> wavs) async {
    if (wavs.length < recipe.variantCount) return;
    // 完整装好后一次发布，失败不留下错位的变体或可播放的半成品。
    final sources = <AudioSource>[];
    for (var i = 0; i < recipe.variantCount; i++) {
      final src = await engine.load(ambienceAsset(recipe.id, i), wavs[i]);
      if (src == null) return;
      sources.add(src);
    }
    _sources.addAll(sources);
    _handles.addAll(List<SoundHandle?>.filled(sources.length, null));
    _applied.addAll(List<double>.filled(sources.length, 0));
    _prepared = true;
  }

  /// 把 [targetGain]（来自 `AmbienceMix`）与 [strength]（决定音色档）走一步。
  ///
  /// [busCoefficient] 是 master × 总线（`BusMix.coefficient`）；[sourcePos] /
  /// [listener] 只在 3D 层用。
  void update(
    double dt, {
    required double targetGain,
    required double strength,
    required double busCoefficient,
    vm.Vector3? sourcePos,
  }) {
    final effectiveTarget = muted ? 0.0 : targetGain.clamp(0.0, 1.0);
    level.to(effectiveTarget, dt);
    _strength.to(strength.clamp(0.0, 1.0), dt);

    if (_prepared) {
      blend = recipe.blend(_strength.value);
      for (var i = 0; i < _sources.length; i++) {
        final weight = i == blend.a
            ? blend.wa
            : i == blend.b
            ? blend.wb
            : 0.0;
        final target = busCoefficient * level.value * weight;

        // 起播：只在真正需要出声的档上占声部。
        final needsVoice = level.value > 1e-3 && weight > 1e-3;
        if (needsVoice && _handles[i] == null) {
          _startVariant(i);
        }

        final h = _handles[i];
        if (h == null) continue;

        // 变了才发：`fadeVolume` 每次调用都会重开一个淡变，每帧无脑调用
        // 等于永远淡不完，而且会一直抢引擎锁（见 `engine.dart` 的选型注释：
        // 每多一次 FFI，就多一次跟混音线程抢全局音频锁的机会）。
        //
        // 判据必须是**相对**的。曾经用的是绝对阈值 `> 0.004`：淡出收尾时
        // 目标已经是 0 而 `_applied` 停在 0.004 上，差值正好不再大于阈值
        // —— 于是**最后那一次"归零"永远发不出去**，引擎侧的音量就永远
        // 停在 0.004、声部永远不释放。现在：要么相对变化够大，要么
        // 精确归零（收尾必须落地）。
        if (shouldSend(target, _applied[i])) {
          _applied[i] = target;
          engine.fadeVolume(h, target, _fadeStep);
        }

        // 3D 声源位置也只在**真的动了**才下发。静态机位下这是每帧一次的
        // FFI 调用，省掉它等于省掉每帧一次抢锁。
        if (is3d && sourcePos != null && _sourceMoved(sourcePos)) {
          _lastSource.setFrom(sourcePos);
          _hasLastSource = true;
          engine.move3d(h, sourcePos.x, sourcePos.y, sourcePos.z);
        }

        // 释放：音量已经**落地到 0** 时归还声部。
        if (shouldRelease(target: target, applied: _applied[i])) {
          _releaseVariant(i);
        }
      }
    }
  }

  /// 每帧下发音量时用的短淡变：让 30fps 的更新之间被引擎插值掉（防 zipper 噪声）。
  static const Duration _fadeStep = Duration(milliseconds: 120);

  /// 该不该归还声部（纯函数，可单测）。
  ///
  /// # 曾经错在哪
  ///
  /// 上一版的判据是 `!active.contains(i) && target == 0 && applied == 0`，
  /// 那个 `!active.contains(i)` 是致命的：`active` 是当前交叉淡化的**两**档，
  /// 而雨/风/夜这些层只有**两**档（`variantCount == 2`）—— 于是 `active` 恒等于
  /// `{0, 1}`，“不在交叉淡化里”**永远为假**，声部永远不归还。
  /// 表现：切回晴天后雨层仍然 `playing=true`（虽然已经听不见，`applied=0`）。
  /// 只有 5 档的河会真正释放它不用的那 3 档 —— 所以之前只有雨/风/夜漏。
  ///
  /// 现在判据只剩“音量真的到 0 了”：起播的门槛（`level > 1e-3 && weight > 1e-3`）
  /// 已经提供了滞回，不会起停抖动。
  static bool shouldRelease({
    required double target,
    required double applied,
  }) => target == 0 && applied == 0;

  /// 该不该把 [next] 下发给引擎。[prev] 是上一次真正发出的值。
  ///
  /// 公开（而不是 private）就是为了能被单测钉住 —— 这条判据曾经错过一次
  /// （绝对阈值让"归零"永远发不出去，于是晴天的雨层永远停在 0.004、
  /// 声部永不释放），这种错误不能再靠"改一版听一遍"。
  static bool shouldSend(double next, double prev) {
    // 归零是**收尾**，必须精确落地：只要还没发过 0，就一定要发一次。
    if (next <= 0) return prev != 0;
    // 否则按相对变化判。绝对阈值在低音量段太粗、在高音量段太细。
    return (next - prev).abs() > math.max(1e-4, next * 0.03);
  }

  /// 3D 声源的"动了没有"判据（1cm）。
  final vm.Vector3 _lastSource = vm.Vector3.zero();
  bool _hasLastSource = false;

  bool _sourceMoved(vm.Vector3 p) {
    if (!_hasLastSource) return true;
    final dx = p.x - _lastSource.x;
    final dy = p.y - _lastSource.y;
    final dz = p.z - _lastSource.z;
    return dx * dx + dy * dy + dz * dz > 1e-4;
  }

  void _startVariant(int i) {
    final src = _sources[i];
    SoundHandle? h;
    if (is3d) {
      h = engine.playLoop3d(src, sourcePoint.x, sourcePoint.y, sourcePoint.z);
    } else {
      h = engine.playLoop2d(src);
    }
    _handles[i] = h;
    _applied[i] = 0;
    // 新声部必须收到一次位置，否则它会停在原点（3D 声源默认在同一点）。
    _hasLastSource = false;
    if (h != null) startedVoices++;
  }

  void _releaseVariant(int i) {
    final h = _handles[i];
    if (h == null) return;
    _handles[i] = null;
    _applied[i] = 0;
    // stop 是异步的，但这里不需要等它：句柄已经不再被引用，
    // 引擎会在淡变结束后自己回收声部。
    engine.stop(h);
  }

  /// 强制静音（不停止引擎声部，让包络自己淡下去）。
  void setMuted(bool value) => muted = value;

  /// 整层立即拆除（热重启/资源回收）。
  Future<void> release() async {
    // 防止异步装配在释放之后重新发布资源。
    try {
      await _preparing;
    } finally {
      _prepared = false;
    }
    for (var i = 0; i < _handles.length; i++) {
      final h = _handles[i];
      if (h != null) {
        _handles[i] = null;
        _applied[i] = 0;
        await engine.stop(h);
      }
    }
    _sources.clear();
    _handles.clear();
    _applied.clear();
  }

  Map<String, Object?> diagnostics() => {
    'prepared': _prepared,
    'loaded': loadedVariants,
    'variants': recipe.variantCount,
    'playing': isPlaying,
    'muted': muted,
    'activeVariants': activeVariants,
    // 层音量包络的当前值，以及**已下发给引擎的最大单声部音量**。
    // 后者是"这层真的没在出声"的硬证据：`targets` 是意图，这个才是事实
    // （前面还有总线乘法与淡变）。
    'level': double.parse(level.value.toStringAsFixed(4)),
    'applied': double.parse(
      (_applied.isEmpty ? 0.0 : _applied.reduce(math.max)).toStringAsFixed(4),
    ),
    if (is3d)
      'source': [
        double.parse(sourcePoint.x.toStringAsFixed(2)),
        double.parse(sourcePoint.y.toStringAsFixed(2)),
        double.parse(sourcePoint.z.toStringAsFixed(2)),
      ],
    'weight': [
      double.parse(blend.wa.toStringAsFixed(3)),
      double.parse(blend.wb.toStringAsFixed(3)),
    ],
    'band': [blend.a, blend.b],
  };
}
