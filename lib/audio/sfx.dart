/// **一次性音效**的播放器：脚步 / 跳跃 / 落地 / 采集 / 界面 / 过关 / 水花。
///
/// ## 这一层真正要解决的问题不是"怎么放"，而是"该不该放"
///
/// 上一版的水花是**每来一个事件就播一声**，而鱼群里有 36 条鱼、每条 9–26 秒就
/// 自发跃出一次 —— 于是平均每秒约 **3 声**水花（实测 154.8s 内 457 声）。
/// 每一声都是 0.55 秒的宽带噪声爆发，叠加起来就是持续不断的"滴滴答答"。
/// 玩家把它听成了雨声，而当时天气是晴天。这是本项目"非当前状态的音效被误播放"
/// 那条需求的实际来源。
///
/// 所以这一层的核心是**三重闸门**，全部在这里（而不是散在各个调用点）：
///
///   1. **每类事件的最小间隔**（[minInterval]）：无论上游多密集，同一类音效
///      每秒最多出现几次。这是防"事件刷屏把耳朵打爆"的最后一道；
///   2. **距离上限**（[maxDistance]）：超出就整声丢弃。几十米外的鱼跃出水面对
///      玩家是听不见的，为它占一个声部、并在近场叠加出底噪，是纯粹的负收益；
///   3. **距离衰减**（[distanceGain]）：与画面一致的远近感，近处清晰、远处轻。
///
/// 被闸门丢掉的次数都记在 [dropped] 里 —— "为什么听不到"这个问题必须能被回答，
/// 而不是靠猜。
library;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'baker.dart';
import 'engine.dart';
import 'pcm.dart';

/// 一次闸门判定的结论。
class SfxAdmission {
  const SfxAdmission(this.allowed, this.reason, this.gain);

  final bool allowed;

  /// `ok` / `notLoaded` / `tooFar` / `tooSoon` / `tooQuiet`。
  final String reason;

  /// 允许播放时的最终增益。
  final double gain;

  @override
  String toString() => 'SfxAdmission($reason${allowed ? ' g=${gain.toStringAsFixed(3)}' : ''})';
}

/// 一次性音效播放器。
class SfxPlayer {
  SfxPlayer({required this.engine});

  final AudioEngine engine;

  final Map<SfxId, List<AudioSource>> _sources = {};
  final Map<SfxId, int> _cursor = {};
  final Map<SfxId, double> _lastPlayedAt = {};
  double _clock = 0;

  final PcmRng _rng = PcmRng(24680);

  /// 一声都没播出去的次数（被闸门拦下），按 id 分类。诊断用。
  final Map<SfxId, int> dropped = {};

  /// 实际播出的声音数，按 id 分类。
  final Map<SfxId, int> played = {};

  /// 同类音效的最小间隔（秒）。**这是修掉"晴天响雨声"的关键之一**。
  ///
  /// 水花 1.2s（带上抖动后实际约每 1–2 秒一声）：鱼跃是**点缀**，不是底噪。
  /// 上一版没有间隔闸门，实测 154.8 秒里响了 457 声（2.95 声/秒）——
  /// 每声都是 0.55 秒的宽带噪声爆发，叠起来就是持续不断的"滴滴答答"，
  /// 玩家把它听成了雨声，而当时天气是晴天。
  static const Map<SfxId, double> minInterval = {
    SfxId.splash: 1.2,
    SfxId.stepGrass: 0.16,
    SfxId.stepSoil: 0.16,
    SfxId.stepWater: 0.20,
    SfxId.jump: 0.25,
    SfxId.land: 0.12,
    SfxId.pickup: 0.05,
    SfxId.ui: 0.08,
    SfxId.fanfare: 1.0,
  };

  /// 间隔上的随机抖动比例。
  ///
  /// **等间隔本身就是"滴水"的听感特征**（水龙头、雨檐都是规则的节拍）。
  /// 真正的池糖里每一声跃出都是独立事件。所以闸门不是"每 1.2 秒放行一次"，
  /// 而是"每次放行后隔 1.2×(0.65..1.35) 秒才允许下一声"。
  double _gapFor(SfxId id) => (minInterval[id] ?? 0.0) * (0.65 + 0.7 * _rng.unit());

  /// 声源的最大可闻距离（米），超出整声丢弃。null = 不设上限（原位声）。
  static const Map<SfxId, double?> maxDistance = {
    SfxId.splash: 48.0,
    SfxId.stepGrass: null,
    SfxId.stepSoil: null,
    SfxId.stepWater: null,
    SfxId.jump: null,
    SfxId.land: null,
    SfxId.pickup: null,
    SfxId.ui: null,
    SfxId.fanfare: null,
  };

  /// 距离衰减的半衰尺度（米）：距离等于它时降到一半。
  static const double _halfAt = 16.0;
  static const double _power = 1.2;

  /// 距离增益 0–1。
  static double distanceGain(double meters) {
    final d = math.max(meters, 0.0) / _halfAt;
    return 1.0 / (1.0 + math.pow(d, _power).toDouble());
  }

  bool isPrepared(SfxId id) => (_sources[id]?.isNotEmpty ?? false);

  /// 装载某个音效的全部变体。
  Future<void> prepare(SfxId id, List<Uint8List> wavs) async {
    final list = <AudioSource>[];
    for (var i = 0; i < wavs.length; i++) {
      final src = await engine.load(id.variantName(i), wavs[i]);
      if (src != null) list.add(src);
    }
    _sources[id] = list;
    _cursor.putIfAbsent(id, () => 0);
  }

  /// 播放一声。[at] 是**世界坐标**（null = 原位声，如 UI 音）。
  ///
  /// [distance] 由调用方给出（世界层知道角色在哪）—— 放在这里算会让本层
  /// 依赖听者状态，而听者状态属于 `manager.dart`。
  void play(
    SfxId id, {
    double gain = 1.0,
    vm.Vector3? at,
    double speed = 1.0,
    double pan = 0.0,
    double distance = 0.0,
  }) {
    final list = _sources[id];
    final last = _lastPlayedAt[id];
    final verdict = admit(
      id: id,
      loaded: list != null && list.isNotEmpty,
      distance: distance,
      gain: gain,
      positional: at != null,
      sinceLast: last == null ? null : _clock - last,
      gap: _nextGap[id] ?? minInterval[id] ?? 0.0,
    );
    if (!verdict.allowed) {
      _bump(dropped, id);
      return;
    }

    _lastPlayedAt[id] = _clock;
    _nextGap[id] = _gapFor(id);

    // 变体轮换：连续几步播同一段波形会立刻被听出"在重复"。
    final srcs = list!;
    final idx = (_cursor[id] ?? 0) % srcs.length;
    _cursor[id] = idx + 1;
    final src = srcs[idx];

    if (at != null) {
      engine.playOneShot3d(src, at.x, at.y, at.z, volume: verdict.gain);
    } else {
      engine.playOneShot2d(src, volume: verdict.gain, speed: speed, pan: pan);
    }
    _bump(played, id);
  }

  /// **纯函数**：这一声到底该不该放。三重闸门的全部逻辑都在这里。
  ///
  /// 把它抽成纯函数只有一个理由：**它是"晴天的滴滴答答"那个 bug 的判据**，
  /// 而这类判据必须能被断言住，不能靠"改一版听一遍"。
  static SfxAdmission admit({
    required SfxId id,
    required bool loaded,
    required double distance,
    required double gain,
    bool positional = false,
    double? sinceLast,
    double gap = 0.0,
  }) {
    if (!loaded) return SfxAdmission(false, 'notLoaded', 0);

    final maxD = maxDistance[id];
    if (maxD != null && distance > maxD) {
      return SfxAdmission(false, 'tooFar', 0);
    }
    if (sinceLast != null && sinceLast < gap) {
      return SfxAdmission(false, 'tooSoon', 0);
    }

    var g = gain;
    if (maxD != null || positional) g *= distanceGain(distance);
    g = g.clamp(0.0, 1.0);
    if (g < 0.012) return SfxAdmission(false, 'tooQuiet', 0);

    return SfxAdmission(true, 'ok', g);
  }

  /// 下一次放行需要等的时长（每次放行后重新抽一次）。
  final Map<SfxId, double> _nextGap = {};

  void _bump(Map<SfxId, int> m, SfxId id) => m[id] = (m[id] ?? 0) + 1;

  /// 每帧推进内部时钟（闸门按它计时）。
  void tick(double dt) => _clock += dt;

  Future<void> release() async {
    _sources.clear();
    _cursor.clear();
    _lastPlayedAt.clear();
  }

  Map<String, Object?> diagnostics() => {
        'loaded': {
          for (final e in _sources.entries) e.key.asset: e.value.length,
        },
        'played': {for (final e in played.entries) e.key.asset: e.value},
        'dropped': {for (final e in dropped.entries) e.key.asset: e.value},
      };
}
