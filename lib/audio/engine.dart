/// **引擎层**：只负责"怎么跟 SoLoud 说话"。不含任何游戏语义。
///
/// 边界画在这里的理由：上面的一层（`manager.dart` / `ambience.dart`）需要决定
/// "什么时候该发什么声"，而这一层要处理的是"FFI 调用有没有保护声部、淡变有没
/// 有被重复重开、设备有没有就绪"。两者变化的原因完全不同，混在一起就没法各自
/// 测、也没法各自读诊断。
///
/// ## 选型：为什么是 `flutter_soloud`
///
/// 候选与淘汰理由（**引擎自带的音频能力不足**是前提：`flutter_scene` 是纯渲染
/// 库，完全没有音频 API，能用的只有平台播放器）：
///
/// | 库 | 为什么不用 |
/// |---|---|
/// | `audioplayers` | 只暴露 volume / balance / playbackRate。**没有 3D 声源**、没有滤波器、没有采样级淡变；循环由平台播放器（macOS 是 AVPlayer）自己接缝，接缝样本对齐不受我们控制 —— 这正是"声音断断续续"的一大来源。 |
/// | `just_audio` | 为**流媒体音乐播放器**设计（播放列表、音轨选择、seek）。同样没有 3D 声源/声部管理，且它的定位是"播放一个文件"，不是"同时混 30 个游戏声源"。 |
/// | 自己写 miniaudio FFI | 等于重写一个音频引擎，且要自己维护六个平台的构建钩子。本项目要的是声音，不是音频引擎。 |
/// | FMOD / Wwise | 商业授权、体积大、Dart 无官方绑定。 |
/// | **`flutter_soloud`** | C++ SoLoud 的 FFI 绑定（**不是**平台通道，所以没有 channel 往返延迟）：3D 声源 + 听者 + 距离衰减 + 多普勒、内存加载（`loadMem`，无需文件资产）、**采样级无缝循环**、逐声部淡变（`fadeVolume` / `fadeRelativePlaySpeed`）、声部保护与上限、滤波器、全平台（含 Web / WASM）。游戏音频需要的每一样它都有。 |
///
/// ## 三条与"卡住主线程"直接相关的约定
///
///   1. **`ensureReady()` 幂等且可以被反复调用**。它从不 `deinit` —— 上一版在
///      第一次按键时走 `force` 路径先拆后建，实测在真实设备上造成约 **1.2 秒**的
///      主线程停顿（`deinitAsync` + `init` + 5 次 `loadMem`）。玩家感受到的就是
///      "按了键没反应"。现在拆除只在显式 [reset] 时发生（热重启用）。
///   2. **引擎初始化不在关键路径上**。`beginPreparing()` 可以在**没有**用户手势时
///      就把设备备好（原生端没有 autoplay 限制），于是第一次按键不用等设备。
///      Web 上 `init` 会被浏览器拒绝，那时它只是安静地留到手势后再来一次。
///   3. **所有音量下发都有"变了才发"判据**。`fadeVolume` 每次调用都会**重开**一个
///      淡变；每帧无脑调用等于永远淡不完，还会一直抢引擎锁。
library;
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

/// 距离衰减模型号（SoLoud 的 `ATTENUATION_MODELS` 是整数枚举）。
abstract final class AttenuationModel {
  static const int none = 0;
  static const int inverseDistance = 1;
  static const int linearDistance = 2;
  static const int exponentialDistance = 3;
}

/// SoLoud 的薄封装。**不持有任何游戏对象**。
class AudioEngine {
  AudioEngine({
    this.sampleRate = 44100,
    this.bufferSize = 1024,
    this.maxVoices = 32,
    this.lowLatency = false,
  });

  /// 波形与引擎用**同一个采样率**，于是全程没有重采样。
  ///
  /// 之前合成侧用 22050（理由：流水声的能量都在 8kHz 以下），现在统一到 44100
  /// 是因为引擎内部就是 44100：同率可以完全跳过一次重采样 —— 重采样器会把
  /// 8kHz 以上的噪声折回来变成零星的"沙沙毛刺"，而省下的内存（每条循环
  /// 8s × 22050 × 2B ≈ 350KB）在桌面端不值得冒险。
  final int sampleRate;

  /// 1024 帧 ≈ 23ms：足够低（操作与画面同步）又不至于在桌面端因为缓冲太小而爆音。
  final int bufferSize;

  /// 是否请求 miniaudio 的 **low-latency** 性能档。
  ///
  /// **默认关掉，而且这是修掉"主线程被冻住"的一部分。**
  ///
  /// `lowLatency: true` 会让 miniaudio 选 `ma_performance_profile_low_latency`
  /// —— 回调周期取设备的最小值（常见 128–256 帧），于是混音线程**极频繁**
  /// 地上锁。而主线程每做一次音频 FFI（下发听者、改音量、读电平……）都要抢
  /// 同一把锁，回调越密，主线程越容易长期抢不到：**渲染 + 输入一起被冻住**。
  ///
  /// 本项目是一堆环境音循环 + 短音效，几十毫秒的输出延迟完全听不出来；
  /// 换掉的是"跟游戏主线程抢锁"这个代价。
  final bool lowLatency;

  final int maxVoices;

  bool _ready = false;
  bool _initializing = false;
  int _initAttempts = 0;
  int initCount = 0;

  /// 最近一次失败的原因。音频"没声音"时唯一的线索是引擎抛的异常文本，
  /// 而 App 的 stdout 在别人的终端里 —— 留在状态里，这个问题才查得下去。
  String? lastError;

  bool get isReady => _ready;

  final Map<String, AudioSource> _sources = {};
  int _loadCount = 0;

  /// 已装载的资源数（诊断）。
  int get sourceCount => _sources.length;

  /// 累计 `init` 成功次数（诊断：>1 说明被反复重建过）。
  int get loadCount => _loadCount;

  /// 就绪所有资源需要的引擎初始化。**幂等**，并发调用只会初始化一次。
  Future<bool> ensureReady() async {
    if (_ready) return true;
    if (_initializing) {
      // 别人正在初始化：等它。绝不并发 init（SoLoud 会先 deinit 再 init）。
      while (_initializing) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      return _ready;
    }
    _initializing = true;
    try {
      if (SoLoud.instance.isInitialized) {
        // 热重启之后原生侧引擎可能还活着，Dart 侧对象已经换了一代。
        // 直接用，不拆 —— 拆的代价是几百毫秒的主线程停顿。
        _ready = true;
      } else {
        _initAttempts++;
        await SoLoud.instance.init(
          sampleRate: sampleRate,
          bufferSize: bufferSize,
          channels: Channels.stereo,
          lowLatency: lowLatency,
        );
        initCount++;
        _ready = true;
      }

      // 打开引擎的**可视化分析**。看起来像为了画面，其实是为了**诊断**：
      // `getApproximateVolume(0/1)` 读的是 `mVisualizationChannelVolume[ch]`，
      // 而那个数组只在 ENABLE_VISUALIZATION 打开时每块混音才被填充 ——
      // 不开的话它恒为 0，诊断里会一直写着"左右声道输出全 0"，看上去像哑的。
      // 开销只是一次 256 点的电平统计，可忽。
      SoLoud.instance.setVisualizationEnabled(true);
      SoLoud.instance.setMaxActiveVoiceCount(maxVoices);
      lastError = null;
      return true;
    } catch (e) {
      // 设备被占用、浏览器未解锁、后端不支持 —— 都不该影响游戏。
      _ready = false;
      lastError = '$e';
      if (kDebugMode) {
        debugPrint('KirbyScene：音频引擎初始化失败（不影响游戏）$e');
      }
      return false;
    } finally {
      _initializing = false;
    }
  }

  /// 在**没有用户手势**的情况下预初始化。
  ///
  /// 原生端允许；Web 上会被 autoplay policy 拒绝，那时返回 false 就好 ——
  /// 调用方不该把它当错误。这是"第一次按键不应该等设备"的落点。
  Future<bool> beginPreparing() => ensureReady();

  /// 装载一段波形（WAV 字节）。同名只装一次。
  Future<AudioSource?> load(String assetName, Uint8List wav) async {
    final existing = _sources[assetName];
    if (existing != null) return existing;
    if (!await ensureReady()) return null;
    try {
      final src = await SoLoud.instance.loadMem('$assetName.wav', wav);
      _sources[assetName] = src;
      _loadCount++;
      return src;
    } catch (e) {
      lastError = '$e';
      if (kDebugMode) debugPrint('KirbyScene：装载 $assetName 失败 $e');
      return null;
    }
  }

  AudioSource? source(String assetName) => _sources[assetName];

  bool isLoaded(String assetName) => _sources.containsKey(assetName);

  /// 起播一个 2D（居中）循环声源。返回 null 表示引擎不可用。
  SoundHandle? playLoop2d(AudioSource src, {double volume = 0}) {
    try {
      return SoLoud.instance.play(src, looping: true, volume: volume);
    } catch (e) {
      lastError = '$e';
      return null;
    }
  }

  /// 起播一个 3D 循环声源。
  ///
  /// **距离衰减刻意关掉**（[AttenuationModel.none]）：距离→音量这条曲线由
  /// `mix.dart` 的 `AmbienceMix.distanceGain` 统一决定。两处同时衰减会把
  /// "离河多远"算成平方 —— 那正是上一版"站在河边像站在瀑布旁、跑远了又
  /// 几乎听不见"的成因。3D 声源这里只提供**声像与多普勒**。
  SoundHandle? playLoop3d(AudioSource src, double x, double y, double z,
      {double volume = 0, double doppler = 0.15}) {
    try {
      final h = SoLoud.instance.play3d(src, x, y, z, looping: true, volume: volume);
      SoLoud.instance.set3dSourceAttenuation(h, AttenuationModel.none, 1.0);
      SoLoud.instance.set3dSourceDopplerFactor(h, doppler);
      SoLoud.instance.setProtectVoice(h, true);
      return h;
    } catch (e) {
      lastError = '$e';
      return null;
    }
  }

  /// 起播一个一次性音效（2D）。
  SoundHandle? playOneShot2d(AudioSource src,
      {double volume = 1, double pan = 0, double speed = 1}) {
    try {
      final h = SoLoud.instance.play(src, volume: volume, pan: pan);
      if ((speed - 1.0).abs() > 1e-3) {
        SoLoud.instance.setRelativePlaySpeed(h, speed);
      }
      return h;
    } catch (e) {
      lastError = '$e';
      return null;
    }
  }

  /// 起播一个一次性音效（3D，带世界坐标）。
  SoundHandle? playOneShot3d(AudioSource src, double x, double y, double z,
      {double volume = 1, double doppler = 0.15}) {
    try {
      final h = SoLoud.instance.play3d(src, x, y, z, volume: volume);
      SoLoud.instance.set3dSourceAttenuation(h, AttenuationModel.none, 1.0);
      SoLoud.instance.set3dSourceDopplerFactor(h, doppler);
      return h;
    } catch (e) {
      lastError = '$e';
      return null;
    }
  }

  /// 停掉一个声部（淡出由调用方负责，这里只是最终收尾）。
  Future<void> stop(SoundHandle handle) async {
    try {
      await SoLoud.instance.stop(handle);
    } catch (_) {
      // 已经失效的句柄 stop 会抛，忽略即可 —— 目的只是尽量归还资源。
    }
  }

  /// 设定声部音量。**只在真的变了才调**（见文件头第 3 条）。
  void setVolume(SoundHandle handle, double volume) {
    try {
      SoLoud.instance.setVolume(handle, volume.clamp(0.0, 1.0));
    } catch (e) {
      lastError = '$e';
    }
  }

  /// 淡变声部音量。
  void fadeVolume(SoundHandle handle, double volume, Duration time) {
    try {
      SoLoud.instance.fadeVolume(handle, volume.clamp(0.0, 1.0), time);
    } catch (e) {
      lastError = '$e';
    }
  }

  void fadeSpeed(SoundHandle handle, double speed, Duration time) {
    try {
      SoLoud.instance.fadeRelativePlaySpeed(handle, speed, time);
    } catch (e) {
      lastError = '$e';
    }
  }

  void move3d(SoundHandle handle, double x, double y, double z) {
    try {
      SoLoud.instance.set3dSourceParameters(handle, x, y, z, 0, 0, 0);
    } catch (e) {
      lastError = '$e';
    }
  }

  /// 下发听者位姿。`at` 是"看向的点"（不是单位向量）。
  ///
  /// **位姿没变就不发。** 这不是省 CPU，是省**锁**：这个调用要经 FFI 拿
  /// SoLoud 的全局音频锁（`mAudioThreadMutex`），而那个锁正被 CoreAudio 回调
  /// 里的混音器持有（见 [outputLevel] 的注释）。静止机位下每帧无谓地抢锁，
  /// 是主线程被饿住的直接来源之一。
  void setListener({
    required double x,
    required double y,
    required double z,
    required double forwardX,
    required double forwardY,
    required double forwardZ,
    double velX = 0,
    double velY = 0,
    double velZ = 0,
  }) {
    if (!_listenerChanged(
        x, y, z, forwardX, forwardY, forwardZ, velX, velY, velZ)) {
      return;
    }
    try {
      SoLoud.instance.set3dListenerParameters(
        x,
        y,
        z,
        x + forwardX,
        y + forwardY,
        z + forwardZ,
        0,
        1,
        0,
        velX,
        velY,
        velZ,
      );
    } catch (e) {
      lastError = '$e';
    }
  }

  /// 上一次下发过的听者位姿（用于"没变就不发"）。
  final List<double> _lastListener = <double>[];

  /// 位置 5mm / 朝向 2e-3 / 速度 5cm/s —— 比这些更小的变化听不出来。
  static const List<double> _listenerEps = [
    5e-3, 5e-3, 5e-3, // 位置
    2e-3, 2e-3, 2e-3, // 朝向
    5e-2, 5e-2, 5e-2, // 速度
  ];

  bool _listenerChanged(
    double x,
    double y,
    double z,
    double fx,
    double fy,
    double fz,
    double vx,
    double vy,
    double vz,
  ) {
    final now = <double>[x, y, z, fx, fy, fz, vx, vy, vz];
    var changed = _lastListener.length != now.length;
    for (var i = 0; !changed && i < now.length; i++) {
      if ((_lastListener[i] - now[i]).abs() > _listenerEps[i]) changed = true;
    }
    if (changed) {
      _lastListener
        ..clear()
        ..addAll(now);
    }
    return changed;
  }

  /// 全局音量也只在变了才发（理由同 [setListener]：省的是锁，不是 CPU）。
  double? _lastGlobalVolume;

  void setGlobalVolume(double v) {
    final clamped = v.clamp(0.0, 1.0);
    if (_lastGlobalVolume != null &&
        (_lastGlobalVolume! - clamped).abs() < 1e-3) {
      return;
    }
    _lastGlobalVolume = clamped;
    try {
      SoLoud.instance.setGlobalVolume(clamped);
    } catch (e) {
      lastError = '$e';
    }
  }

  /// 读回引擎侧的实测电平（左右声道，**混音后**）。
  ///
  /// # ⚠️ 这个调用会**阻塞**，绝不要放在帧回调里
  ///
  /// `getApproximateVolume` 在 SoLoud 侧是
  /// ```cpp
  /// lockAudioMutex_internal();          // = pthread_mutex_lock(mAudioThreadMutex)
  /// vol = mVisualizationChannelVolume[aChannel];
  /// unlockAudioMutex_internal();
  /// ```
  /// 而 `mAudioThreadMutex` 正被 **CoreAudio 回调里的混音器**持有整段 `mix()`。
  /// 所以：
  ///
  ///   * 混音周期内抢不到锁 → 主线程（渲染 + 输入）被整整挡住一个混音周期；
  ///   * 混音线程重新上锁快于主线程被调度到 → 主线程可以**被饿死很久**。
  ///
  /// 实测抓到过完整证据链：主线程栈停在
  /// `getApproximateVolume → _pthread_mutex_firstfit_lock_wait → __psynch_mutexwait`
  /// 上，而音频线程 1485/1485 个采样点都在 `mix_internal` 里 —— 表现就是
  /// **按键完全不响应、几十秒后才恢复**。
  ///
  /// 于是它被划成"**仅在显式请求时刷新**"的探针（`AudioManager.refreshProbe`），
  /// 结果缓存起来供诊断读，永远不在每帧路径上出现。
  ({double left, double right}) outputLevel() {
    try {
      return (
        left: SoLoud.instance.getApproximateVolume(0),
        right: SoLoud.instance.getApproximateVolume(1),
      );
    } catch (e) {
      lastError = '$e';
      return (left: 0, right: 0);
    }
  }

  int get activeVoices {
    try {
      return SoLoud.instance.getActiveVoiceCount();
    } catch (_) {
      return 0;
    }
  }

  int get engineTimeMs {
    try {
      return SoLoud.instance.getEngineTime().inMilliseconds;
    } catch (_) {
      return 0;
    }
  }

  int positionMs(SoundHandle handle) {
    try {
      return SoLoud.instance.getPosition(handle).inMilliseconds;
    } catch (_) {
      return 0;
    }
  }

  /// 彻底拆除引擎。**只给热重启/强制重播用** —— 它会让主线程停顿几百毫秒，
  /// 绝不能挂在用户手势或每帧路径上（见文件头第 1 条）。
  Future<void> reset() async {
    try {
      if (SoLoud.instance.isInitialized) {
        await SoLoud.instance.deinitAsync();
      }
    } catch (_) {
      // 引擎已经不在了，忽略。
    }
    _sources.clear();
    _ready = false;
    _initializing = false;
  }

  Map<String, Object?> diagnostics() => {
        'ready': _ready,
        'initCount': initCount,
        'initAttempts': _initAttempts,
        'sources': sourceCount,
        'loads': _loadCount,
        'sampleRate': sampleRate,
        'maxVoices': maxVoices,
        'lowLatency': lowLatency,
        if (lastError != null) 'error': lastError,
      };
}
