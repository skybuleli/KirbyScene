/// KirbyScene 的**音频基础设施库**。
///
/// 游戏侧只需要 `import '../audio/audio.dart';`，再认识 [AudioManager] 一个类。
///
/// ## 分层
///
/// | 文件 | 职责 | 依赖 |
/// |---|---|---|
/// | `pcm.dart` | 程序化 PCM 的公共原语（噪声、滤波、无缝循环、WAV 编码） | 无 |
/// | `recipe.dart` | 环境音"配方"接口 + 等功率档位淡化 | `pcm.dart` |
/// | `synth/*.dart` | 具体波形：河流 / 雨 / 风 / 夜 / 一次性音效 | `pcm.dart` |
/// | `mix.dart` | 总线电平 + "什么天气该听到什么"（**纯函数**） | 无 |
/// | `engine.dart` | SoLoud 封装：设备生命周期、音源、声部、诊断 | `flutter_soloud` |
/// | `ambience.dart` | 一层环境音的运行时：交叉淡化、淡入淡出、声部预算 | `engine`, `mix` |
/// | `sfx.dart` | 一次性音效：三重闸门（间隔 / 距离 / 音量）+ 变体轮换 | `engine` |
/// | `baker.dart` | 烘焙任务目录 + 离开主 isolate 的合成调度 | `flutter/foundation` |
/// | `manager.dart` | [AudioManager]：游戏侧唯一门面 | 全部 |
///
/// ## 为什么分这么细
///
/// 因为"音频出问题"的可能位置横跨三层，而每层能用的证据完全不同：
///
///   * **波形不对**（急促的河和缓的河听起来一样）→ 纯函数，单测断言频谱；
///   * **该响的没响 / 不该响的响了**（晴天响雨声）→ 纯函数
///     （`AmbienceMix.targetGain`），单测枚举全部天气组合；
///   * **响了但听感不对**（太响、位置不对、断断续续）→ 引擎侧读回的实测量
///     （`tool/audio_audit.mjs`）。
///
/// 三层各自可断言，就不需要"改一版听一遍"这种没法收敛的循环。
library;

export 'ambience.dart' show AmbienceLayerPlayer;
export 'baker.dart'
    show BakeJob, SfxId, allBakeJobs, ambienceRecipes, bakeSfx, runBakeJob;
export 'engine.dart' show AttenuationModel, AudioEngine;
export 'manager.dart' show AudioListener, AudioManager, WeatherAudio;
export 'mix.dart'
    show AmbienceLayer, AmbienceMix, AmbienceState, AudioBus, BusMix, LayerLevel;
export 'pcm.dart'
    show
        PcmRng,
        encodeWav16,
        equalPower,
        foldTail,
        loopLockedFreq,
        normalizePeak,
        onePoleAlpha,
        onePoleHighPassAlpha,
        peakOf,
        rmsOf,
        seamlessLoop,
        smoothTowards,
        tauForFadeSeconds;
export 'recipe.dart'
    show AmbienceRecipe, BandBlend, ambienceAsset, bandBlend;
export 'sfx.dart' show SfxAdmission, SfxPlayer;
export 'synth/oneshot.dart'
    show
        StepSurface,
        fanfarePcm,
        footstepPcm,
        jumpPcm,
        landPcm,
        pickupPcm,
        splashPcm,
        uiPcm;
export 'synth/river.dart' show RiverAmbienceRecipe, RiverSoundMix, RiverSoundSpec, RiverSoundSynth;
export 'synth/weather.dart'
    show NightAmbienceRecipe, RainAmbienceRecipe, WindAmbienceRecipe;
