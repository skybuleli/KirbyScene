/// 河床水草的**分布规律与摇曳物理**测试。
///
/// 这些断言有物理/生态含义，不是"跑通"：
///   * 生态位 —— 只在水下、株顶留出水余量（那是挺水芦苇的地盘）；
///   * 水动力 —— 急流抓不住根，所以主流区没有水草；
///   * 分布 —— 成丛而非均匀，且近岸缓流带显著密于主流区；
///   * 摇曳 —— 摆幅随流速、相位随流场推进、**根部在摆动中严格不动**。
///
/// 布局与摇曳都是纯计算（[AquaticFlora.planSites] / [AquaticFlora.swayMatrixFor]），
/// 测试环境没有 GPU，因此这里完全不构造 `InstancedMesh`，只断言数据。
library;
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:kirby_scene/game/aquatic_flora.dart';
import 'package:kirby_scene/game/flow.dart';
import 'package:kirby_scene/game/terrain.dart';
import 'package:vector_math/vector_math.dart' as vm;

void main() {
  late Terrain terrain;
  late RiverFlow flow;

  setUpAll(() {
    terrain = Terrain();
    flow = RiverFlow(terrain);
  });

  AquaticFlora flora({int seed = 311, int budget = 2000}) =>
      AquaticFlora(terrain: terrain, flow: flow, seed: seed, instanceBudget: budget);

  /// 把河道按 2m 格切成"合格格"（在水里、够深、未上岸），返回
  /// (格内株数统计, 合格格的横向位置列表)。方差与分带密度测试共用。
  ({Map<int, int> counts, List<double> laterals}) gridStat(
    List<AquaticPlantSite> sites, {
    double cell = 2.0,
  }) {
    final counts = <int, int>{};
    int key(int gx, int gz) => gx * 100000 + gz;
    for (final s in sites) {
      final k = key((s.x / cell).floor(), (s.z / cell).floor());
      counts[k] = (counts[k] ?? 0) + 1;
    }
    final laterals = <double>[];
    final keys = <int>[];
    for (var gx = -60; gx <= 60; gx++) {
      for (var gz = -60; gz <= 60; gz++) {
        final cx = (gx + 0.5) * cell;
        final cz = (gz + 0.5) * cell;
        if (!flow.isInWater(cx, cz)) continue;
        if (flow.depthAt(cx, cz) < 0.16) continue;
        final l = flow.lateralAt(cx, cz);
        if (l > 1.12) continue;
        laterals.add(l);
        keys.add(key(gx, gz));
      }
    }
    final perCell = <int, int>{};
    for (final k in keys) {
      perCell[k] = counts[k] ?? 0;
    }
    return (counts: perCell, laterals: laterals);
  }

  AquaticPlantSite withSpeed(AquaticPlantSite s, double speed) => AquaticPlantSite(
        x: s.x,
        z: s.z,
        bedY: s.bedY,
        waterY: s.waterY,
        depth: s.depth,
        speed: speed,
        lateral: s.lateral,
        species: s.species,
        height: s.height,
        yaw: s.yaw,
        phase: s.phase,
        flowDirX: s.flowDirX,
        flowDirZ: s.flowDirZ,
        bladeCount: s.bladeCount,
        tint: s.tint,
      );

  group('生态位：只在水下', () {
    test('每个 site 都在水下，根与株顶都在水位以下', () {
      final sites = flora(budget: 100000).planSites();
      expect(sites, isNotEmpty);

      for (final s in sites) {
        expect(flow.isInWater(s.x, s.z), isTrue,
            reason: '(${s.x},${s.z}) 的水草不在水下 —— 会和岸边芦苇打架');
        expect(s.depth, greaterThan(0.0));
        expect(s.bedY, lessThan(s.waterY), reason: '根没在水面以下');
      }
    });

    test('株顶低于水位且留 ≥5cm 余量（水草穿出水面 = 穿帮）', () {
      final sites = flora(budget: 100000).planSites();
      for (final s in sites) {
        final margin = s.waterY - s.tipY;
        expect(margin, greaterThanOrEqualTo(AquaticFlora.minClearance - 1e-9),
            reason: '(${s.x},${s.z}) 株顶距水面只有 ${margin.toStringAsFixed(4)}m');
      }
    });

    test('长草确实长到贴着水位（但没穿出），且深水里有高个长草', () {
      final sites = flora(budget: 100000).planSites();
      var minMargin = double.infinity;
      for (final s in sites) {
        final m = s.waterY - s.tipY;
        if (m < minMargin) minMargin = m;
      }
      // 有株几乎顶到水位（允许"接近水面"这个自然现象）……
      expect(minMargin, lessThanOrEqualTo(0.055),
          reason: '没有一株长到接近水面，长草没长起来（最小余量 $minMargin）');
      // ……但没有任何一株突破 5cm 余量。
      expect(minMargin, greaterThanOrEqualTo(AquaticFlora.minClearance - 1e-9));

      final tallBanded = sites
          .where((s) => s.species == AquaticSpecies.bandedLeaves && s.height > 0.6)
          .length;
      expect(tallBanded, greaterThan(20), reason: '深水里没有高个的带状长草');
    });
  });

  group('水动力：急流抓不住根', () {
    test('所有 site 的流速都低于阈值', () {
      final sites = flora(budget: 100000).planSites();
      for (final s in sites) {
        expect(s.speed, lessThan(AquaticFlora.speedCutoff),
            reason: '(${s.x},${s.z}) 流速 ${s.speed.toStringAsFixed(3)} 处还有水草');
      }
    });

    test('确实存在超过阈值的水域（否则"急流没有草"是空规则）', () {
      var fastPoints = 0;
      for (var z = -60.0; z <= 60.0; z += 1.0) {
        final (left, right) = flow.banksAt(z);
        for (var i = 0; i <= 30; i++) {
          final x = left + (right - left) * (i / 30);
          if (!flow.isInWater(x, z)) continue;
          if (flow.speedAt(x, z) >= AquaticFlora.speedCutoff) fastPoints++;
        }
      }
      expect(fastPoints, greaterThan(200),
          reason: '整条河没有一处超过阈值的急流，这条筛选规则形同虚设');
    });
  });

  group('分布自然错落', () {
    late List<AquaticPlantSite> sites;
    late Map<int, int> perCell;
    late List<double> laterals;

    setUpAll(() {
      // 大预算 = 不裁剪的理想分布，排除"预算切边"对统计的干扰。
      sites = flora(budget: 100000).planSites();
      final stat = gridStat(sites);
      perCell = stat.counts;
      laterals = stat.laterals;
    });

    test('成丛：格内株数的方差显著大于泊松期望（var/mean ≫ 1）', () {
      final counts = perCell.values.toList();
      expect(counts.length, greaterThan(500));
      final mean = counts.reduce((a, b) => a + b) / counts.length;
      var varSum = 0.0;
      for (final c in counts) {
        varSum += (c - mean) * (c - mean);
      }
      final variance = varSum / counts.length;
      expect(mean, greaterThan(0.05));
      // 泊松过程 var == mean；成丛（还有成片裸河床）会把它顶到几倍。
      expect(variance / mean, greaterThan(1.5),
          reason: '格内株数几乎是泊松的 —— 还是均匀撒点，不是成丛');
    });

    test('存在成片的空白河床（成丛的另一面）', () {
      final counts = perCell.values.toList();
      final empty = counts.where((c) => c == 0).length;
      expect(empty / counts.length, greaterThan(0.35),
          reason: '合格水域里几乎处处有草 —— 没有留出裸河床，读不出"丛"');
    });

    test('近岸缓流带密度显著高于主流区', () {
      final keys = perCell.keys.toList();
      double avgIn(double lo, double hi) {
        var sum = 0.0;
        var n = 0;
        for (var i = 0; i < keys.length; i++) {
          if (laterals[i] >= lo && laterals[i] < hi) {
            sum += perCell[keys[i]]!;
            n++;
          }
        }
        return n == 0 ? 0 : sum / n;
      }

      final bank = avgIn(0.5, 0.85); // 近岸缓流带
      final mainstream = avgIn(0.0, 0.15); // 河心主流
      expect(bank, greaterThan(mainstream * 2.0),
          reason: '近岸 $bank 未显著高于主流 $mainstream —— 流速筛选没起作用');
    });

    test('物种按水深分带：矮苔最浅、细叶丛居中、带状长草最深', () {
      double meanDepth(AquaticSpecies sp) {
        final ds = sites.where((s) => s.species == sp).map((s) => s.depth).toList();
        expect(ds, isNotEmpty, reason: '物种 ${sp.label} 一株都没有，分带规则没跑');
        return ds.reduce((a, b) => a + b) / ds.length;
      }

      final moss = meanDepth(AquaticSpecies.bedMoss);
      final fine = meanDepth(AquaticSpecies.fineLeaf);
      final banded = meanDepth(AquaticSpecies.bandedLeaves);
      expect(fine, greaterThan(moss), reason: '细叶丛应当比矮苔长在更深处');
      expect(banded, greaterThan(fine), reason: '带状长草应当长在最深处');
    });

    test('深水里没有矮苔（分带是硬约束而非倾向）', () {
      for (final s in sites) {
        if (s.species == AquaticSpecies.bedMoss) {
          expect(s.depth, lessThan(0.9),
              reason: '矮苔出现在 ${s.depth.toStringAsFixed(2)}m 深处，分带失效');
        }
      }
    });
  });

  group('可复现性', () {
    test('同一 seed 结果逐点一致', () {
      final a = flora(seed: 311, budget: 100000).planSites();
      final b = flora(seed: 311, budget: 100000).planSites();
      expect(a.length, b.length);
      for (var i = 0; i < a.length; i++) {
        expect(a[i].x, b[i].x);
        expect(a[i].z, b[i].z);
        expect(a[i].species, b[i].species);
        expect(a[i].height, b[i].height);
      }
    });

    test('不同 seed 结果不同', () {
      final a = flora(seed: 311, budget: 100000).planSites();
      final b = flora(seed: 912, budget: 100000).planSites();
      var differs = a.length != b.length;
      for (var i = 0; i < math.min(a.length, b.length) && !differs; i++) {
        if (a[i].x != b[i].x || a[i].z != b[i].z) differs = true;
      }
      expect(differs, isTrue, reason: '换 seed 得到完全一样的分布 —— 撒点是退化的');
    });
  });

  group('预算', () {
    test('默认预算下实例数落在 1200–2500，且不超预算', () {
      final system = flora();
      final sites = system.planSites();
      var instances = 0;
      for (final s in sites) {
        instances += s.bladeCount;
      }
      expect(instances, greaterThanOrEqualTo(1200));
      expect(instances, lessThanOrEqualTo(system.instanceBudget));
    });

    test('预算不足时优先保住近场，裁掉的是远景', () {
      final full = flora(budget: 100000).planSites();
      final capped = flora().planSites();

      int near(List<AquaticPlantSite> a) =>
          a.where((s) => s.x * s.x + s.z * s.z <= 45.0 * 45.0).length;

      final nearFull = near(full);
      final nearCapped = near(capped);
      expect(nearFull, greaterThan(100));
      expect(nearCapped / nearFull, greaterThan(0.95),
          reason: '45m 内的水草被预算裁掉了 —— 近场优先级失效');
      expect(capped.length, lessThan(full.length),
          reason: '小预算没有裁掉任何东西，说明预算根本没起作用');
    });
  });

  group('随水流摇曳', () {
    late AquaticPlantSite fast;
    late AquaticPlantSite slow;

    setUpAll(() {
      final banded = flora(budget: 100000)
          .planSites()
          .firstWhere((s) => s.species == AquaticSpecies.bandedLeaves);
      fast = banded; // 原样的当地流速
      slow = withSpeed(banded, 0.05); // 缓流
    });

    test('同一株在急流中的摆幅大于缓流', () {
      double range(AquaticPlantSite s) {
        var lo = double.infinity;
        var hi = -double.infinity;
        for (var i = 0; i < 4000; i++) {
          final a = flora().swayAngle(s, i * 0.005);
          if (a < lo) lo = a;
          if (a > hi) hi = a;
        }
        return hi - lo;
      }

      final rFast = range(fast);
      final rSlow = range(slow);
      expect(rFast, greaterThan(rSlow * 1.3),
          reason: '急流摆幅 $rFast 没有明显大于缓流 $rSlow');
      expect(rSlow, greaterThan(0.0));
    });

    test('相位随时间推进（往复摆动，而不是停在某个角）', () {
      final s = fast;
      final period = 2 * math.pi / flora().swayOmega(s);
      final samples = [
        for (var i = 0; i < 60; i++) flora().swayAngle(s, i * period / 60),
      ];
      expect(samples.toSet().length, greaterThan(20), reason: '摆动角几乎是常量');
      var rises = false;
      var falls = false;
      for (var i = 1; i < samples.length; i++) {
        if (samples[i] > samples[i - 1] + 1e-9) rises = true;
        if (samples[i] < samples[i - 1] - 1e-9) falls = true;
      }
      expect(rises && falls, isTrue, reason: '没有往复，相位没有在推进');
      // 一个周期之后回到原角度（相位是严格线性的 → 严格周期）。
      expect(flora().swayAngle(s, period + 0.37), closeTo(flora().swayAngle(s, 0.37), 1e-9));
    });

    test('根部位置在摆动中严格不变（铰接在河床上，不是整体平移）', () {
      final s = fast;
      final m0 = flora().swayMatrixFor(s, 0.0);
      final x0 = m0.storage[12];
      final y0 = m0.storage[13];
      final z0 = m0.storage[14];

      // 根部坐标也应当就是 site 给的株根（允许矩阵的浮点量化误差）。
      expect(x0, closeTo(s.x, 1e-4));
      expect(y0, closeTo(s.bedY, 1e-4));
      expect(z0, closeTo(s.z, 1e-4));

      for (var i = 0; i < 500; i++) {
        final t = i * 0.037;
        final m = flora().swayMatrixFor(s, t);
        expect(m.storage[12], x0,
            reason: '摆动把根部挪动了 —— 草是"漂"不是"摆"');
        expect(m.storage[13], y0);
        expect(m.storage[14], z0);
      }
    });

    test('叶尖顺/逆流向倾倒，且只沿流向偏移（不横着摆）', () {
      final s = fast;
      final h = s.height;
      var sawDownstream = false;
      var sawUpstream = false;
      var maxCross = 0.0;
      var maxAlong = 0.0;

      for (var i = 0; i < 2000; i++) {
        final m = flora().swayMatrixFor(s, i * 0.01);
        final tip = m.transform3(vm.Vector3(0, 1, 0));
        final ox = tip.x - s.x;
        final oz = tip.z - s.z;
        final along = ox * s.flowDirX + oz * s.flowDirZ;
        final cross = ox * s.flowDirZ - oz * s.flowDirX; // 垂直于流向的分量
        if (along > 1e-6) sawDownstream = true;
        if (along < -1e-6) sawUpstream = true;
        if (cross.abs() > maxCross) maxCross = cross.abs();
        if (along.abs() > maxAlong) maxAlong = along.abs();
      }

      expect(sawDownstream && sawUpstream, isTrue,
          reason: '叶尖只在流向一侧摆动，缺少"逆流回摆"');
      expect(maxCross, lessThan(1e-4),
          reason: '叶尖偏离了流向平面（横向甩动 $maxCross）—— 铰链轴应当垂直于流向');
      expect(maxAlong, lessThan(h),
          reason: '叶尖位移超过了株高 —— 旋转没有绕根，而是被当成了平移');
    });
  });

  group('水下颜色衰减', () {
    test('深水更暗、更偏蓝绿；浅水更亮、更偏黄绿', () {
      final sites = flora(budget: 100000).planSites();
      double lum(AquaticPlantSite s) =>
          0.2126 * s.tint.r + 0.7152 * s.tint.g + 0.0722 * s.tint.b;
      double blueGreenRatio(AquaticPlantSite s) =>
          s.tint.b / math.max(s.tint.g, 1e-6);

      final shallow = sites.where((s) => s.depth < 0.45).toList();
      final deep = sites.where((s) => s.depth > 1.15).toList();
      expect(shallow, isNotEmpty);
      expect(deep, isNotEmpty);

      double avgLum(List<AquaticPlantSite> a) =>
          a.map(lum).reduce((x, y) => x + y) / a.length;
      double avgRatio(List<AquaticPlantSite> a) =>
          a.map(blueGreenRatio).reduce((x, y) => x + y) / a.length;

      expect(avgLum(deep), lessThan(avgLum(shallow) * 0.6),
          reason: '深处的水草不够暗，深浅一眼分不开');
      expect(avgRatio(deep), greaterThan(avgRatio(shallow) * 1.4),
          reason: '深处的水草没有明显偏蓝绿');
      // 颜色分量都在合法范围。
      for (final s in sites) {
        for (final v in [s.tint.r, s.tint.g, s.tint.b]) {
          expect(v, inInclusiveRange(0.0, 1.0));
        }
        expect(s.tint.a, 1.0);
      }
    });
  });
}
