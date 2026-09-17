/// **统一音频管理接口**：游戏侧唯一需要认识的音频入口。
///
/// 世界层（`world.dart`）只做四件事，其余全在本文件内部：
///
///   1. 启动后 `beginBaking()` —— 后台把波形烘出来（不阻塞）；
///   2. 可操作之后 `arm()` —— 初始化设备并起播（幂等，可反复调）；
///   3. 每帧 `update(...)` —— 递进听者位姿、角色状态、天气快照；
///   4. 事件发生时调对应的方法（`footstep` / `splash` / `pickup` / …）。
///
/// ## 分层结构
///
/// ```
///  world.dart
///      └── AudioManager            （本文件：门面 + 每帧编排）
///            ├── BusMix             （mix.dart：master × 总线音量）
///            ├── AmbienceMix        （mix.dart：天气/场景 → 每层目标音量，纯函数）
///            ├── AmbienceLayerPlayer × 4   （ambience.dart：河/雨/风/夜，各自独立）
///            └── SfxPlayer          （sfx.dart：事件音，带三重闸门）
///                   ↓
///            AudioEngine            （engine.dart：SoLoud 的全部 FFI 调用）
///                   ↓
///            PcmBaker               （baker.dart：配方 → PCM → WAV 字节）
/// ```
///
/// 每一层各自可单测：配方与混音决策是纯函数，播放器是纯状态机（引擎被接口隔离），
/// 引擎是薄封装。这正是"加一层新环境音只需要写一个 [AmbienceRecipe]"的前提。
///
/// ## 加一层新的环境音要改哪里
///
///   1. 写一个 [AmbienceRecipe]（波形）；
///   2. 在 `baker.dart` 的 [ambienceRecipes] 里加一行；
///   3. 在 `mix.dart` 的 [AmbienceLayer] 里加一个枚举值 + 它的基准音量；
///   4. 在 [AudioManager] 的 `_buildLayers()` 里加一行。
///
/// 播放、交叉淡化、淡入淡出、声部预算、诊断都不用碰。
library;
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../game/flow.dart';
import '../game/terrain.dart';
import 'ambience.dart';
import 'baker.dart';
import 'engine.dart';
import 'mix.dart';
import 'motion.dart';
import 'pcm.dart';
import 'recipe.dart';
import 'sfx.dart';
import 'synth/river.dart';

/// 听者位姿（世界层每帧给出）。朝向来自**相机**，位置来自**角色**。
class AudioListener {
  const AudioListener({
    required this.position,
    required this.forward,
    required this.up,
    required this.velocity,
  });

  /// 听者位置（米）。取角色锚点，而不是相机。
  ///
  /// 第三人称里相机在角色身后 8–22m，若把听者放在相机上，"离河多远"会被相机
  /// 距离污染 —— 角色明明站在岸边，声音却像在几十米外。朝向仍取相机，
  /// 转身时声像才会跟着转。
  final vm.Vector3 position;
  final vm.Vector3 forward;
  final vm.Vector3 up;
  final vm.Vector3 velocity;
}

/// 天气给音频的输入（**只有天气**；河流相关的量由本层自己从 [RiverFlow] 取）。
class WeatherAudio {
  const WeatherAudio({
    required this.rainAmount,
    required this.windAmount,
    required this.nightAmount,
  });

  /// 雨势 0–1。过渡期间是插值中的值。
  final double rainAmount;

  /// 风/草摆强度 0–1。
  final double windAmount;

  /// 夜色 0–1。
  final double nightAmount;

  static const WeatherAudio clear = WeatherAudio(
    rainAmount: 0,
    windAmount: 0.35,
    nightAmount: 0,
  );
}

/// 游戏的音频门面。
class AudioManager {
  AudioManager({
    required this.terrain,
    required this.flow,
    this.seed = 5150,
    this.sampleRate = 44100,
  }) : engine = AudioEngine(sampleRate: sampleRate) {
    sfx = SfxPlayer(engine: engine);
    _buildLayers();
  }

  final Terrain terrain;
  final RiverFlow flow;
  final int sampleRate;

  /// 烘焙的随机种子：同一个种子得到完全一样的波形（可复现）。
  final int seed;

  final AudioEngine engine;
  late final SfxPlayer sfx;

  final BusMix buses = BusMix();

  final Map<AmbienceLayer, AmbienceLayerPlayer> layers = {};

  // ------------------------------------------------------------------
  // 烘焙（异步、分片、不阻塞）
  // ------------------------------------------------------------------

  /// 已烘焙好的 WAV 字节，按资源名索引。
  final Map<String, Uint8List> _baked = {};

  /// 还没跑的任务。
  final List<BakeJob> _bakeQueue = [];

  bool _baking = false;
  bool _bakeDone = false;
  int _bakeFailures = 0;

  /// 烘焙总耗时（毫秒，累计 CPU 时间，含让出），诊断用。
  int bakeMsTotal = 0;

  /// 开始后台烘焙。**幂等**，重复调用无副作用。
  ///
  /// 每烘好一条就交给引擎（若引擎就绪）并**让出一次事件循环**，所以：
  ///   * 原生端 `compute` 在独立 isolate 里跑，主线程完全不被占用；
  ///   * Web 端退化为同 isolate，但单次阻塞被限制在"一条循环"的量级。
  void beginBaking() {
    if (_baking || _bakeDone) return;
    _baking = true;
    _bakeQueue.addAll(allBakeJobs(sampleRate: sampleRate, seed: seed));
    unawaited(_pump());
  }

  Future<void> _pump() async {
    final sw = Stopwatch()..start();
    while (_bakeQueue.isNotEmpty) {
      if (_disposed) return;
      final job = _bakeQueue.removeAt(0);
      try {
        final pcm = await compute(runBakeJob, job);
        _baked[job.assetName] = encodeWav16(pcm, sampleRate: sampleRate);
        // 引擎已经就绪的话，立刻把它交给对应的层/音效（边烘边能用）。
        await _install(job);
      } catch (e) {
        _bakeFailures++;
        if (kDebugMode) debugPrint('KirbyScene：烘焙 ${job.assetName} 失败 $e');
      }
      // 让出事件循环：这是"烘焙不阻塞输入"的关键一步。
      await Future<void>.delayed(Duration.zero);
    }
    bakeMsTotal = sw.elapsedMilliseconds;
    _baking = false;
    _bakeDone = true;
    // **烘完再装一遍**，不能只靠烘每一条时的即时装载。
    //
    // 原因是一个真实的竞态（已踩过）：环境音层要求"全部变体都烘好"才能装，
    // 而设备初始化（`ensureReady`）是异步的。于是河道那 5 档如果在设备就绪
    // **之前**就全部烘完，逐条时的即时装载会全部因为 `engine.isReady == false`
    // 而被跳过，而那一刻又没有任何人再回头装它 —— 结果就是"河一层从来没声音"。
    // 烘完之后无条件补一遍，这个窗口就关上了（重复装载是幂等的）。
    await _installAllBaked();
    _refreshPrepared();
  }

  /// 把已烘焙的字节装到对应的播放器上（只在引擎就绪时真正发生）。
  Future<void> _install(BakeJob job) async {
    if (!engine.isReady) return;
    final wav = _baked[job.assetName];
    if (wav == null) return;
    if (job.kind == 'sfx') {
      final id = SfxId.values.firstWhere((s) => s.asset == job.name);
      final list = <Uint8List>[];
      for (var i = 0; i < id.variants; i++) {
        final b = _baked[id.variantName(i)];
        if (b == null) return; // 变体还没烘齐，等齐了再装
        list.add(b);
      }
      await sfx.prepare(id, list);
    } else {
      // 环境音层的变体要一起装（交叉淡化需要相邻档同时在手）。
      final recipe = ambienceRecipes[job.name]!;
      final list = <Uint8List>[];
      for (var i = 0; i < recipe.variantCount; i++) {
        final b = _baked[ambienceAsset(job.name, i)];
        if (b == null) return;
        list.add(b);
      }
      await layers[AmbienceLayer.values.byName(job.name)]?.prepare(list);
    }
  }

  /// 引擎就绪后把**所有已经烘好**的东西装进去。`arm()` 会调它。
  Future<void> _installAllBaked() async {
    for (final job in allBakeJobs(sampleRate: sampleRate, seed: seed)) {
      if (_baked.containsKey(job.assetName)) await _install(job);
    }
    _refreshPrepared();
  }

  void _refreshPrepared() {
    preparedLayers = layers.values.where((l) => l.isPrepared).length;
  }

  bool get isBaking => _baking;
  bool get isBakeDone => _bakeDone;
  int get bakedAssets => _baked.length;
  int get bakeFailures => _bakeFailures;
  int preparedLayers = 0;

  // ------------------------------------------------------------------
  // 起播
  // ------------------------------------------------------------------

  bool _started = false;
  bool _disposed = false;
  bool _arming = false;

  /// 是否已经在出声（诊断用）。注意它只代表"起播命令没抛异常"。
  bool get isPlaying => _started;
  bool get isEngineReady => engine.isReady;

  /// 引擎从收到 `arm` 到真正能出声花的时间（毫秒）。诊断用。
  int lastArmMs = 0;
  int armCount = 0;

  /// 用户手势（或原生端启动完成）之后调用：初始化设备并起播。
  ///
  /// **幂等，且从不拆除引擎。** 上一版在第一次按键时走"先拆后建"的强制路径，
  /// 实测在真实设备上造成约 1.2 秒的主线程停顿 —— 玩家感受到的就是"按了键
  /// 没反应"。现在：
  ///
  ///   * 引擎已经在跑 → 直接返回（重复调用零成本）；
  ///   * 引擎没跑 → 只做"初始化 + 装载 + 起播"这一条路，不 deinit。
  Future<void> arm() async {
    if (_disposed || _arming) return;
    if (_started) return;
    _arming = true;
    final sw = Stopwatch()..start();
    try {
      if (!await engine.ensureReady()) {
        // Web 上没手势时会被 autoplay policy 拒绝；下次手势会再来一次。
        return;
      }
      if (!_baking && !_bakeDone) beginBaking();
      await _installAllBaked();
      _started = true;
      armCount++;
      lastArmMs = sw.elapsedMilliseconds;
      engine.setGlobalVolume(buses.master);
    } catch (e) {
      engine.lastError = '$e';
      if (kDebugMode) debugPrint('KirbyScene：音频起播失败（不影响游戏）$e');
    } finally {
      _arming = false;
    }
  }

  /// 在**没有用户手势**时预初始化（原生端允许）。
  ///
  /// 目的在于把"第一次按键"与"打开音频设备"这两件事解耦：设备在小地图还在
  /// 渲染时就开好了，第一次按键不用等它。Web 上会被拒绝，此时安静返回。
  Future<void> preArm() => arm();

  /// 热重启/强制重播用：**会停顿主线程**，绝不要挂在手势或每帧路径上。
  Future<void> reset() async {
    _started = false;
    for (final l in layers.values) {
      await l.release();
    }
    await sfx.release();
    await engine.reset();
  }

  Future<void> dispose() async {
    _disposed = true;
    for (final l in layers.values) {
      await l.release();
    }
    await sfx.release();
    await engine.reset();
  }

  // ------------------------------------------------------------------
  // 分层
  // ------------------------------------------------------------------

  void _buildLayers() {
    layers[AmbienceLayer.river] = AmbienceLayerPlayer(
      layer: AmbienceLayer.river,
      recipe: ambienceRecipes['river']!,
      engine: engine,
      is3d: true,
      fadeSeconds: 1.6,
    );
    layers[AmbienceLayer.rain] = AmbienceLayerPlayer(
      layer: AmbienceLayer.rain,
      recipe: ambienceRecipes['rain']!,
      engine: engine,
      is3d: false,
      fadeSeconds: 2.4, // 雨来雨停都要慢一点，跟随天气过渡本身
    );
    layers[AmbienceLayer.wind] = AmbienceLayerPlayer(
      layer: AmbienceLayer.wind,
      recipe: ambienceRecipes['wind']!,
      engine: engine,
      is3d: false,
      fadeSeconds: 2.0,
    );
    layers[AmbienceLayer.night] = AmbienceLayerPlayer(
      layer: AmbienceLayer.night,
      recipe: ambienceRecipes['night']!,
      engine: engine,
      is3d: false,
      fadeSeconds: 2.6,
    );
  }

  /// 单独控制某一层的启停（需求里的"各自可单独启停"）。
  void setLayerMuted(AmbienceLayer layer, bool muted) =>
      layers[layer]?.setMuted(muted);

  /// 单独控制某一层的音量 —— 通过把它的目标音量乘一个系数实现，不碰别的层。
  void setLayerTrim(AmbienceLayer layer, double trim) =>
      _trims[layer] = trim.clamp(0.0, 2.0);
  final Map<AmbienceLayer, double> _trims = {};

  // ------------------------------------------------------------------
  // 每帧
  // ------------------------------------------------------------------

  static const double _mixInterval = 0.10;

  double _mixClock = 0;

  /// 听者位置（诊断）。
  final vm.Vector3 listenerPosition = vm.Vector3.zero();
  final vm.Vector3 listenerForward = vm.Vector3(0, 0, 1);

  /// 河道上离角色最近的点（3D 声源位置）与到它的距离。
  final vm.Vector3 riverSource = vm.Vector3.zero();
  double riverDistance = 0;
  double riverSectionSpeed = 0;
  double riverSectionTurbulence = 0;
  double riverIntensity = 0;
  double riverPlaybackRate = 1;

  /// 本帧解析出的场景快照（诊断：一眼看出"现在该听到什么"）。
  AmbienceState ambienceState = AmbienceState.silent;

  final AudioMotion _motion = AudioMotion();
  vm.Vector3 get _characterVelocity => _motion.velocity;

  /// 传送／重生是坐标重定位，不能把位移送进多普勒和脚步计算。
  void resetMotion() {
    _motion.reset();
    _strideAccumulator = 0;
  }

  // 脚步：按"走过的距离"而不是"时间"触发 —— 加速/减速时步频自然跟着变。
  double _strideAccumulator = 0;
  bool _stepFoot = false;

  void update(
    double dt, {
    required AudioListener listener,
    required vm.Vector3 characterPos,
    required bool grounded,
    required WeatherAudio weather,
  }) {
    if (_disposed) return;
    sfx.tick(dt);
    buses.update(dt);
    if (engine.isReady) engine.setGlobalVolume(buses.master);

    if (!_started) return;

    // 同时拒绝未显式通知的坐标跳变；超大伪速度会使原生多普勒速率归零。
    _motion.update(dt, characterPos);

    // 听者位姿每帧只更新 **Dart 侧的状态**（零成本）；真正下发到引擎放在下面
    // 的 10Hz 节拍里 —— 理由见 [_pushListener]。
    listenerPosition.setFrom(listener.position);
    listenerForward.setFrom(listener.forward);
    _listener = listener;

    _updateFootsteps(dt, characterPos, grounded);

    _mixClock += dt;
    if (_mixClock < _mixInterval) return;
    final step = _mixClock;
    _mixClock = 0;

    _pushListener();
    _updateAmbience(step, characterPos, weather);
  }

  AudioListener? _listener;

  /// 把听者位姿下发给引擎。**只在 10Hz 的节拍上调用，绝不每帧调。**
  ///
  /// # 为什么这个调用也不能每帧发
  ///
  /// 它在 flutter_soloud 里**每次都顺带跑一遍全声部的 3D 计算**：
  /// ```cpp
  /// // bindings.cpp
  /// player->set3dListenerParameters(...);
  /// player->update3dAudio();        // ← Soloud::update3dAudio() 第一件事就是
  ///                                 //   lockAudioMutex_internal()
  /// ```
  /// 而 `mAudioThreadMutex` 正被 CoreAudio 回调里的混音器持有整段 `mix()`。
  /// 每秒下发 30 次 = 每秒跟混音线程抢 30 次锁；而混音线程跑在实时优先级上、
  /// 回调又密，主线程很容易**长期抢不到** —— 渲染与输入一起被冻住。
  ///
  /// 10Hz 对声像/多普勒完全够用：3D 声源位置本来就是这个节拍刷新的。
  void _pushListener() {
    final l = _listener;
    if (l == null || !engine.isReady) return;
    engine.setListener(
      x: l.position.x,
      y: l.position.y,
      z: l.position.z,
      forwardX: l.forward.x,
      forwardY: l.forward.y,
      forwardZ: l.forward.z,
      velX: _characterVelocity.x,
      velY: _characterVelocity.y,
      velZ: _characterVelocity.z,
    );
  }

  void _updateAmbience(double dt, vm.Vector3 characterPos, WeatherAudio weather) {
    // 声源 = 河道中心线上离**角色**最近的点（河是线声源，最近点就是听感上的方向）。
    final (px, pz) = flow.nearestCenterPoint(characterPos.x, characterPos.z);
    riverSource.setValues(px, flow.waterYAt(pz), pz);
    final dx = characterPos.x - px;
    final dz = characterPos.z - pz;
    riverDistance = math.sqrt(dx * dx + dz * dz);

    // 音色取**声源处**的断面参数，而不是角色脚下的：你听到的是那段水，
    // 不是自己站的地方。站在深潭边听上游的急滩，本该是急滩的声音。
    riverSectionSpeed = flow.sectionSpeedAt(pz);
    riverSectionTurbulence = flow.sectionTurbulenceAt(pz);

    final mix = RiverSoundMix.evaluate(
      distanceToRiver: riverDistance,
      sectionSpeed: riverSectionSpeed,
      meanSpeed: flow.meanSpeed,
      sectionTurbulence: riverSectionTurbulence,
    );
    riverIntensity = mix.intensity;
    riverPlaybackRate = mix.playbackRate;

    ambienceState = AmbienceState(
      rainAmount: weather.rainAmount,
      windAmount: weather.windAmount,
      nightAmount: weather.nightAmount,
      riverIntensity: riverIntensity,
      riverDistance: riverDistance,
    );

    final targets = AmbienceMix.all(ambienceState);
    final strengths = <AmbienceLayer, double>{
      AmbienceLayer.river: riverIntensity,
      AmbienceLayer.rain: weather.rainAmount,
      AmbienceLayer.wind: weather.windAmount,
      AmbienceLayer.night: weather.nightAmount,
    };

    for (final layer in AmbienceLayer.values) {
      final player = layers[layer];
      if (player == null) continue;
      final target = (targets[layer] ?? 0) * (_trims[layer] ?? 1.0);
      player.update(
        dt,
        targetGain: target,
        strength: strengths[layer] ?? 0,
        busCoefficient: buses.coefficient(AudioBus.ambience),
        sourcePos: layer == AmbienceLayer.river ? riverSource : null,
      );
    }

    _applyRiverRate();
  }

  double _sentRiverRate = double.nan;
  int _sentRiverHandles = -1;

  /// 河流的"节奏"细调：音色由档位负责，速率只表达快慢。
  ///
  /// **变了才发。** `fadeRelativePlaySpeed` 每次调用都会重开一个淡变，
  /// 而且**每一次都是一次 FFI** —— 而 FFI 要抢 SoLoud 的全局音频锁，
  /// 锁又被 CoreAudio 回调里的混音器持有（见 `engine.dart` 里 `setListener`
  /// 与 `outputLevel` 的注释）。速率只在 0.90–1.14 之间动，10Hz 盲目下发
  /// 等于每秒白抢十几次锁。声部数一并当判据：新档起播时必须补发一次。
  void _applyRiverRate() {
    final river = layers[AmbienceLayer.river];
    if (river == null || !engine.isReady) return;
    final handles = _riverHandles(river).toList();
    if (handles.length == _sentRiverHandles &&
        (_sentRiverRate - riverPlaybackRate).abs() < 0.01) {
      return;
    }
    _sentRiverRate = riverPlaybackRate;
    _sentRiverHandles = handles.length;
    for (final h in handles) {
      engine.fadeSpeed(h, riverPlaybackRate, const Duration(milliseconds: 240));
    }
  }

  /// 河流层当前的声部句柄（用于统一下发播放速率）。
  Iterable<SoundHandle> _riverHandles(AmbienceLayerPlayer player) =>
      player.handles;

  // ------------------------------------------------------------------
  // 事件音（统一入口）
  // ------------------------------------------------------------------

  /// 一步。`inWater` 决定音色（浅水比草地更亮更长）。
  ///
  /// 步频按**走过的距离**驱动：走得快步子就密，停下来就自然没有声音。
  static const double strideWalk = 1.75;
  static const double strideRun = 2.25;

  void _updateFootsteps(double dt, vm.Vector3 characterPos, bool grounded) {
    if (!grounded) return;
    final speed = math.sqrt(
      _characterVelocity.x * _characterVelocity.x +
          _characterVelocity.z * _characterVelocity.z,
    );
    if (speed < 0.35) return;

    _strideAccumulator += speed * dt;
    final stride = speed > 5.0 ? strideRun : strideWalk;
    if (_strideAccumulator < stride) return;
    _strideAccumulator = 0;

    _stepFoot = !_stepFoot;
    footstep(speed: speed, inWater: _isInWater(characterPos));
  }

  bool _isInWater(vm.Vector3 p) =>
      terrain.heightAt(p.x, p.z) < flow.waterYAt(p.z) + 0.06;

  /// 脚步。原地声（不需要世界坐标：听者就在角色身上）。
  void footstep({required double speed, required bool inWater}) {
    final run = speed > 5.0;
    final gain = (run ? 0.62 : 0.40) + (_stepFoot ? 0.06 : 0.0);
    sfx.play(
      inWater
          ? SfxId.stepWater
          : (run ? SfxId.stepGrass : SfxId.stepSoil),
      gain: gain,
      // 左右脚轻微交替声像：步子"有方向"，比两声完全重合自然得多。
      pan: _stepFoot ? 0.14 : -0.14,
    );
  }

  void jump() => sfx.play(SfxId.jump, gain: 0.55);

  void land({required double impact}) => sfx.play(
        SfxId.land,
        gain: (0.30 + 0.60 * impact.clamp(0.0, 1.0)),
      );

  void pickup() => sfx.play(SfxId.pickup, gain: 0.75);

  /// 界面音（切天气 / 重开）。
  void uiTap() => sfx.play(SfxId.ui, gain: 0.55);

  /// 过关。
  void levelClear() => sfx.play(SfxId.fanfare, gain: 0.85);

  /// 鱼跃出水面的水花。[x]/[z] 是**世界坐标**。
  ///
  /// 注意本方法**每帧可能被调用多次**（一次多鱼跃出），闸门在 [SfxPlayer] 里：
  /// 超过每秒约 1.8 声会被丢弃，超过 48m 整声丢弃。上一版没有这道闸门，
  /// 于是"晴天的滴滴答答"就是这么来的。
  void splash({required double size, required double x, required double z}) {
    final y = flow.waterYAt(z) + 0.05;
    final d = _distanceToListener(x, y, z);
    sfx.play(
      SfxId.splash,
      gain: 0.30 + 0.42 * (size / 0.40).clamp(0.0, 1.0),
      at: vm.Vector3(x, y, z),
      distance: d,
    );
  }

  double _distanceToListener(double x, double y, double z) {
    final dx = x - listenerPosition.x;
    final dy = y - listenerPosition.y;
    final dz = z - listenerPosition.z;
    return math.sqrt(dx * dx + dy * dy + dz * dz);
  }

  /// **通用扩展点**：任何新的游戏事件音都可以直接走它，不必改本文件的结构。
  void playOneShot(
    SfxId id, {
    double gain = 1.0,
    vm.Vector3? at,
    double speed = 1.0,
  }) {
    sfx.play(
      id,
      gain: gain,
      at: at,
      speed: speed,
      distance: at == null ? 0 : _distanceToListener(at.x, at.y, at.z),
    );
  }

  // ------------------------------------------------------------------
  // 设置与诊断
  // ------------------------------------------------------------------

  void setBusGain(AudioBus bus, double v) => buses.setGain(bus, v);
  void setMasterGain(double v) => buses.setMaster(v);

  // ------------------------------------------------------------------
  // 引擎侧探针（**仅显式刷新**）
  // ------------------------------------------------------------------

  /// `outputLeft/Right` / `activeVoices` / `engineTimeMs` 的缓存值。
  ///
  /// # ⚠️ 为什么这些量不能每帧读
  ///
  /// 它们在 SoLoud 侧都要经 FFI 拿**全局音频锁**（`mAudioThreadMutex`），
  /// 而那个锁被 CoreAudio 回调里的混音器持有整段 `mix()`。在帧回调里读
  /// 它们，等于每帧跟混音线程抢一次锁；抢不到就把主线程（渲染 + 输入）
  /// 整整挡住一个混音周期，甚至会因为混音线程重新上锁更快而**被饿死很久**。
  /// 实测抓到过 "`state` 每帧都读 → 按键几十秒无响应" 的完整证据链
  /// （详见 `engine.dart` 里 [AudioEngine.outputLevel] 的注释）。
  ///
  /// 所以它们被拆成一条**显式**路径：只有 [refreshProbe]（MCP 的
  /// `audio_levels`）去真读，其余时候诊断读的是这里的缓存。
  double probeLeft = 0;
  double probeRight = 0;
  int probeVoices = 0;
  int probeEngineMs = 0;

  /// 探针是否被刷新过（没刷过的 0 不能当成"静音"的证据）。
  bool probeValid = false;

  /// 显式刷新引擎侧探针。**绝不要在每帧路径上调用**（见上面的注释）。
  void refreshProbe() {
    final lvl = engine.outputLevel();
    probeLeft = lvl.left;
    probeRight = lvl.right;
    probeVoices = engine.activeVoices;
    probeEngineMs = engine.engineTimeMs;
    probeValid = true;
  }

  /// 暴露给 MCP `state.audio` 的一组量。
  ///
  /// 关键是**引擎侧读回的**那几个：`engineTimeMs` 在推进、`outputLeft/Right`
  /// 非零，才说明"真的在出声"。`playing` 只代表"起播命令没抛异常"
  /// （上一版踩过：状态里写着 playing，实际一点声音都没有）。
  ///
  /// 本方法**不碰音频锁**（全部读 Dart 侧状态与缓存），所以可以安全地
  /// 每帧调用；引擎侧的实测值要先用 [refreshProbe] 刷新。
  Map<String, Object?> diagnostics() {
    return {
      'started': _started,
      'baking': _baking,
      'bakeDone': _bakeDone,
      'bakedAssets': bakedAssets,
      'preparedLayers': preparedLayers,
      'bakeMs': bakeMsTotal,
      'bakeFailures': _bakeFailures,
      'armMs': lastArmMs,
      'armCount': armCount,
      'engine': engine.diagnostics(),
      'buses': buses.diagnostics(),
      'layers': {
        for (final e in layers.entries) e.key.name: e.value.diagnostics(),
      },
      'targets': {
        for (final e in AmbienceMix.all(ambienceState).entries)
          e.key.name: double.parse(e.value.toStringAsFixed(4)),
      },
      'trims': {
        for (final e in _trims.entries) e.key.name: e.value,
      },
      'river': {
        'intensity': double.parse(riverIntensity.toStringAsFixed(3)),
        'distance': double.parse(riverDistance.toStringAsFixed(2)),
        'sectionSpeed': double.parse(riverSectionSpeed.toStringAsFixed(3)),
        'sectionTurbulence':
            double.parse(riverSectionTurbulence.toStringAsFixed(3)),
        'playbackRate': double.parse(riverPlaybackRate.toStringAsFixed(3)),
        'source': [
          double.parse(riverSource.x.toStringAsFixed(2)),
          double.parse(riverSource.y.toStringAsFixed(2)),
          double.parse(riverSource.z.toStringAsFixed(2)),
        ],
      },
      'listener': [
        double.parse(listenerPosition.x.toStringAsFixed(2)),
        double.parse(listenerPosition.y.toStringAsFixed(2)),
        double.parse(listenerPosition.z.toStringAsFixed(2)),
      ],
      'characterSpeed': double.parse(_characterVelocity.length.toStringAsFixed(2)),
      'probeValid': probeValid,
      'outputLeft': double.parse(probeLeft.toStringAsFixed(4)),
      'outputRight': double.parse(probeRight.toStringAsFixed(4)),
      'engineTimeMs': probeEngineMs,
      'activeVoices': probeVoices,
      'sfx': sfx.diagnostics(),
    };
  }
}
