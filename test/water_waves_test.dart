/// 水面波场的物理自洽性测试（**纯 Dart**，不构造 MeshGeometry / Scene）。
///
/// 这些断言不是为了"跑通"，而是把"河面看起来在流动"拆成几条必须成立的关系：
///   * 位移真的随时间变化（核心需求）；
///   * 变化幅度与**当地流速**绑定，而不是各说各话；
///   * 波峰不越过岸线高程；
///   * 法线是单位向量、以 +Y 为主（否则光照下读不出波纹）；
///   * 点源涟漪会立刻响应、随后衰减、总量有上限且会合并；
///   * 泡沫亮度随 [RiverFlow.turbulenceAt] 提升。
///
/// 之所以能在没有 GPU 的环境里跑，是因为全部数学都在 `water_waves.dart`：
/// 那里不 import flutter_scene，构造 `Scene` / `MeshGeometry` 才会抛的那类
/// 异常在这里根本不会发生。
library;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kirby_scene/game/flow.dart';
import 'package:kirby_scene/game/terrain.dart';
import 'package:kirby_scene/game/water_waves.dart';

void main() {
  late Terrain terrain;
  late RiverFlow flow;

  setUpAll(() {
    terrain = Terrain();
    flow = RiverFlow(terrain);
  });

  WaterWaves makeWave() => WaterWaves(flow: flow);

  /// 离给定 z 最近的那一行。
  int nearestRow(WaterWaves w, double z) {
    var best = 0;
    var bestD = double.infinity;
    for (var i = 0; i < w.rows; i++) {
      final d = (w.vertexZ(i) - z).abs();
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }

  /// 某一行（去掉最外两列，避开振幅为 0 的岸线）在 dt 内的平均垂直位移变化量。
  double rowAvgDelta(WaterWaves w, int row, double t0, double dt) {
    w.update(t0);
    final before = Float32List(w.cols);
    for (var j = 0; j < w.cols; j++) {
      before[j] = w.positions[(row * w.cols + j) * 3 + 1];
    }
    w.update(t0 + dt);
    var sum = 0.0;
    for (var j = 1; j < w.cols - 1; j++) {
      final y = w.positions[(row * w.cols + j) * 3 + 1];
      sum += (y - before[j]).abs();
    }
    return sum / (w.cols - 2);
  }

  /// 某列顶点在一段时间内的振幅（相对该行水位的最大偏离）。
  double colAmplitude(WaterWaves w, int row, int col) {
    final waterY = flow.waterYAt(w.vertexZ(row));
    var maxAbs = 0.0;
    for (var k = 0; k < 80; k++) {
      w.update(k * 0.04);
      final y = w.positions[(row * w.cols + col) * 3 + 1];
      final d = (y - waterY).abs();
      if (d > maxAbs) maxAbs = d;
    }
    return maxAbs;
  }

  group('网格拓扑', () {
    test('顶点数 / 三角形数符合 rows×cols 带状网格，索引都在范围内', () {
      final w = makeWave();
      expect(w.vertexCount, w.rows * w.cols);
      expect(w.triangleCount, (w.rows - 1) * (w.cols - 1) * 2);
      expect(w.indices.length, w.triangleCount * 3);

      for (final index in w.indices) {
        expect(index, lessThan(w.vertexCount));
      }

      // 每行最外两列必须落在流场给出的岸线上（水面范围由流场决定，不自己扫地形）。
      for (var i = 0; i < w.rows; i += 17) {
        final (left, right) = flow.banksAt(w.vertexZ(i));
        expect(w.vertexXAt(i, 0), closeTo(left, 1e-3),
            reason: '第 $i 行左岸没落在 flow.banksAt 上');
        expect(w.vertexXAt(i, w.cols - 1), closeTo(right, 1e-3),
            reason: '第 $i 行右岸没落在 flow.banksAt 上');
      }
    });

    test('顶点预算落在 1.5k–2.5k，且每 3 帧一次更新足够轻', () {
      final w = makeWave();
      expect(w.vertexCount, greaterThanOrEqualTo(1500));
      expect(w.vertexCount, lessThanOrEqualTo(2500));
    });
  });

  group('位移与水位', () {
    test('所有顶点 y 落在 flow.waterYAt(z) 附近，且岸边不高于岸线', () {
      final w = makeWave();
      w.update(3.17);

      var maxAbs = 0.0;
      for (var i = 0; i < w.rows; i++) {
        final z = w.vertexZ(i);
        final waterY = flow.waterYAt(z);
        for (var j = 0; j < w.cols; j++) {
          final vi = i * w.cols + j;
          final y = w.positions[vi * 3 + 1];
          maxAbs = math.max(maxAbs, (y - waterY).abs());

          // 波峰不允许超过岸线高程：岸线在 mean water level 上几乎没有超高，
          // 所以近岸/浅水处的顶点必须严格贴在（或低于）水位上。
          final x = w.vertexXAt(i, j);
          final shallow = flow.depthAt(x, z) < 0.05;
          if (j == 0 || j == w.cols - 1 || shallow) {
            expect(y, lessThanOrEqualTo(waterY + 1e-3),
                reason: '第 $i 行第 $j 列的水面越过了岸线（y=$y, waterY=$waterY）');
          }
        }
      }
      expect(maxAbs, lessThan(WaterWaves.maxAmplitude + 2e-3),
          reason: '水面顶点偏离水位过大');
    });

    test('时间前进后顶点位置不同 —— 水面确实在动（核心需求）', () {
      final w = makeWave();
      w.update(0.0);
      final before = Float32List.fromList(w.positions);

      w.update(0.09);
      var changed = 0;
      var maxDelta = 0.0;
      for (var vi = 0; vi < w.vertexCount; vi++) {
        final d = (w.positions[vi * 3 + 1] - before[vi * 3 + 1]).abs();
        if (d > 1e-4) changed++;
        maxDelta = math.max(maxDelta, d);
      }
      expect(changed, greaterThan((w.vertexCount * 0.6).round()),
          reason: '大部分顶点没动 —— 水面还是静止的');
      expect(maxDelta, greaterThan(0.004));
    });
  });

  group('动画与流场绑定', () {
    test('流速快的水域相邻两帧位移变化量大于流速慢的水域', () {
      final w = makeWave();

      var fastestZ = 0.0, slowestZ = 0.0;
      var fastest = -1.0, slowest = double.infinity;
      for (var z = -60.0; z <= 60.0; z += 0.5) {
        final v = flow.sectionSpeedAt(z);
        if (v > fastest) {
          fastest = v;
          fastestZ = z;
        }
        if (v < slowest) {
          slowest = v;
          slowestZ = z;
        }
      }
      expect(fastest / slowest, greaterThan(1.3),
          reason: '沿程流速几乎没有差异，这条断言失去意义');

      const dt = 0.08;
      const t0 = 1.3;
      final fastAvg =
          rowAvgDelta(w, nearestRow(w, fastestZ), t0, dt);
      final slowAvg =
          rowAvgDelta(w, nearestRow(w, slowestZ), t0, dt);

      expect(fastAvg, greaterThan(slowAvg * 1.3),
          reason: '快水（z=$fastestZ, v=$fastest）的位移变化量 '
              '$fastAvg 没有明显大于慢水（z=$slowestZ, v=$slowest）的 $slowAvg');
    });

    test('边框顶点（最外列）振幅明显小于河心', () {
      final w = makeWave();
      final row = w.rows ~/ 2;

      final centerAmp = colAmplitude(w, row, w.cols ~/ 2);
      final leftAmp = colAmplitude(w, row, 0);
      final rightAmp = colAmplitude(w, row, w.cols - 1);

      expect(centerAmp, greaterThan(0.05),
          reason: '河心振幅太小，读不出波纹');
      expect(leftAmp, lessThan(centerAmp * 0.2),
          reason: '左岸振幅 $leftAmp 没有明显小于河心 $centerAmp');
      expect(rightAmp, lessThan(centerAmp * 0.2),
          reason: '右岸振幅 $rightAmp 没有明显小于河心 $centerAmp');
    });
  });

  group('法线', () {
    test('法线是单位向量，且以 +Y 为主（否则光照下读不出波纹）', () {
      final w = makeWave();
      w.update(2.0);

      var sumY = 0.0;
      var minY = 1.0;
      for (var vi = 0; vi < w.vertexCount; vi++) {
        final o = vi * 3;
        final x = w.normals[o];
        final y = w.normals[o + 1];
        final z = w.normals[o + 2];
        final len = math.sqrt(x * x + y * y + z * z);
        expect(len, closeTo(1.0, 1e-3), reason: '顶点 $vi 的法线不是单位向量');
        expect(y, greaterThan(0.0), reason: '顶点 $vi 的法线朝下');
        sumY += y;
        minY = math.min(minY, y);
      }

      final meanY = sumY / w.vertexCount;
      expect(meanY, greaterThan(0.8), reason: '法线平均不够朝上 —— 波纹过陡或方向反了');
      // 全都恰好是 (0,1,0) 说明法线根本没被波面扰动（等于没做这一步）。
      expect(meanY, lessThan(0.999), reason: '法线完全平坦 —— 有限差分没生效');
      expect(minY, lessThan(0.99), reason: '没有任何一条法线被波纹扰动');
    });
  });

  group('点源涟漪', () {
    test('addRipple 后该点位移立刻变大，随后随时间衰减', () {
      final w = makeWave();
      const t0 = 4.0;
      w.update(t0);

      const z = 0.0;
      final (left, right) = flow.banksAt(z);
      final cx = (left + right) * 0.5;

      final base = w.heightOffsetAt(cx, z, t0);
      w.addRipple(cx, z, 0.4);
      final just = w.heightOffsetAt(cx, z, t0);

      expect((just - base).abs(), greaterThan(0.05),
          reason: '触发涟漪后该点位移没有立刻变化');

      final early = w.rippleOffsetAt(cx, z, t0).abs();
      final later = w.rippleOffsetAt(cx, z, t0 + 1.9).abs();
      expect(later, lessThan(early), reason: '涟漪没有随时间衰减');
      expect(w.rippleOffsetAt(cx, z, t0 + WaterWaves.rippleLifetime + 0.3), 0.0,
          reason: '涟漪超过了寿命还在起作用');
    });

    test('同一位置附近重复触发会合并，不会无限堆积', () {
      final w = makeWave();
      w.update(0.0);
      final cx = flow.river.centerX(0.0);

      w.addRipple(cx, 0.0, 0.3);
      final afterFirst = w.rippleCount;
      for (var k = 0; k < 5; k++) {
        w.addRipple(cx + 0.05 * k, 0.02 * k, 0.2);
      }
      expect(w.rippleCount, afterFirst,
          reason: '同一处连续触发没有合并，涟漪会越堆越多');
    });

    test('涟漪总数有上限', () {
      final w = makeWave();
      w.update(0.0);
      for (var k = 0; k < 300; k++) {
        final z = -70.0 + k * 0.45;
        w.addRipple(flow.river.centerX(z), z, 0.3);
      }
      expect(w.rippleCount, lessThanOrEqualTo(WaterWaves.rippleCapacity));
      expect(w.rippleCount, greaterThan(4),
          reason: '所有涟漪都被误判成了同一个点');
      expect(WaterWaves.rippleCapacity, lessThanOrEqualTo(60),
          reason: '上限太高，会拖垮每帧的涟漪循环');
    });

    test('过期的涟漪会被回收', () {
      final w = makeWave();
      w.update(0.0);
      final cx = flow.river.centerX(20.0);
      w.addRipple(cx, 20.0, 0.3);
      expect(w.rippleCount, 1);
      w.update(WaterWaves.rippleLifetime + 0.5);
      expect(w.rippleCount, 0, reason: '过期涟漪没有被淘汰');
    });
  });

  group('泡沫', () {
    test('湍流高的位置泡沫亮度高于湍流低的位置', () {
      final w = makeWave();
      const t = 1.7;
      w.update(t);

      var highSum = 0.0, highN = 0;
      var lowSum = 0.0, lowN = 0;
      for (var i = 0; i < w.rows; i++) {
        final z = w.vertexZ(i);
        for (var j = 0; j < w.cols; j++) {
          final x = w.vertexXAt(i, j);
          if (flow.depthAt(x, z) < 0.05) continue;
          final turb = flow.turbulenceAt(x, z);
          final foam = w.foamAt(x, z, t);
          // 这条河最急的断面湍流也只到 ~0.47（见 flow 的参考流速取舍），
          // 所以"高湍流"的门槛取 0.35 而不是 0.5。
          if (turb > 0.35) {
            highSum += foam;
            highN++;
          } else if (turb < 0.15) {
            lowSum += foam;
            lowN++;
          }
        }
      }

      expect(highN, greaterThan(0), reason: '没有采样到湍流高的点');
      expect(lowN, greaterThan(0), reason: '没有采样到湍流低的点');
      expect(highSum / highN, greaterThan(lowSum / lowN),
          reason: '湍流高的地方泡沫没有更亮 —— 浅滩读不出白水');
    });

    test('顺流泡沫条纹随时间滚动（顶点色在变）', () {
      final w = makeWave();
      w.update(0.0);
      final before = Float32List.fromList(w.colors);
      w.update(0.15);

      var changed = 0;
      for (var vi = 0; vi < w.vertexCount; vi++) {
        if ((w.colors[vi * 4 + 1] - before[vi * 4 + 1]).abs() > 1e-4) changed++;
      }
      expect(changed, greaterThan((w.vertexCount * 0.5).round()),
          reason: '顶点色几乎没变 —— 看不出水往哪边流');
    });
  });
}
