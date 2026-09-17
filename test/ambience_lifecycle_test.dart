import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kirby_scene/audio/ambience.dart';
import 'package:kirby_scene/audio/engine.dart';
import 'package:kirby_scene/audio/mix.dart';
import 'package:kirby_scene/audio/synth/weather.dart';

// 只替换设备边界；装配、档位、静音与回收均走真实环境层实现。
class _RecordingEngine extends AudioEngine {
  final active = <SoundHandle>{};
  int loads = 0;
  int nextHandle = 1;
  Completer<void>? loadGate;

  @override
  Future<AudioSource?> load(String assetName, Uint8List wav) async {
    loads++;
    await loadGate?.future;
    // 测试设备替身只需资源身份，不调用原生加载；内部构造限用于此边界。
    // ignore: invalid_use_of_internal_member
    return AudioSource(SoundHash(loads));
  }

  @override
  SoundHandle? playLoop2d(AudioSource src, {double volume = 0}) {
    final handle = SoundHandle(nextHandle++);
    active.add(handle);
    return handle;
  }

  @override
  void fadeVolume(SoundHandle handle, double volume, Duration time) {}

  @override
  Future<void> stop(SoundHandle handle) async {
    active.remove(handle);
  }
}

void main() {
  late _RecordingEngine engine;
  late AmbienceLayerPlayer layer;
  late List<Uint8List> wavs;

  setUp(() {
    engine = _RecordingEngine();
    layer = AmbienceLayerPlayer(
      layer: AmbienceLayer.rain,
      recipe: RainAmbienceRecipe(),
      engine: engine,
      is3d: false,
    );
    wavs = List.generate(layer.recipe.variantCount, (_) => Uint8List(4));
  });

  void advance({double strength = 0.4}) {
    layer.update(1, targetGain: 0.5, strength: strength, busCoefficient: 0.54);
  }

  test('普通静音路径会停止全部受管理声部', () async {
    await layer.prepare(wavs);
    advance();
    expect(engine.active, isNotEmpty);
    layer.setMuted(true);
    for (var i = 0; i < 20; i++) {
      advance();
    }
    expect(layer.isPlaying, isFalse);
    expect(engine.active, isEmpty);
  });

  test('播放后重复装配保留句柄，静音后不留下孤立循环声部', () async {
    await layer.prepare(wavs);
    advance();
    final firstHandles = engine.active.toSet();
    expect(firstHandles, isNotEmpty);
    await layer.prepare(wavs);
    advance();
    layer.setMuted(true);
    for (var i = 0; i < 20; i++) {
      advance();
    }
    expect(layer.isPlaying, isFalse);
    expect(engine.active, isEmpty, reason: '清空句柄不等于停止引擎声部，重复装配不能丢失所有权');
    expect(engine.loads, wavs.length);
  });

  test('并发装配合并为一次，未完成时不发布半成品', () async {
    engine.loadGate = Completer<void>();
    final first = layer.prepare(wavs);
    final second = layer.prepare(wavs);
    expect(layer.isPrepared, isFalse);
    engine.loadGate!.complete();
    await Future.wait([first, second]);
    expect(engine.loads, wavs.length);
    expect(layer.loadedVariants, wavs.length);
    advance();
    await layer.release();
    expect(engine.active, isEmpty);
  });

  test('装配中释放等待装配结束，不残留资源，可重新装配', () async {
    engine.loadGate = Completer<void>();
    final preparing = layer.prepare(wavs);
    final releasing = layer.release();
    engine.loadGate!.complete();
    await Future.wait([preparing, releasing]);
    expect(layer.isPrepared, isFalse);
    expect(layer.loadedVariants, 0);
    expect(engine.active, isEmpty);
    await layer.prepare(wavs);
    advance();
    expect(engine.active, isNotEmpty);
    await layer.release();
    expect(engine.active, isEmpty);
  });
}
