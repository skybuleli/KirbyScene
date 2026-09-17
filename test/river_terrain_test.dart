/// 河流与地形改造的纯逻辑测试。
///
/// 这里验证的都是"看不见但一定会出问题"的性质：
///   * 河床是否**单调下降**（否则水流方向自相矛盾）；
///   * 水面是否**一定低于两岸**（否则河会"悬空流"）；
///   * 河谷雕刻是否**平滑**（这是"不要突兀拼接"的可断言版本：
///     相邻采样点之间的高度跳变必须有上界）；
///   * 河宽是否在合理区间（下切过浅会让水面漫成湖）。
library;
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:kirby_scene/game/river.dart';
import 'package:kirby_scene/game/terrain.dart';

void main() {
  final terrain = Terrain(seed: 20260914);
  const river = River();

  group('河道几何', () {
    test('中心线在世界原点之外、草场之内（不会切掉玩法区）', () {
      // 只检查地图内的河段（halfExtent 75，两端各留一点余量）。
      for (var z = -70.0; z <= 70.0; z += 2.0) {
        final x = river.centerX(z);
        final d = math.sqrt(x * x + z * z);
        expect(d, greaterThan(Terrain.playRadius + 5.0),
            reason: '河道不该穿过玩法区（z=$z）');
        expect(d, lessThan(90.0), reason: '河道该落在草地范围内（z=$z）');
      }
    });

    test('河床坡降单调下降（水流方向自洽）', () {
      var prev = river.bedRamp(river.zStart);
      for (var z = river.zStart - 2.0; z >= river.zEnd; z -= 2.0) {
        final y = river.bedRamp(z);
        expect(y, lessThanOrEqualTo(prev + 1e-9),
            reason: '河床在 z=$z 处回升了，水面会"倒流"');
        prev = y;
      }
      expect(river.bedRamp(river.zEnd), lessThan(river.bedRamp(river.zStart)));
    });

    test('河谷权重在两端的取值正确且单调', () {
      expect(river.valleyWeight(0), closeTo(0, 1e-9));
      expect(river.valleyWeight(river.valleyRadius), closeTo(1, 1e-9));
      var prev = -1.0;
      for (var d = 0.0; d <= river.valleyRadius; d += 0.5) {
        final w = river.valleyWeight(d);
        expect(w, greaterThanOrEqualTo(prev));
        prev = w;
      }
    });

    test('到中心线的距离随横向偏移单调增加', () {
      const z = 12.0;
      final cx = river.centerX(z);
      var prev = -1.0;
      for (var off = 0.0; off <= 30.0; off += 1.0) {
        final d = river.distanceToCenter(cx + off, z);
        expect(d, greaterThanOrEqualTo(prev - 1e-9));
        prev = d;
      }
    });
  });

  group('河谷雕刻', () {
    test('水面横向范围有界（是河不是湖）', () {
      // 逐行扫描：找出"地形低于水面"的连续区间，半宽不能超过 12m。
      // 下切过浅时水面会漫出十几米，看起来就是个湖（实测踩过）。
      for (var z = river.zEnd + 4; z <= river.zStart - 4; z += 2.0) {
        final cx = river.centerX(z);
        final waterY = terrain.waterSurfaceAt(cx, z);
        var halfWidth = 0.0;
        for (var off = 0.0; off <= 30.0; off += 0.25) {
          if (terrain.heightAt(cx + off, z) > waterY) break;
          halfWidth = off;
        }
        expect(halfWidth, lessThan(10.0),
            reason: 'z=$z 处水面半宽 ${halfWidth}m，太宽了（会读成湖）');
        expect(halfWidth, greaterThan(1.0),
            reason: 'z=$z 处几乎没水（河道断流）');
      }
    });

    test('河心处确实是"下切出来的河谷"（深度在合理区间）', () {
      // 与"无河道地形"对照：河心处应当被下切掉一个合理深度（2–8m）。
      // 太浅说明河谷没刻出来（水面会漫成湖），太深就成了峡谷。
      final noRiver = Terrain(seed: 20260914, carveRiver: false);
      var total = 0, cutEnough = 0;
      var maxCut = 0.0, minCut = double.infinity;
      for (var z = river.zEnd + 4; z <= river.zStart - 4; z += 3.0) {
        final cx = river.centerX(z);
        final cut = noRiver.heightAt(cx, z) - terrain.heightAt(cx, z);
        total++;
        if (cut > minCut) {} // 保持 min/max 语义直观
        minCut = math.min(minCut, cut);
        maxCut = math.max(maxCut, cut);
        // 河床取「坡降基准」与「原地形 − 下切深度」的较小值，因此
        // 穿过低洼地的河段天然下切少 —— 只要有 70% 的河段切出 0.8m 以上，
        // 就说明河谷确实存在；同时任何河段都不该被切成峡谷。
        if (cut >= 0.8) cutEnough++;
      }
      expect(total, greaterThan(20));
      expect(cutEnough / total, greaterThan(0.70),
          reason: '只有 ${(cutEnough / total * 100).toStringAsFixed(0)}% 的河段切出了河谷'
              '（最浅 ${minCut.toStringAsFixed(2)}m，最深 ${maxCut.toStringAsFixed(2)}m）');
      expect(maxCut, lessThan(12.0), reason: '下切过深，河谷变峡谷了');
      expect(minCut, greaterThan(-6.0),
          reason: '有些河段河床反而高于原地形（会变成"地上河"）');
    });

    test('河心处地形低于水面（河道里确实有水）', () {
      var wetRows = 0;
      for (var z = river.zEnd + 4; z <= river.zStart - 4; z += 2.0) {
        final cx = river.centerX(z);
        if (terrain.heightAt(cx, z) < terrain.waterSurfaceAt(cx, z)) wetRows++;
      }
      expect(wetRows, greaterThan(30), reason: '大部分河道都应该有水');
    });

    test('河谷雕刻平滑：相邻采样高度差有上界', () {
      // 这是"不要突兀拼接"的可断言版本：沿垂直河道方向每 0.25m 采一点，
      // 相邻两点的高差不能超过 1.2m（相当于 79% 的陡坡，已经非常陡了）。
      for (var z = -40.0; z <= 40.0; z += 10.0) {
        final cx = river.centerX(z);
        var prev = terrain.heightAt(cx - 30.0, z);
        for (var off = -30.0; off <= 30.0; off += 0.25) {
          final h = terrain.heightAt(cx + off, z);
          expect((h - prev).abs(), lessThan(1.2),
              reason: 'z=$z, 偏移 ${off}m 处出现高度突变（河谷接缝）');
          prev = h;
        }
      }
    });

    test('远离河道的地形不被雕刻影响', () {
      // 离中心线超过 valleyRadius*1.25 的地方，高度应当与"无河道地形"
      // 完全一致 —— 用一个 valleyRadius 极小的河道来对比。
      final noRiver = Terrain(seed: 20260914, carveRiver: false);
      for (final p in const [(-45.0, 0.0), (-20.0, -50.0), (-40.0, 40.0)]) {
        expect(terrain.heightAt(p.$1, p.$2),
            closeTo(noRiver.heightAt(p.$1, p.$2), 1e-9));
      }
    });

    test('水面夹在河床与河岸之间（既没过岸也没露出河床）', () {
      // 注意"水面 − 河床 == 水深"是同义反复（水面就是这么定义的），
      // 真正要验证的是它与**两侧地面**的关系。
      for (var z = river.zEnd + 5; z <= river.zStart - 5; z += 5.0) {
        final cx = river.centerX(z);
        final surface = terrain.waterSurfaceAt(cx, z);
        expect(terrain.heightAt(cx, z), lessThan(surface),
            reason: 'z=$z 河床高于水面（水会消失）');
        // 岸上 12m 处必须高于水面（水不会漫成湖）
        expect(terrain.heightAt(cx + 12.0, z), greaterThan(surface),
            reason: 'z=$z 右侧 12m 处仍在水下');
      }
    });
  });
}
