/// 纯逻辑测试：噪声与地形。
///
/// 这些是关卡生成的**地基**——如果噪声不确定，地形、草的落点、收集物位置
/// 每次运行都会变，Web 与原生还会不一致（`procedural` skill 警告的那个坑）。
/// 所以这里只测不需要 GPU 的部分，能在 `flutter test` 里直接跑。

library;
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:kirby_scene/game/noise.dart';
import 'package:kirby_scene/game/terrain.dart';

void main() {
  group('ValueNoise 确定性', () {
    test('同一坐标反复采样结果完全一致', () {
      const noise = ValueNoise(seed: 42);
      for (var i = 0; i < 20; i++) {
        final x = i * 1.37 + 0.11;
        final y = i * -2.41 + 5.3;
        expect(noise.value2(x, y), noise.value2(x, y));
        expect(noise.fbm2(x, y), noise.fbm2(x, y));
      }
    });

    test('不同 seed 产出不同的场', () {
      const a = ValueNoise(seed: 1);
      const b = ValueNoise(seed: 2);
      var differences = 0;
      for (var i = 0; i < 50; i++) {
        if ((a.value2(i * 0.7, i * 1.3) - b.value2(i * 0.7, i * 1.3)).abs() > 1e-9) {
          differences++;
        }
      }
      expect(differences, greaterThan(40));
    });

    test('fbm 输出落在 [-1, 1] 内', () {
      const noise = ValueNoise(seed: 7);
      for (var i = 0; i < 300; i++) {
        final x = (i % 20) * 3.1 - 30;
        final y = (i ~/ 20) * 2.7 - 20;
        final v = noise.fbm2(x, y, octaves: 5);
        expect(v, inInclusiveRange(-1.0, 1.0));
      }
    });

    test('值是连续变化的（相邻采样不会跳变）', () {
      const noise = ValueNoise(seed: 99);
      const step = 0.01;
      var prev = noise.value2(0, 0);
      for (var i = 1; i < 200; i++) {
        final v = noise.value2(i * step, 0);
        expect((v - prev).abs(), lessThan(0.15), reason: '在 i=$i 处出现跳变');
        prev = v;
      }
    });
  });

  group('Terrain 高度场', () {
    final terrain = Terrain();

    test('中央玩法区被压平', () {
      // playRadius 以内应当几乎是平的，给玩法一块舒服的场地。
      for (final p in [
        (x: 0.0, z: 0.0),
        (x: 5.0, z: 0.0),
        (x: 0.0, z: -8.0),
        (x: 10.0, z: 10.0),
      ]) {
        expect(terrain.heightAt(p.x, p.z).abs(), lessThan(0.6),
            reason: '(${p.x}, ${p.z}) 不够平');
      }
    });

    test('外围确实有起伏，不是一块平板', () {
      final samples = <double>[];
      for (var i = 0; i < 64; i++) {
        final angle = i / 64 * math.pi * 2;
        samples.add(terrain.heightAt(math.cos(angle) * 50, math.sin(angle) * 50));
      }
      final minH = samples.reduce(math.min);
      final maxH = samples.reduce(math.max);
      expect(maxH - minH, greaterThan(3.0), reason: '外围地形太平，没有山丘');
    });

    test('heightAt 是纯函数（同参数同结果）', () {
      for (var i = 0; i < 30; i++) {
        final x = i * 2.3 - 30;
        final z = 17.0 - i * 1.7;
        expect(terrain.heightAt(x, z), terrain.heightAt(x, z));
      }
    });

    test('法线朝上且已归一化', () {
      final n = terrain.normalAt(30, -25);
      expect(n.y, greaterThan(0));
      expect(n.length, closeTo(1.0, 1e-6));
    });
  });

  group('泊松盘采样', () {
    test('产出请求数量且互不靠得太近', () {
      final rng = math.Random(3);
      const radius = 2.0;
      final points = poissonDisc(60, radius, rng);

      expect(points.length, greaterThan(20));
      for (var i = 0; i < points.length; i++) {
        for (var j = i + 1; j < points.length; j++) {
          final d = (points[i] - points[j]).magnitude;
          expect(d, greaterThanOrEqualTo(radius - 1e-9),
              reason: '第 $i 与第 $j 个点距离 $d 小于半径');
        }
      }
    });
  });
}
