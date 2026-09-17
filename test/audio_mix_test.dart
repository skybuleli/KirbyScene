/// 音频基础设施库的**纯逻辑**测试。
///
/// 这些测试只跑 `dart`（不碰音频设备、不碰 Flutter 引擎），因为这一层刻意做成
/// 了纯函数/纯状态机。每一条都对应一个**被报过的具体故障**：
///
///   * 晴天响雨声 → [AmbienceMix] 的目标音量在 `rainAmount == 0` 时必须恒为 0；
///   * 河流太响 / 平缓的河也像瀑布 → 距离与急缓必须真的影响音量；
///   * 切换天气时音效突变 → 档位淡化必须等功率、层音量必须连续；
///   * 循环接缝"咔"的一声 → 首尾必须连续。
library;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kirby_scene/audio/audio.dart';

void main() {
  group('档位交叉淡化（bandBlend）', () {
    test('等功率：权重平方和恒为 1（淡化中点不塌音量）', () {
      for (var i = 0; i <= 20; i++) {
        final b = bandBlend(i / 20, 5);
        expect(b.wa * b.wa + b.wb * b.wb, closeTo(1.0, 1e-9));
      }
    });

    test('边界处只有一档在响，且整体位置单调上升', () {
      final lo = bandBlend(0, 5);
      expect(lo.a, 0);
      expect(lo.b, 1);
      expect(lo.wa, closeTo(1.0, 1e-9));
      expect(lo.wb, closeTo(0.0, 1e-9));

      final hi = bandBlend(1, 5);
      expect(hi.a, 4);
      expect(hi.b, 4);
      expect(hi.wa, closeTo(1.0, 1e-9));

      // 位置（档号 + 档内插值）必须单调上升。
      double pos(double u) {
        final b = bandBlend(u, 5);
        return b.a + b.fraction;
      }

      var prev = -1.0;
      for (var i = 0; i <= 100; i++) {
        final p = pos(i / 100);
        expect(p, greaterThanOrEqualTo(prev - 1e-9));
        prev = p;
      }
    });

    test('换档是连续的：任一档的权重随强度平滑变化（没有台阶 = 没有"咔"）', () {
      // 注意：单个档的 `wa` 在换档处**会**跳回来（它换成了新低档的权重），
      // 所以"wa 单调"是错的断言。真正要保证的是——把权重展开到"每个档号"之后，
      // 每个档号的权重是连续的。
      const count = 5;
      double weightOf(int band, double u) {
        final b = bandBlend(u, count);
        if (band == b.a) return b.wa;
        if (band == b.b) return b.wb;
        return 0.0;
      }

      const du = 0.001;
      for (var k = 0; k + 1 <= 1000; k++) {
        final u = k / 1000;
        for (var band = 0; band < count; band++) {
          final d = (weightOf(band, u + du) - weightOf(band, u)).abs();
          expect(d, lessThan(0.02),
              reason: '档 $band 在 u=$u 附近跳了 $d（听感上就是一次"咔"）');
        }
      }
    });

    test('单档配方也能用（夜层）', () {
      final b = bandBlend(0.7, 1);
      expect(b.a, 0);
      expect(b.b, 0);
      expect(b.wa, 1.0);
    });
  });

  group('该听到什么（AmbienceMix）—— "晴天不响雨声"的判据', () {
    /// 全部非雨天（以及夜里的雨量）都不可能让雨层出声。
    test('雨量为 0 时雨层目标恒为 0（枚举所有晴天/多云/夜晚组合）', () {
      for (final wind in [0.0, 0.3, 1.0]) {
        for (final night in [0.0, 0.5, 1.0]) {
          for (final intensity in [0.0, 0.5, 1.0]) {
            for (final dist in [0.0, 8.0, 40.0]) {
              final s = AmbienceState(
                rainAmount: 0,
                windAmount: wind,
                nightAmount: night,
                riverIntensity: intensity,
                riverDistance: dist,
              );
              expect(AmbienceMix.targetGain(AmbienceLayer.rain, s), 0.0,
                  reason: 'wind=$wind night=$night i=$intensity d=$dist');
              expect(AmbienceMix.shouldPlay(AmbienceLayer.rain, s), isFalse);
            }
          }
        }
      }
    });

    test('雨量 > 0 时雨层出声，且音量随雨势单调上升', () {
      double gain(double rain) => AmbienceMix.targetGain(
            AmbienceLayer.rain,
            AmbienceState(
              rainAmount: rain,
              windAmount: 0.3,
              nightAmount: 0,
              riverIntensity: 0.3,
              riverDistance: 20,
            ),
          );

      expect(gain(0.0), 0.0);
      expect(gain(0.05), greaterThan(0.0));
      var prev = -1.0;
      for (var i = 1; i <= 10; i++) {
        final g = gain(i / 10);
        expect(g, greaterThan(prev));
        prev = g;
      }
    });

    test('河流：距离越远越轻，且平缓的河明显比急滩轻', () {
      double river(double intensity, double dist) => AmbienceMix.targetGain(
            AmbienceLayer.river,
            AmbienceState(
              rainAmount: 0,
              windAmount: 0,
              nightAmount: 0,
              riverIntensity: intensity,
              riverDistance: dist,
            ),
          );

      var prev = 2.0;
      for (final d in [0.0, 5.0, 12.0, 24.0, 48.0, 96.0]) {
        final g = river(0.5, d);
        expect(g, lessThan(prev));
        prev = g;
      }
      // 半衰尺度 12m：那里应当大约是一半。
      expect(river(0.5, 0) / 2, closeTo(river(0.5, 12), 0.02));

      // "与实际平缓的水流状态相符"：深潭必须比急滩轻得多（不是一样响）。
      final calm = river(0.0, 10);
      final rapids = river(1.0, 10);
      expect(calm / rapids, closeTo(AmbienceMix.calmFloor, 0.02));
      expect(calm / rapids, lessThan(0.4));
    });

    test('掩蔽：下雨掩掉风、且大雨里虫子不叫（自然融合，不是各响各的）', () {
      AmbienceState st(double rain) => AmbienceState(
            rainAmount: rain,
            windAmount: 0.8,
            nightAmount: 1.0,
            riverIntensity: 0.5,
            riverDistance: 10,
          );

      expect(AmbienceMix.targetGain(AmbienceLayer.wind, st(0.0)),
          greaterThan(AmbienceMix.targetGain(AmbienceLayer.wind, st(1.0))));
      expect(AmbienceMix.targetGain(AmbienceLayer.night, st(1.0)),
          lessThan(0.1 * AmbienceMix.targetGain(AmbienceLayer.night, st(0.0))));
      // 雨本身不该被自己掩掉。
      expect(AmbienceMix.targetGain(AmbienceLayer.rain, st(0.5)), greaterThan(0.0));
    });

    test('夜层只在有夜色时出声；风层无风时也留一点底噪', () {
      const day = AmbienceState(
        rainAmount: 0,
        windAmount: 0,
        nightAmount: 0,
        riverIntensity: 0.3,
        riverDistance: 20,
      );
      expect(AmbienceMix.targetGain(AmbienceLayer.night, day), 0.0);
      expect(AmbienceMix.shouldPlay(AmbienceLayer.night, day), isFalse);
      // 完全静音会让场景"死掉"，所以风留底噪。
      expect(AmbienceMix.targetGain(AmbienceLayer.wind, day), greaterThan(0.0));

      const night = AmbienceState(
        rainAmount: 0,
        windAmount: 0,
        nightAmount: 1,
        riverIntensity: 0.3,
        riverDistance: 20,
      );
      expect(AmbienceMix.targetGain(AmbienceLayer.night, night), greaterThan(0.0));
      expect(AmbienceMix.shouldPlay(AmbienceLayer.night, night), isTrue);
    });
  });

  group('音量包络（LayerLevel / BusMix）', () {
    test('淡入淡出是连续的：单帧变化远小于全程，且不会越位', () {
      final lvl = LayerLevel(fadeSeconds: 1.2);
      expect(lvl.value, 0.0);
      final first = () {
        lvl.to(1.0, 1 / 60);
        return lvl.value;
      }();
      expect(first, greaterThan(0.0));
      expect(first, lessThan(0.1), reason: '单帧不该跳一大截（那是"突兀的切入"）');

      // 收敛到目标，且不越过。
      for (var i = 0; i < 400; i++) {
        lvl.to(1.0, 1 / 60);
        expect(lvl.value, lessThanOrEqualTo(1.0 + 1e-9));
      }
      expect(lvl.value, closeTo(1.0, 1e-3));
      expect(lvl.settled(1.0), isTrue);
    });

    test('淡出到静音后 isSilent 为真（可以用来决定"到底要不要占用声部"）', () {
      final lvl = LayerLevel(fadeSeconds: 0.5, value: 1.0);
      for (var i = 0; i < 600; i++) {
        lvl.to(0.0, 1 / 60);
      }
      expect(lvl.isSilent, isTrue);
    });

    test('总线系数 = master × 总线，且总线各自可调、互不影响', () {
      final mix = BusMix(master: 1.0);
      mix.update(1.0); // 让包络走到目标
      expect(mix.coefficient(AudioBus.ambience),
          closeTo(AudioBus.ambience.defaultGain, 1e-6));

      mix.setGain(AudioBus.sfx, 0.2);
      for (var i = 0; i < 200; i++) {
        mix.update(1 / 60);
      }
      expect(mix.coefficient(AudioBus.sfx), closeTo(0.2, 1e-3));
      // 改 sfx 不能动 ambience。
      expect(mix.coefficient(AudioBus.ambience),
          closeTo(AudioBus.ambience.defaultGain, 1e-3));
    });

    test('环境音总线的默认值明显低于音效（"河流太响"的混音阶梯）', () {
      expect(AudioBus.ambience.defaultGain,
          lessThan(AudioBus.sfx.defaultGain));
      expect(BusMix().coefficient(AudioBus.ambience), lessThan(0.6));
    });

    test('淡出必须真正落到 0（指数逼近永远到不了 0，得靠收尾吸附）', () {
      final lvl = LayerLevel(fadeSeconds: 2.4, value: 1.0);
      for (var i = 0; i < 60 * 20; i++) {
        lvl.to(0.0, 1 / 60);
      }
      // 关键：不是"小于某个阈值"，而是**恒等于 0**。
      // 调用方唯一的启停判据是 `target == 0`，差一点点都判不出来。
      expect(lvl.value, 0.0);
      expect(lvl.isSilent, isTrue);
    });

    test('非零目标不会被吸附（吸附只该发生在收尾）', () {
      final lvl = LayerLevel(fadeSeconds: 0.3, value: 0.0004);
      for (var i = 0; i < 600; i++) {
        lvl.to(0.02, 1 / 60);
      }
      expect(lvl.value, closeTo(0.02, 1e-6));
    });
  });

  group('音量下发判据（shouldSend）—— "晴天还挂着雨声"的判据', () {
    test('归零必须发一次（旧的绝对阈值会把它漏掉）', () {
      // 这正是实测卡住的那一步：目标已经变成 0，而 `_applied` 停在 0.004 上，
      // `|0 - 0.004| > 0.004` 为**假** → 最后那次"归零"永远发不出去，
      // 引擎侧音量就永远停在 0.004、声部永不释放。
      expect(AmbienceLayerPlayer.shouldSend(0.0, 0.004), isTrue);
      expect(AmbienceLayerPlayer.shouldSend(0.0, 1e-9), isTrue);
    });

    test('已经发过 0 就不再重复发（否则每帧都重开一次淡变）', () {
      expect(AmbienceLayerPlayer.shouldSend(0.0, 0.0), isFalse);
    });

    test('没变就不发（省的是音频锁，不只是 CPU）', () {
      expect(AmbienceLayerPlayer.shouldSend(0.5, 0.5), isFalse);
      expect(AmbienceLayerPlayer.shouldSend(0.5, 0.5005), isFalse);
    });

    test('相对判据在低音量段仍然分得清（绝对阈值在这里是瞎的）', () {
      // 0.001 → 0.002 的绝对差只有 0.001，低于旧阈值 0.004 ——
      // 低音量段的音量变化会被整个吃掉，听感上就是"淡出到一半就冻住"。
      expect(AmbienceLayerPlayer.shouldSend(0.002, 0.001), isTrue);
      expect(AmbienceLayerPlayer.shouldSend(0.9, 0.5), isTrue);
    });

    test('一层淡出后能真正抵达"目标 0 且已发 0"（声部释放的前提）', () {
      // 把两段逻辑（包络 + 下发判据）串成一条链跑一遍：这条链曾经断在中间，
      // 于是"不再参与交叉淡化的档"永远不会被释放（晴天也挂着一层雨）。
      // 单档时 bus × weight 都是 1，所以 target 就等于 level.value。
      final level = LayerLevel(fadeSeconds: 2.4, value: 1.0);
      var applied = 1.0;
      var steps = 0;
      var released = false;
      while (steps++ < 60 * 30) {
        level.to(0.0, 1 / 60);
        if (AmbienceLayerPlayer.shouldSend(level.value, applied)) {
          applied = level.value;
        }
        if (level.value == 0 && applied == 0) {
          released = true;
          break;
        }
      }
      expect(released, isTrue, reason: '淡出必须在有限时间内真正结束并归还声部');
      expect(steps, lessThan(60 * 30));
    });
  });

  group('声部归还判据（shouldRelease）—— "切回晴天雨层还在播"的判据', () {
    test('音量真的到 0 了就归还声部', () {
      expect(AmbienceLayerPlayer.shouldRelease(target: 0, applied: 0), isTrue);
    });

    test('还没淡完不能归还', () {
      expect(AmbienceLayerPlayer.shouldRelease(target: 0, applied: 0.004),
          isFalse);
      expect(AmbienceLayerPlayer.shouldRelease(target: 0.2, applied: 0.2),
          isFalse);
    });

    test('只有两档的层：交叉淡化的两档就是全部档位（旧判据在这里恒为假）', () {
      // 上一版判据里加了一个 `!active.contains(i)`，而 `active` 就是
      // 交叉淡化的两档。雨/风/夜只有 2 档，于是它恒等于 `{0,1}`、
      // “不在淡化的两档里”**永远不成立** ⇒ 声部永不归还。
      // 只有 5 档的河会真正释放用不到的那 3 档 —— 所以之前只有雨/风/夜漏。
      for (var i = 0; i <= 20; i++) {
        final b = bandBlend(i / 20, 2);
        // 两档时 a/b 只会落在 0..1，也就是**覆盖了全部档位**。
        expect(b.a, inInclusiveRange(0, 1));
        expect(b.b, inInclusiveRange(0, 1));
      }
      // 反过来：档位多于两档时，一定有档位不在淡化里。
      final b = bandBlend(0.0, 5);
      expect({b.a, b.b}.length, lessThan(5));
    });
  });

  group('一次性音效的闸门（SfxPlayer.admit）—— "晴天的滴滴答答"的判据', () {
    test('未装载一律不放（并会被计入 dropped）', () {
      final v = SfxPlayer.admit(
        id: SfxId.splash,
        loaded: false,
        distance: 1,
        gain: 1,
      );
      expect(v.allowed, isFalse);
      expect(v.reason, 'notLoaded');
    });

    test('水花有并不可忽略的最小间隔 —— 这是"每秒约 3 声"那个 bug 的回归护栏', () {
      final gap = SfxPlayer.minInterval[SfxId.splash]!;
      expect(gap, greaterThanOrEqualTo(1.0),
          reason: '上一版没有间隔闸门，实测 2.95 声/秒，玩家听成了雨声');

      // 间隔之内一律丢弃。
      final soon = SfxPlayer.admit(
        id: SfxId.splash,
        loaded: true,
        distance: 2,
        gain: 0.6,
        gap: gap,
        sinceLast: gap * 0.5,
      );
      expect(soon.allowed, isFalse);
      expect(soon.reason, 'tooSoon');

      // 间隔之后放行。
      final ok = SfxPlayer.admit(
        id: SfxId.splash,
        loaded: true,
        distance: 2,
        gain: 0.6,
        gap: gap,
        sinceLast: gap * 1.1,
      );
      expect(ok.allowed, isTrue);
      expect(ok.gain, greaterThan(0.0));
    });

    test('超过可闻距离整声丢弃，且距离衰减单调', () {
      final far = SfxPlayer.admit(
        id: SfxId.splash,
        loaded: true,
        distance: 200,
        gain: 0.6,
        gap: 0,
        sinceLast: 99,
      );
      expect(far.allowed, isFalse);
      expect(far.reason, 'tooFar');

      var prev = 1.1;
      for (final d in [0.0, 5.0, 16.0, 32.0, 47.0]) {
        final v = SfxPlayer.admit(
          id: SfxId.splash,
          loaded: true,
          distance: d,
          gain: 1.0,
          gap: 0,
          sinceLast: 99,
        );
        expect(v.gain, lessThan(prev));
        prev = v.gain;
      }
      expect(SfxPlayer.distanceGain(0), closeTo(1.0, 1e-9));
      expect(SfxPlayer.distanceGain(16), closeTo(0.5, 0.02));
    });

    test('脚步这类原位声不设距离上限（否则跑到地图边就没脚步声了）', () {
      for (final id in [SfxId.stepGrass, SfxId.stepSoil, SfxId.stepWater]) {
        final v = SfxPlayer.admit(
          id: id,
          loaded: true,
          distance: 500,
          gain: 0.5,
          gap: 0,
          sinceLast: 99,
        );
        expect(v.allowed, isTrue, reason: '$id 不该被距离闸门拦掉');
      }
    });
  });

  group('环境音配方的无缝循环（雨 / 风 / 夜）', () {
    /// 接缝处的跳变必须与波形内部的跳变同量级，否则循环到接缝处会"咔"一声。
    void expectSeamless(String id, AmbienceRecipe recipe, int variant) {
      final pcm = recipe.bake(variant, 22050, 1234);
      expect(pcm.length, greaterThan(1000));

      var maxInner = 0.0, sum = 0.0;
      for (var i = 1; i < pcm.length; i++) {
        final d = (pcm[i] - pcm[i - 1]).abs();
        if (d > maxInner) maxInner = d;
        sum += d;
      }
      final meanInner = sum / (pcm.length - 1);
      final seam = (pcm.first - pcm.last).abs();

      expect(seam, lessThan(math.max(meanInner * 8, maxInner)),
          reason: '$id 变体 $variant 的接缝跳变 $seam 相对内部跳变过大');
    }

    test('雨 / 风 / 夜三条循环的首尾都是连续的', () {
      for (var i = 0; i < const RainAmbienceRecipe().variantCount; i++) {
        expectSeamless('rain', const RainAmbienceRecipe(), i);
      }
      for (var i = 0; i < const WindAmbienceRecipe().variantCount; i++) {
        expectSeamless('wind', const WindAmbienceRecipe(), i);
      }
      expectSeamless('night', const NightAmbienceRecipe(), 0);
    });

    test('雨：雨势越大越往下沉（低频体量上升），且不是静音', () {
      const recipe = RainAmbienceRecipe();
      final light = recipe.bake(0, 22050, 7);
      final heavy = recipe.bake(recipe.variantCount - 1, 22050, 7);

      expect(rmsOf(light), greaterThan(0.01));
      expect(rmsOf(heavy), greaterThan(0.01));

      // 用一阶低通代理"低频能量"：大雨的低频占比必须更高。
      double lowBand(Float64List b) {
        var lp = 0.0, acc = 0.0;
        final a = onePoleAlpha(300, 22050);
        for (final v in b) {
          lp += (v - lp) * a;
          acc += lp * lp;
        }
        return math.sqrt(acc / b.length);
      }

      expect(lowBand(heavy) / rmsOf(heavy),
          greaterThan(lowBand(light) / rmsOf(light)));
    });

    test('雨不是"稀疏的水滴"：颗粒密度远高于人耳能分辨单次事件的速率', () {
      // 判据用"波形的包络起伏"代理：稀疏水滴会产生大量接近静音的间隙。
      // 这里断言"接近静音的样本占比很低" —— 致密颗粒会融成连续的雨幕。
      final pcm = const RainAmbienceRecipe().bake(0, 22050, 7);
      final peak = peakOf(pcm);
      var quiet = 0;
      for (final v in pcm) {
        if (v.abs() < peak * 0.05) quiet++;
      }
      expect(quiet / pcm.length, lessThan(0.35),
          reason: '大段近静音说明它是稀疏水滴（会被听成漏水的水龙头），不是雨');
    });

    test('风：阵性来自包络，不是恒定噪声（幅度的起伏必须明显）', () {
      final pcm = const WindAmbienceRecipe().bake(2, 22050, 9);
      // 分窗统计 RMS 的离散度：阵风应当造成窗口间明显的强弱差。
      const win = 2205;
      final levels = <double>[];
      for (var s = 0; s + win <= pcm.length; s += win) {
        var acc = 0.0;
        for (var i = s; i < s + win; i++) {
          acc += pcm[i] * pcm[i];
        }
        levels.add(math.sqrt(acc / win));
      }
      final mean = levels.reduce((a, b) => a + b) / levels.length;
      final spread =
          levels.map((v) => (v - mean).abs()).reduce((a, b) => a + b) / levels.length;
      expect(spread / mean, greaterThan(0.12),
          reason: '恒定噪声没有阵性，听上去不像风');
    });
  });

  group('烘焙任务目录', () {
    test('覆盖全部环境音层与全部一次性音效，且资源名不重复', () {
      final jobs = allBakeJobs(sampleRate: 22050);
      final names = jobs.map((j) => j.assetName).toList();
      expect(names.toSet().length, names.length, reason: '资源名重复会互相覆盖');

      for (final id in SfxId.values) {
        for (var i = 0; i < id.variants; i++) {
          expect(names, contains(id.variantName(i)));
        }
      }
      for (final entry in ambienceRecipes.entries) {
        for (var i = 0; i < entry.value.variantCount; i++) {
          expect(names, contains(ambienceAsset(entry.key, i)));
        }
      }
    });

    test('runBakeJob 是纯的：同一任务两次得到完全一样的波形', () {
      final job = allBakeJobs(sampleRate: 22050).firstWhere(
        (j) => j.assetName == 'night_0',
      );
      final a = runBakeJob(job);
      final b = runBakeJob(job);
      expect(a.length, b.length);
      for (var i = 0; i < a.length; i += 97) {
        expect(a[i], b[i]);
      }
    });

    test('脚步有多条变体（放同一条会被听出"在重复"）', () {
      expect(SfxId.stepGrass.variants, greaterThanOrEqualTo(3));
      final a = bakeSfx(SfxId.stepGrass, 0, 22050);
      final b = bakeSfx(SfxId.stepGrass, 1, 22050);
      expect(a.length, b.length);
      var diff = 0;
      for (var i = 0; i < a.length; i++) {
        if ((a[i] - b[i]).abs() > 1e-6) diff++;
      }
      expect(diff, greaterThan(a.length ~/ 2), reason: '变体之间必须真的不同');
    });
  });

  group('WAV 编码（雨/风/夜也要能被引擎读）', () {
    test('头字段自洽，样本数正确', () {
      final pcm =
          Float64List.fromList(List<double>.generate(500, (i) => i / 500));
      final wav = encodeWav16(pcm, sampleRate: 44100);
      final view = ByteData.view(wav.buffer);
      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
      expect(view.getUint16(22, Endian.little), 1, reason: '单声道');
      expect(view.getUint32(24, Endian.little), 44100);
      expect(view.getUint16(34, Endian.little), 16, reason: '16 位');
      expect(view.getUint32(40, Endian.little), 500 * 2);
      expect(wav.length, 44 + 500 * 2);
    });
  });
}
