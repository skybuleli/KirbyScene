/// 水流音效**合成器**的纯逻辑测试。
///
/// 这里能测是因为 `river_sound.dart` 不碰音频设备、不碰 Flutter：波形就是一段
/// `Float64List`。要在 CI / 无扬声器的机器上验证"这声音对不对"，只能靠这类
/// 可断言的客观量 —— 所以下面测的每一条都对应一个**听感上的具体故障**：
///
///   * 采样率/位深写错 → 播放器放出来是噪声或静音；
///   * 接缝不连续 → 循环到接缝处"咔哒"一声（overlap-add 没做对就是这个症状）；
///   * 湍流没接进音色 → 急滩与深潭听上去一模一样；
///   * 样本削顶 → 爆音。
library;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kirby_scene/audio/synth/river.dart';

/// 读 WAV 头里的一个 32 位小端字段。
int _u32(Uint8List bytes, int offset) =>
    ByteData.view(bytes.buffer, bytes.offsetInBytes).getUint32(offset, Endian.little);

int _u16(Uint8List bytes, int offset) =>
    ByteData.view(bytes.buffer, bytes.offsetInBytes).getUint16(offset, Endian.little);

String _ascii(Uint8List bytes, int offset, int length) =>
    String.fromCharCodes(bytes.sublist(offset, offset + length));

/// 一阶差分均值：噪声的"亮度"（高频能量）的廉价度量。
double _meanAbsDiff(Float64List s) {
  var sum = 0.0;
  for (var i = 1; i < s.length; i++) {
    sum += (s[i] - s[i - 1]).abs();
  }
  return sum / (s.length - 1);
}

double _peak(Float64List s) {
  var m = 0.0;
  for (final v in s) {
    final a = v.abs();
    if (a > m) m = a;
  }
  return m;
}

void main() {
  group('WAV 编码', () {
    test('头部字段与数据长度自洽（采样率/声道/位深/块大小）', () {
      final synth = RiverSoundSynth(sampleRate: 22050, seed: 7);
      final pcm = synth.flowLoop(
        const RiverSoundSpec(seconds: 0.5, speed: 0.5, turbulence: 0.4),
      );
      final wav = synth.toWav16(pcm);

      expect(_ascii(wav, 0, 4), 'RIFF');
      expect(_ascii(wav, 8, 4), 'WAVE');
      expect(_ascii(wav, 12, 4), 'fmt ');
      expect(_ascii(wav, 36, 4), 'data');

      expect(_u32(wav, 16), 16, reason: 'fmt 块长度');
      expect(_u16(wav, 20), 1, reason: '必须是 PCM');
      expect(_u16(wav, 22), 1, reason: '单声道');
      expect(_u32(wav, 24), 22050, reason: '采样率');
      expect(_u32(wav, 28), 22050 * 2, reason: '字节率 = 采样率 × 块对齐');
      expect(_u16(wav, 32), 2, reason: '块对齐 = 声道数 × 位深/8');
      expect(_u16(wav, 34), 16, reason: '位深');

      expect(_u32(wav, 40), pcm.length * 2, reason: 'data 块声明长度');
      expect(wav.length, 44 + pcm.length * 2, reason: '整文件长度');
      expect(_u32(wav, 4), 36 + pcm.length * 2, reason: 'RIFF 块长度');
    });

    test('样本落在 16 位范围内且不是静音', () {
      final synth = RiverSoundSynth(seed: 11);
      final wav = synth.toWav16(synth.flowLoop(
        const RiverSoundSpec(seconds: 0.4, speed: 0.6, turbulence: 0.5),
      ));
      final view = ByteData.view(wav.buffer, wav.offsetInBytes);

      var maxAbs = 0;
      var nonZero = 0;
      for (var i = 44; i < wav.length; i += 2) {
        final v = view.getInt16(i, Endian.little);
        if (v != 0) nonZero++;
        final a = v.abs();
        if (a > maxAbs) maxAbs = a;
      }
      expect(maxAbs, inInclusiveRange(1, 32767), reason: '削顶或全静音');
      expect(maxAbs, greaterThan(32767 * 0.5), reason: '归一化没生效，声音太小');
      expect(nonZero / ((wav.length - 44) / 2), greaterThan(0.95),
          reason: '大面积静音说明合成参数把信号压死了');
    });
  });

  group('循环接缝', () {
    test('首尾连续：接缝处的跳变与波形内部跳变同量级', () {
      final synth = RiverSoundSynth(seed: 23);
      final pcm = synth.flowLoop(
        const RiverSoundSpec(seconds: 0.8, speed: 0.5, turbulence: 0.5),
      );

      final seam = (pcm[0] - pcm[pcm.length - 1]).abs();
      final internal = _meanAbsDiff(pcm);

      // 没做 overlap-add 时，接缝处是"两种滤波器瞬态"的硬碰，
      // 跳变会是内部平均跳变的几十倍，听感上就是一声"咔"。
      expect(seam, lessThan(internal * 8.0),
          reason: '接缝跳变 $seam 远大于内部平均跳变 $internal');
    });

    test('首尾响度连续 —— 调制包络没有在循环边界重置', () {
      // 这是"断断续续"的客观判据：波形被 overlap-add 接好了，但如果叠加的
      // 振幅起伏频率不是"循环长度的整数个周期"，包络就会在每次循环时跳一下，
      // 听感上是一波一波地重启（实机反馈过）。
      final synth = RiverSoundSynth(seed: 77);
      final pcm = synth.flowLoop(
        const RiverSoundSpec(seconds: 4.0, speed: 0.5, turbulence: 0.4),
      );

      const window = 3300; // ≈0.15s，足够平均掉噪声的随机起伏
      double rms(int from) {
        var sum = 0.0;
        for (var i = from; i < from + window; i++) {
          sum += pcm[i] * pcm[i];
        }
        return math.sqrt(sum / window);
      }

      final head = rms(0);
      final tail = rms(pcm.length - window);
      final relDiff = (head - tail).abs() / math.max(head, tail);
      expect(relDiff, lessThan(0.25),
          reason: '首($head)尾($tail)响度差 ${(relDiff * 100).toStringAsFixed(0)}%，'
              '循环处会听出"起伏重置"');
    });

    test('首段不是被淡化成静音（overlap-add 没有把开头压扁）', () {
      final synth = RiverSoundSynth(seed: 31);
      final pcm = synth.flowLoop(
        const RiverSoundSpec(seconds: 0.8, speed: 0.5, turbulence: 0.3),
      );
      // 取开头 5% 与中段 5% 比能量：淡化只该改变混合比例，不该改变量级。
      final head = pcm.sublist(0, (pcm.length * 0.05).round());
      final mid = pcm.sublist(
        (pcm.length * 0.45).round(),
        (pcm.length * 0.50).round(),
      );
      double rms(Float64List s) {
        var sum = 0.0;
        for (final v in s) {
          sum += v * v;
        }
        return (sum / s.length);
      }

      final ratio = rms(mid) / (rms(head) + 1e-12);
      expect(ratio, lessThan(4.0), reason: '开头能量与中段差了 ${ratio}x');
    });
  });

  group('参数确实接进了音色', () {
    test('湍流越大，高频越亮（急滩听上去更"嘶"）', () {
      // 同 seed：噪声底完全一样，唯一的差别就是湍流参数 ——
      // 于是这个对比测的是"参数有没有真的进入合成"，而不是随机性。
      final calm = RiverSoundSynth(seed: 44).flowLoop(
        const RiverSoundSpec(seconds: 0.8, speed: 0.5, turbulence: 0.0),
      );
      final rough = RiverSoundSynth(seed: 44).flowLoop(
        const RiverSoundSpec(seconds: 0.8, speed: 0.5, turbulence: 1.0),
      );

      expect(_meanAbsDiff(rough), greaterThan(_meanAbsDiff(calm) * 1.2),
          reason: '湍流没有改变亮度，急滩与深潭会听成同一种水');
    });

    test('同 seed 同参数完全可复现，不同 seed 不同', () {
      const spec = RiverSoundSpec(seconds: 0.3, speed: 0.4, turbulence: 0.6);
      final a = RiverSoundSynth(seed: 5).flowLoop(spec);
      final b = RiverSoundSynth(seed: 5).flowLoop(spec);
      final c = RiverSoundSynth(seed: 6).flowLoop(spec);

      expect(a.length, b.length);
      for (var i = 0; i < a.length; i++) {
        expect(a[i], b[i], reason: '第 $i 个样本不稳定 —— 同 seed 必须逐位相同');
      }
      var differing = 0;
      for (var i = 0; i < a.length; i++) {
        if ((a[i] - c[i]).abs() > 1e-9) differing++;
      }
      expect(differing, greaterThan(a.length ~/ 2), reason: '换 seed 应当换一条河');
    });

    test('合成耗时可控（起播前一次性合成，不能卡住主线程）', () {
      final synth = RiverSoundSynth(seed: 9);
      final sw = Stopwatch()..start();
      synth.flowLoop(
        const RiverSoundSpec(seconds: 5.0, speed: 0.5, turbulence: 0.5),
      );
      sw.stop();
      // 真人游戏里这一下发生在加载/首帧，200ms 以内感知不到。
      // 放宽到 600ms 是给 CI 上的慢机器留余量（这不是性能基准，是防呆）。
      expect(sw.elapsedMilliseconds, lessThan(600));
    });
  });

  group('水花声', () {
    test('有起音、有衰减，且长度正确', () {
      final synth = RiverSoundSynth(seed: 2);
      final pcm = synth.splash(size: 0.6, seconds: 0.4);

      expect(pcm.length, (0.4 * synth.sampleRate).round());
      expect(pcm[0].abs(), lessThan(0.02), reason: '起音不该是爆音');

      const window = 400;
      final headPeak = _peak(Float64List.sublistView(pcm, 0, window));
      final tailPeak =
          _peak(Float64List.sublistView(pcm, pcm.length - window, pcm.length));
      expect(headPeak, greaterThan(0.3), reason: '水花必须响');
      expect(tailPeak, lessThan(headPeak * 0.5), reason: '没有衰减，听起来像持续噪声');
    });

    test('大鱼的水花更长（衰减更慢）', () {
      final small = RiverSoundSynth(seed: 3).splash(size: 0.25, seconds: 0.5);
      final big = RiverSoundSynth(seed: 3).splash(size: 1.0, seconds: 0.5);
      // 用"后半段能量占比"衡量衰减速度，避开展幅归一化带来的干扰。
      double energy(Float64List s, int from, int to) {
        var sum = 0.0;
        for (var i = from; i < to; i++) {
          sum += s[i] * s[i];
        }
        return sum;
      }

      final half = small.length ~/ 2;
      final smallRatio = energy(small, half, small.length) /
          (energy(small, 0, half) + 1e-12);
      final bigRatio =
          energy(big, half, big.length) / (energy(big, 0, half) + 1e-12);
      expect(bigRatio, greaterThan(smallRatio));
    });
  });

  group('音色档（RiverSoundMix）', () {
    RiverSoundMix mix({double speed = 0.5, double turb = 0.2}) =>
        RiverSoundMix.evaluate(
          distanceToRiver: 8.0,
          sectionSpeed: speed,
          meanSpeed: 0.5,
          sectionTurbulence: turb,
        );

    test('越急的河段落在越高的档（单调）', () {
      final calm = mix(speed: 0.10, turb: 0.0);
      final mid = mix(speed: 0.5, turb: 0.4);
      final rapids = mix(speed: 1.0, turb: 1.0);

      expect(calm.intensity, lessThan(mid.intensity));
      expect(mid.intensity, lessThan(rapids.intensity));
      expect(calm.intensity, lessThan(0.15), reason: '深潭应该几乎不含白水档');
      expect(rapids.intensity, greaterThan(0.85), reason: '急滩应该顶到最高档');
    });

    test('湍流对"有多急"的影响大于流速（白水才是听觉上的"急"）', () {
      final fastCalmWater = mix(speed: 1.0, turb: 0.0);
      final slowWhiteWater = mix(speed: 0.5, turb: 1.0);
      expect(slowWhiteWater.intensity, greaterThan(fastCalmWater.intensity),
          reason: '深潭里的急流不该比浅滩白水听起来更激');
    });

    test('等功率交叉淡化：权重平方和恒为 1（淡化过程中不塌音量）', () {
      for (var i = 0; i <= 200; i++) {
        final u = i / 200;
        final m = mix(speed: 0.06 + 0.94 * u, turb: u);
        final power = m.weightA * m.weightA + m.weightB * m.weightB;
        expect(power, closeTo(1.0, 1e-9), reason: 'u=$u 处功率为 $power');
        expect(m.weightA, greaterThanOrEqualTo(0.0));
        expect(m.weightB, greaterThanOrEqualTo(0.0));
        expect(m.bandB, greaterThanOrEqualTo(m.bandA));
        expect(m.bandA, inInclusiveRange(0, RiverSoundMix.bandCount - 1));
        expect(m.bandB, inInclusiveRange(0, RiverSoundMix.bandCount - 1));
      }
    });

    test('档位切换连续 —— 旧档权重先降到 0 才换档（没台阶）', () {
      // 这是"音色随流速连续变化"的客观判据：档号是整数、必然跳变，
      // 但只要跳变发生在**旧档权重已接近 0** 的时刻，听感上就是连续的。
      var last = mix(speed: 0.0, turb: 0.0);
      for (var i = 1; i <= 400; i++) {
        final u = i / 400;
        final m = mix(speed: 0.06 + 0.94 * u, turb: u);
        if (m.bandA != last.bandA) {
          expect(last.weightA, lessThan(0.08),
              reason: '换档时旧档权重还有 ${last.weightA} —— 会听出"咔一下"');
          expect(m.bandA, last.bandA + 1, reason: '档号不该跳着走');
        }
        last = m;
      }
    });

    test('相邻两档真的换了音色，而且越高的档越"嘶"', () {
      // 这条是整个改造的关键验收：如果各档音色差不多，那"随流速变化"就
      // 只是变了个音量。同 seed 逐档对比亮度（高频能量）的低廉度量。
      var previous = 0.0;
      for (var i = 0; i < RiverSoundMix.bandCount; i++) {
        final pcm = RiverSoundSynth(seed: 44).flowLoop(
          RiverSoundMix.bandSpec(i).copyWith(seconds: 1.2),
        );
        final brightness = _meanAbsDiff(pcm);
        if (i > 0) {
          expect(brightness, greaterThan(previous),
              reason: '第 $i 档不比第 ${i - 1} 档更亮 —— 急滩与深潭会听成同一种水');
        }
        previous = brightness;
      }
      // 最低档与最高档的差距要"听得出来"，不能只是统计上更大。
      final calm = _meanAbsDiff(RiverSoundSynth(seed: 44).flowLoop(
        RiverSoundMix.bandSpec(0).copyWith(seconds: 1.2),
      ));
      final rapids = _meanAbsDiff(RiverSoundSynth(seed: 44).flowLoop(
        RiverSoundMix.bandSpec(RiverSoundMix.bandCount - 1).copyWith(seconds: 1.2),
      ));
      expect(rapids, greaterThan(calm * 1.5), reason: '两端档的音色差太小');
    });

    test('速率只做细调：范围窄且单调（音色已承担主要表达）', () {
      final slow = mix(speed: 0.10);
      final fast = mix(speed: 1.0);
      expect(fast.playbackRate, greaterThan(slow.playbackRate));
      expect(slow.playbackRate, greaterThanOrEqualTo(0.90));
      expect(fast.playbackRate, lessThanOrEqualTo(1.14));
      expect(fast.playbackRate - slow.playbackRate, lessThan(0.25),
          reason: '速率幅度太大，会听出"播放器在变速"');
    });

    test('档位合成参数：深潭无白水、急滩拉满，且单调', () {
      final calm = RiverSoundMix.bandSpec(0);
      final rapids = RiverSoundMix.bandSpec(RiverSoundMix.bandCount - 1);
      expect(calm.turbulence, lessThan(0.02), reason: '深潭不该有白花花的噪声');
      expect(rapids.turbulence, closeTo(1.0, 0.02));
      expect(rapids.speed, greaterThan(calm.speed));

      for (var i = 1; i < RiverSoundMix.bandCount; i++) {
        expect(RiverSoundMix.bandSpec(i).turbulence,
            greaterThan(RiverSoundMix.bandSpec(i - 1).turbulence));
        expect(RiverSoundMix.bandSpec(i).speed,
            greaterThan(RiverSoundMix.bandSpec(i - 1).speed));
      }
    });

    test('整组档位烘焙耗时可控（起播前一次性算完，不能卡住主线程）', () {
      final synth = RiverSoundSynth(seed: 13);
      final sw = Stopwatch()..start();
      for (var i = 0; i < RiverSoundMix.bandCount; i++) {
        synth.flowLoop(RiverSoundMix.bandSpec(i));
      }
      sw.stop();
      // 5 条 × 8s × 44.1kHz。放宽到 4s 是给 CI 上的慢机器留余量
      //（这不是性能基准，是防呆：万一有人把档数或循环长度调爆）。
      expect(sw.elapsedMilliseconds, lessThan(4000));
    });
  });
}
