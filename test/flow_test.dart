/// 流场的物理自洽性测试。
///
/// 这些断言不是为了"跑通"，而是为了把流场钉在几条**必须成立**的物理关系上：
/// 水位与地形同源、连续性方程真的让窄断面变快、流向确实指向下游、
/// 沿程流时单调且波距与流速成正比。后面水面动画、水草、鱼虾、音效
/// 全部建立在这些关系上，这里一旦松掉，四处会同时出现自相矛盾的画面。
library;
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:kirby_scene/game/flow.dart';
import 'package:kirby_scene/game/terrain.dart';

void main() {
  late Terrain terrain;
  late RiverFlow flow;

  setUpAll(() {
    terrain = Terrain();
    flow = RiverFlow(terrain);
  });

  group('几何一致性', () {
    test('水面高程与 Terrain.waterSurfaceAt 同源', () {
      for (var z = -70.0; z <= 70.0; z += 5.0) {
        expect(
          flow.waterYAt(z),
          closeTo(terrain.waterSurfaceAt(flow.river.centerX(z), z), 1e-9),
          reason: 'z=$z 处水位与地形水位不一致 —— 水草/鱼会在不同高度',
        );
      }
    });

    test('水面宽度为正，且岸线包含河心', () {
      for (var z = -70.0; z <= 70.0; z += 3.0) {
        final (left, right) = flow.banksAt(z);
        expect(right - left, greaterThan(0.7));
        final cx = flow.river.centerX(z);
        expect(left, lessThanOrEqualTo(cx + 1e-6));
        expect(right, greaterThanOrEqualTo(cx - 1e-6));
      }
    });

    test('河床低于水面，且河心确实在水里', () {
      for (var z = -60.0; z <= 60.0; z += 10.0) {
        final cx = flow.river.centerX(z);
        expect(flow.bedYAt(z), lessThan(flow.waterYAt(z)));
        expect(flow.depthAt(cx, z), greaterThan(0.0));
        expect(flow.isInWater(cx, z), isTrue);
      }
    });

    test('河道两侧足够远处一定在岸上（不会整条河都在水下）', () {
      final z = 10.0;
      final cx = flow.river.centerX(z);
      expect(flow.isInWater(cx + 60.0, z), isFalse);
      expect(flow.isInWater(cx - 60.0, z), isFalse);
    });
  });

  group('流速场', () {
    test('流速落在可流动的合理区间（不是 0，也不是洪水）', () {
      for (var z = -70.0; z <= 70.0; z += 5.0) {
        final v = flow.sectionSpeedAt(z);
        expect(v, greaterThan(0.03), reason: 'z=$z 几乎不流 —— 动画会读成静止');
        expect(v, lessThan(1.2), reason: 'z=$z 流速超过 1.2m/s，小溪尺度上不合理');
      }
      expect(flow.maxSpeed, lessThan(1.2));
    });

    test('连续性方程成立：窄断面流得快，宽断面流得慢', () {
      var minW = double.infinity, maxW = -double.infinity;
      var zAtMin = 0.0, zAtMax = 0.0;
      for (var z = -60.0; z <= 60.0; z += 1.0) {
        final w = flow.widthAt(z);
        if (w < minW) {
          minW = w;
          zAtMin = z;
        }
        if (w > maxW) {
          maxW = w;
          zAtMax = z;
        }
      }
      expect(
        flow.sectionSpeedAt(zAtMin),
        greaterThan(flow.sectionSpeedAt(zAtMax)),
        reason: '最窄处 z=$zAtMin (宽 ${minW.toStringAsFixed(2)}m) 没有比 '
            '最宽处 z=$zAtMax (宽 ${maxW.toStringAsFixed(2)}m) 快',
      );
      expect(maxW / minW, greaterThan(1.15),
          reason: '河宽沿程几乎不变，连续性没得发挥');
    });

    test('河心比岸边快（横向边界层）', () {
      for (var z = -50.0; z <= 50.0; z += 10.0) {
        final (left, right) = flow.banksAt(z);
        final cx = (left + right) * 0.5;
        final center = flow.speedAt(cx, z);
        final nearBank = flow.speedAt(left + (right - left) * 0.05, z);
        expect(center, greaterThan(nearBank),
            reason: 'z=$z 处岸边流速不低于河心 —— 水草倒向会失去层次');
      }
    });

    test('表层流速高于断面平均（对数流速剖面）', () {
      final z = 0.0;
      final cx = flow.river.centerX(z);
      // 河心的表层流速应当明显高于断面平均，但不超过 1.5 倍。
      final ratio = flow.speedAt(cx, z) / flow.sectionSpeedAt(z);
      expect(ratio, greaterThan(1.0));
      expect(ratio, lessThan(1.5));
    });

    test('全河统计量可用且非退化', () {
      expect(flow.meanSpeed, greaterThan(0.03));
      expect(flow.maxSpeed, greaterThanOrEqualTo(flow.meanSpeed));
      expect(flow.discharge, greaterThan(0.0));
      expect(flow.meanTurbulence, inInclusiveRange(0.0, 1.0));
    });

    test('湍流强度在 [0,1] 且急滩高于深潭', () {
      var maxT = -1.0, minT = 2.0;
      var zAtMax = 0.0, zAtMin = 0.0;
      for (var z = -60.0; z <= 60.0; z += 1.0) {
        final t = flow.sectionTurbulenceAt(z);
        expect(t, inInclusiveRange(0.0, 1.0));
        if (t > maxT) {
          maxT = t;
          zAtMax = z;
        }
        if (t < minT) {
          minT = t;
          zAtMin = z;
        }
      }
      expect(maxT, greaterThan(minT + 0.02),
          reason: '湍流沿程没有变化 —— 音效与泡沫会平得没有起伏');
      // 湍流最高的断面应当比最低的断面浅（弗劳德近似：浅→急→白水）。
      expect(flow.sectionDepthAt(zAtMax), lessThan(flow.sectionDepthAt(zAtMin)));
    });
  });

  group('流向与沿程流时', () {
    test('流向指向下游（−z）且是单位向量', () {
      for (var z = -60.0; z <= 60.0; z += 12.0) {
        final cx = flow.river.centerX(z);
        for (final x in [cx - 2.0, cx, cx + 2.0]) {
          final d = flow.directionAt(x, z);
          expect(d.length, closeTo(1.0, 1e-6));
          expect(d.y, lessThan(0.0), reason: 'xz=($x,$z) 处流向没有指向下游');
        }
      }
    });

    test('弯道处流向带横向分量（离心偏移，漂移物甩向凹岸）', () {
      var bestZ = 0.0;
      var bestCurv = 0.0;
      for (var z = -50.0; z <= 50.0; z += 0.5) {
        final c = (flow.river.centerSlope(z + 0.5) -
                flow.river.centerSlope(z - 0.5))
            .abs();
        if (c > bestCurv) {
          bestCurv = c;
          bestZ = z;
        }
      }
      expect(bestCurv, greaterThan(0.0));
      final (left, right) = flow.banksAt(bestZ);
      final dir = flow.directionAt((left + right) * 0.5, bestZ);
      expect(dir.x.abs(), greaterThan(0.005),
          reason: '弯道 z=$bestZ 处流向完全没有横向分量，漂移物不会甩向外侧');
      expect(dir.x.abs(), lessThan(0.4),
          reason: '横向分量过大 —— 漂移物会横着撞岸而不是顺弯道走');
    });

    test('沿程流时随下游单调增加', () {
      var prev = -1.0;
      for (var z = 70.0; z >= -70.0; z -= 2.0) {
        final t = flow.travelTimeAt(z);
        expect(t, greaterThanOrEqualTo(prev - 1e-9),
            reason: 'z=$z 处流时倒退 —— 波形会倒着跑');
        prev = t;
      }
      expect(prev, greaterThan(30.0));
    });

    test('flowPhase 的空间波距正比于当地流速（急流拉长、深潭挤密）', () {
      // 相位沿 z 的梯度 |dφ/dz| = ω / v(z)：
      //   * 流速大 → 梯度小 → 波距长；
      //   * 流速小 → 梯度大 → 波距短。
      // 这条关系成立，就说明 travelTime 表真的按 1/v 积出来了 ——
      // 否则水面波纹会以"匀速"往下跑，急流浅滩上立刻穿帮。
      const omega = 2.2;
      const dt = 1e-3;
      double gradAt(double z) =>
          (flow.flowPhase(z + 0.5, dt, omega) - flow.flowPhase(z - 0.5, dt, omega))
              .abs();

      var fastestZ = 0.0, slowestZ = 0.0;
      var fastest = 0.0, slowest = double.infinity;
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
          reason: '沿程流速几乎没有差异，波距不会有变化');
      expect(gradAt(fastestZ), lessThan(gradAt(slowestZ)),
          reason: '最快断面 z=$fastestZ 的相位梯度不低于最慢断面 z=$slowestZ '
              '—— 波距与流速反了');

      // 波距的绝对值要落在"看得出是波纹"的尺度上（约 0.1–3m）。
      for (final z in [fastestZ, slowestZ]) {
        final lambda = 2 * math.pi * flow.sectionSpeedAt(z) / omega;
        expect(lambda, greaterThan(0.1), reason: 'z=$z 的波距小到看不见');
        expect(lambda, lessThan(3.0), reason: 'z=$z 的波距大到读不出波纹');
      }
    });

    test('stepDownstream 确实往 z 减小的方向走', () {
      final (nx, nz) = flow.stepDownstream(flow.river.centerX(0.0), 0.0, 3.0);
      expect(nz, lessThan(0.0));
      expect((nx - flow.river.centerX(0.0)).abs(), lessThan(3.0));
    });
  });

  group('横向剖面', () {
    test('lateralAt 在河心为 0、岸边接近 1', () {
      final z = 20.0;
      final (left, right) = flow.banksAt(z);
      final cx = (left + right) * 0.5;
      expect(flow.lateralAt(cx, z), closeTo(0.0, 0.02));
      expect(flow.lateralAt(right, z), closeTo(1.0, 0.05));
      expect(flow.lateralAt(left, z), closeTo(1.0, 0.05));
      expect(flow.lateralAt(right + 5.0, z), greaterThan(1.0));
    });

    test('横向速度剖面是单峰驼峰：岸边慢、河心快，两侧各自单调', () {
      final z = -15.0;
      final (left, right) = flow.banksAt(z);
      final speed = <double>[];
      for (var i = 0; i <= 20; i++) {
        speed.add(flow.speedAt(left + (right - left) * (i / 20), z));
      }
      var peak = 0;
      for (var i = 1; i < speed.length; i++) {
        if (speed[i] > speed[peak]) peak = i;
      }
      expect(peak, inInclusiveRange(8, 12), reason: '峰值不在河心附近');

      // 左半侧（岸边 → 河心）递增。
      for (var i = 1; i <= peak; i++) {
        expect(speed[i], greaterThanOrEqualTo(speed[i - 1] - 1e-9),
            reason: '左半侧 i=$i 处速度回落，边界层不单调');
      }
      // 右半侧（河心 → 岸边）递减。
      for (var i = peak + 1; i < speed.length; i++) {
        expect(speed[i], lessThanOrEqualTo(speed[i - 1] + 1e-9),
            reason: '右半侧 i=$i 处速度回升，边界层不单调');
      }
      // 岸边的速度必须明显低于河心，否则"水草倒向"与"泡沫聚岸"都没层次。
      expect(speed.first, lessThan(speed[peak] * 0.25));
      expect(speed.last, lessThan(speed[peak] * 0.25));
    });
  });

  group('最近河道点（空间音频的声源位置）', () {
    /// 点到"同 z 处河心"的距离 —— 旧实现用的就是这个近似。
    double sameRowDistance(double x, double z) {
      final dx = flow.river.centerX(z) - x;
      return math.sqrt(dx * dx);
    }

    test('返回的点确实在中心线上，且在河道范围内', () {
      for (final p in [
        (40.0, 0.0),
        (-35.0, 30.0),
        (10.0, -60.0),
        (0.0, 0.0),
        (55.0, -75.0),
      ]) {
        final (px, pz) = flow.nearestCenterPoint(p.$1, p.$2);
        expect(px, closeTo(flow.river.centerX(pz), 1e-9),
            reason: '返回的点不在中心线上');
        final lo = math.min(flow.river.zStart, flow.river.zEnd) - 1e-6;
        final hi = math.max(flow.river.zStart, flow.river.zEnd) + 1e-6;
        expect(pz, inInclusiveRange(lo, hi), reason: '声源跑到河道之外了');
      }
    });

    test('比"同 z 处河心"更近（弯道上差别明显）', () {
      // 声源定位用最近点而不是"玩家所在 z 的那一段"：河道是蜿蜒的，
      // 在弯道内侧站着时，最近的点可能在斜后方。
      var improved = 0;
      for (var z = -70.0; z <= 70.0; z += 7.0) {
        for (final offset in [18.0, -18.0, 35.0, -35.0]) {
          final x = flow.river.centerX(z) + offset;
          final (px, pz) = flow.nearestCenterPoint(x, z);
          final dx = px - x;
          final dz = pz - z;
          final nearest = math.sqrt(dx * dx + dz * dz);
          final same = sameRowDistance(x, z);
          expect(nearest, lessThanOrEqualTo(same + 1e-6),
              reason: '最近点比同 z 处还远，搜索写错了');
          if (nearest < same - 0.5) improved++;
        }
      }
      expect(improved, greaterThan(4),
          reason: '没有任何一个采样点受益 —— 说明只搜了同 z 的那一段');
    });

    test('从河心线上的点出发，最近点就是它自己（距离≈0）', () {
      for (var z = -60.0; z <= 60.0; z += 12.0) {
        final x = flow.river.centerX(z);
        final (px, pz) = flow.nearestCenterPoint(x, z);
        final d = math.sqrt(math.pow(px - x, 2) + math.pow(pz - z, 2));
        expect(d, lessThan(0.6), reason: 'z=$z 处的河心点没被认出来，距离 $d');
      }
    });

    test('声源处的断面参数与那个 z 一致（音色取自所听之处）', () {
      const probeX = 45.0;
      const probeZ = 12.0;
      final (_, pz) = flow.nearestCenterPoint(probeX, probeZ);
      final speed = flow.sectionSpeedAt(pz);
      final turb = flow.sectionTurbulenceAt(pz);
      expect(speed, greaterThan(0.0));
      expect(turb, inInclusiveRange(0.0, 1.0));
      // 同一段河道上取值必须与直接查询一致（同一个插值源）。
      expect(flow.sectionSpeedAt(pz), closeTo(speed, 1e-12));
      expect(flow.sectionTurbulenceAt(pz), closeTo(turb, 1e-12));
    });
  });
}
