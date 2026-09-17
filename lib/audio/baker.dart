/// 音频**烘焙**：把"配方"变成可以交给引擎的 WAV 字节。
///
/// ## 为什么必须离开主 isolate
///
/// 程序化合成是有实打实 CPU 成本的（实测：河流 5 档 8 秒 @44.1kHz 约 210ms，
/// 整套环境音约 0.6–1.0s）。放在主 isolate 上跑，就等于让 UI 线程在这段时间里
/// 不处理输入、不重绘 —— 而这正是"进了游戏按键没反应"最经典的成因之一。
///
/// 所以这里做两件事：
///
///   1. **并行**：`compute` 在原生平台会真的起一个 isolate，主线程完全不受影响；
///      Web 上 `compute` 退化为同 isolate 执行（浏览器没有真线程），但那时
///      每片之间仍然 `await` 让出，单次阻塞被限制在一片的量级；
///   2. **分片**：任务是**逐个**提交的（一次一个变体），而不是"一把算完"。
///      于是即便在最坏情况下（Web），最长的一次阻塞也是"一条循环"（约 40–90ms），
///      而不是整个库。
///
/// ## 任务为什么是纯数据
///
/// [BakeJob] 只装 String/int，且 [runBakeJob] 是**顶层函数** —— 这两条是
/// `compute` 的硬要求（跨 isolate 传的是拷贝，闭包捕获的对象树不一定可送）。
/// 把配方按 id 注册在 [ambienceRecipes] 里的另一个好处是：加一层新的环境音
/// 只需要在这里加一行，调度侧完全不用改。
library;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'recipe.dart';
import 'synth/oneshot.dart';
import 'synth/river.dart';
import 'synth/weather.dart';

/// 全部环境音层的配方注册表。
///
/// 加一层新的环境音 = 写一个 [AmbienceRecipe] + 在这里加一行。
/// 播放侧（`ambience.dart`）与调度侧（本文件）都只认这个表。
const Map<String, AmbienceRecipe> ambienceRecipes = {
  'river': RiverAmbienceRecipe(),
  'rain': RainAmbienceRecipe(),
  'wind': WindAmbienceRecipe(),
  'night': NightAmbienceRecipe(),
};

/// 一次性音效的清单。[variants] 是变体条数。
///
/// 为什么脚步要 4 条变体：连续几步如果放的是同一段波形，耳朵会立刻听出
/// "在重复"——比"没有脚步声"更假。轮换几条不同随机种子的波形就够了。
enum SfxId {
  splash('splash', 1),
  stepGrass('step_grass', 4),
  stepSoil('step_soil', 3),
  stepWater('step_water', 3),
  jump('jump', 1),
  land('land', 1),
  pickup('pickup', 1),
  ui('ui', 1),
  fanfare('fanfare', 1);

  const SfxId(this.asset, this.variants);

  /// 资源名前缀。
  final String asset;

  /// 需要预烘焙几条变体（轮换用）。
  final int variants;

  /// 变体 [i] 在引擎里的资源名。
  String variantName(int i) => variants <= 1 ? asset : '${asset}_$i';
}

/// 一个烘焙任务：**纯数据**，可以跨 isolate 传输。
class BakeJob {
  const BakeJob({
    required this.kind,
    required this.name,
    required this.variant,
    required this.sampleRate,
    required this.seed,
  });

  /// `ambience` 或 `sfx`。
  final String kind;

  /// 环境音层的 id，或一次性音效的 [SfxId.asset]。
  final String name;

  /// 变体 / 档索引。
  final int variant;

  final int sampleRate;

  /// 随机种子：换个种子就换一段"同参数不同细节"的波形。
  final int seed;

  /// 引擎里的资源名（同时用作诊断键）。
  String get assetName => kind == 'sfx'
      ? SfxId.values.firstWhere((s) => s.asset == name).variantName(variant)
      : ambienceAsset(name, variant);
}

/// 顶层烘焙函数（`compute` 要求）。返回单声道 PCM，样本范围 [-1, 1]。
Float64List runBakeJob(BakeJob job) {
  if (job.kind == 'sfx') {
    final id = SfxId.values.firstWhere((s) => s.asset == job.name);
    return bakeSfx(id, job.variant, job.sampleRate, seed: job.seed);
  }
  final recipe = ambienceRecipes[job.name]!;
  return recipe.bake(job.variant, job.sampleRate, job.seed);
}

/// 合成一条一次性音效。[variant] 只影响种子/变体选择。
///
/// [impact] 类参数（落地力度）不进烘焙：那是**播放时**的增益/音高，
/// 烘焙变体只负责"音色"。这避免为每种力度各烘一条。
Float64List bakeSfx(SfxId id, int variant, int sampleRate, {int seed = 1337}) {
  final s = seed + variant * 7919;
  switch (id) {
    case SfxId.splash:
      return splashPcm(size: 0.32, sampleRate: sampleRate, seed: s);
    case SfxId.stepGrass:
      return footstepPcm(
          surface: StepSurface.grass, variant: variant, sampleRate: sampleRate, seed: s);
    case SfxId.stepSoil:
      return footstepPcm(
          surface: StepSurface.soil, variant: variant, sampleRate: sampleRate, seed: s);
    case SfxId.stepWater:
      return footstepPcm(
          surface: StepSurface.water, variant: variant, sampleRate: sampleRate, seed: s);
    case SfxId.jump:
      return jumpPcm(sampleRate: sampleRate, seed: s);
    case SfxId.land:
      return landPcm(impact: 0.8, sampleRate: sampleRate, seed: s);
    case SfxId.pickup:
      return pickupPcm(sampleRate: sampleRate, seed: s);
    case SfxId.ui:
      return uiPcm(sampleRate: sampleRate, seed: s);
    case SfxId.fanfare:
      return fanfarePcm(sampleRate: sampleRate, seed: s);
  }
}

/// 该跑的全部烘焙任务（环境音在前：它们要先出声）。
List<BakeJob> allBakeJobs({
  required int sampleRate,
  int seed = 5150,
}) {
  final jobs = <BakeJob>[];
  for (final entry in ambienceRecipes.entries) {
    for (var i = 0; i < entry.value.variantCount; i++) {
      jobs.add(BakeJob(
        kind: 'ambience',
        name: entry.key,
        variant: i,
        sampleRate: sampleRate,
        seed: seed + i * 7717 + entry.key.hashCode.abs() % 997,
      ));
    }
  }
  for (final id in SfxId.values) {
    for (var i = 0; i < id.variants; i++) {
      jobs.add(BakeJob(
        kind: 'sfx',
        name: id.asset,
        variant: i,
        sampleRate: sampleRate,
        seed: seed + i * 7919 + id.index * 131,
      ));
    }
  }
  return jobs;
}
