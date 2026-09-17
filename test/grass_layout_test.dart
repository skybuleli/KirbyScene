/// 草地布局（采样/密度场）的纯逻辑测试。
///
/// 布局阶段不碰 GPU（[GrassField.sampleLayout] 只依赖 [Terrain] 的解析
/// 高度场），可以在这里验证分布正确性；渲染相关的部分留给截图验证。
library;
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:kirby_scene/game/grass.dart';
import 'package:kirby_scene/game/terrain.dart';

void main() {
  final terrain = Terrain(seed: 20260914);

  group('密度场 densityAt', () {
    test('平缓近处密度显著大于 0（修复密度过低的根基）', () {
      // 玩法区附近是压平的草地，法线朝上、海拔低 → 应该接近全密度。
      final d = GrassField(terrain: terrain).densityAt(10, 10);
      expect(d, greaterThan(8.0));
    });

    test('外沿密度衰减到接近 0（距离 LOD）', () {
      final field = GrassField(terrain: terrain);
      final near = field.densityAt(10, 10);
      final far = field.densityAt(60, 0);
      expect(far, lessThan(near * 0.5));
    });

    test('陡坡上不长草', () {
      // 在高度场上找一个法线朝上分量最小的点来验证渐隐。
      var steepest = 1.0;
      var steepestPos = (0.0, 0.0);
      for (var x = 25.0; x < 65.0; x += 1.0) {
        for (var z = 25.0; z < 65.0; z += 1.0) {
          final ny = terrain.normalAt(x, z).y;
          if (ny < steepest) {
            steepest = ny;
            steepestPos = (x, z);
          }
        }
      }
      if (steepest < 0.70) {
        final d = GrassField(terrain: terrain).densityAt(steepestPos.$1, steepestPos.$2);
        expect(d, closeTo(0, 1e-9));
      }
    });

    test('外圈之外与内圈之内都是 0', () {
      final field = GrassField(terrain: terrain);
      expect(field.densityAt(0, 0), 0); // 内圈
      expect(field.densityAt(75, 0), 0); // 外圈之外
    });
  });

  group('距离补偿（加宽 / 矮化）', () {
    test('相机近处不加宽、远处加宽到上限', () {
      final near = GrassField.distanceCompensation(
          cameraDistance: 3.0, playerDistance: 3.0);
      final far = GrassField.distanceCompensation(
          cameraDistance: 60.0, playerDistance: 3.0);
      expect(near.$1, 1.0);
      expect(far.$1, closeTo(1.0 + GrassField.kMaxWiden, 1e-9));
    });

    test('加宽随相机距离单调不减', () {
      var prev = 0.0;
      for (var d = 0.0; d <= 80.0; d += 2.0) {
        final w = GrassField.distanceCompensation(
                cameraDistance: d, playerDistance: 0)
            .$1;
        expect(w, greaterThanOrEqualTo(prev));
        prev = w;
      }
    });

    test('矮化只看角色距离，和相机距离无关', () {
      final a = GrassField.distanceCompensation(
          cameraDistance: 2.0, playerDistance: 0.0);
      final b = GrassField.distanceCompensation(
          cameraDistance: 50.0, playerDistance: 0.0);
      expect(a.$2, closeTo(GrassField.kNearHeightFactor, 1e-9));
      expect(b.$2, closeTo(a.$2, 1e-9));
      // 角色 10m 外恢复全高
      final full = GrassField.distanceCompensation(
          cameraDistance: 2.0, playerDistance: 12.0);
      expect(full.$2, closeTo(1.0, 1e-9));
    });

    test('加宽基准是相机而非角色（低视角巨型叶片回归）', () {
      // 相机贴着地面、叶片离角色很远但离相机很近：不该被加宽。
      final leafNearCamera = GrassField.distanceCompensation(
          cameraDistance: 1.5, playerDistance: 40.0);
      expect(leafNearCamera.$1, 1.0,
          reason: '离相机近的叶片不能因为离角色远就被放大成巨型叶片');
      // 反过来，离相机远的叶片要被加宽，哪怕它就在角色脚下。
      final leafFarFromCamera = GrassField.distanceCompensation(
          cameraDistance: 45.0, playerDistance: 0.0);
      expect(leafFarFromCamera.$1, greaterThan(2.0));
    });
  });

  group('布局采样 sampleLayout', () {
    test('产量在预算内且远超 v1（4500）', () {
      final blades = GrassField(terrain: terrain, maxBlades: 64000).sampleLayout();
      expect(blades.length, greaterThan(30000));
      expect(blades.length, lessThanOrEqualTo(64000));
    });

    test('确定性：同参数两次采样结果一致', () {
      final a = GrassField(terrain: terrain, seed: 42).sampleLayout();
      final b = GrassField(terrain: terrain, seed: 42).sampleLayout();
      expect(a.length, b.length);
      for (var i = 0; i < a.length; i++) {
        expect(a[i].x, b[i].x);
        expect(a[i].z, b[i].z);
      }
    });

    test('所有落点都在环带内、贴地合理', () {
      final blades = GrassField(terrain: terrain).sampleLayout();
      for (final b in blades) {
        final d = math.sqrt(b.x * b.x + b.z * b.z);
        // 外沿 70m + 域扭曲最多把落点推出 ~1m
        expect(d, inExclusiveRange(2.0, 71.5));
        expect(b.height, inExclusiveRange(0.0, 1.2));
      }
    });

    test('分层抖动消除空穴：预算覆盖范围内没有成片空盘', () {
      // 纯随机撒点的经典问题：存在比"平均间距"大得多的空穴。
      // 把场地按 4m 分盘统计，要求没有一块 4m 盘（有草区域）完全空掉。
      // 只统计 30m 内：预算现在是**优先给近处**的，远景在预算用尽时被裁掉
      // 属于设计行为（见下一个用例）。
      final blades = GrassField(terrain: terrain).sampleLayout();
      const cell = 4.0;
      final occupied = <String>{};
      for (final b in blades) {
        occupied.add('${(b.x / cell).floor()}:${(b.z / cell).floor()}');
      }
      var eligible = 0, filled = 0;
      final field = GrassField(terrain: terrain);
      for (var gx = -16; gx <= 16; gx++) {
        for (var gz = -16; gz <= 16; gz++) {
          final cx = (gx + 0.5) * cell;
          final cz = (gz + 0.5) * cell;
          final d = math.sqrt(cx * cx + cz * cz);
          if (d < 3.5 || d > 30.0) continue;
          if (field.densityAt(cx, cz) <= 1.0) continue;
          eligible++;
          if (occupied.contains('$gx:$gz')) filled++;
        }
      }
      expect(eligible, greaterThan(0));
      expect(filled / eligible, greaterThan(0.95),
          reason: '分层抖动下不应出现成片的 4m 空盘');
    });

    test('预算不足时优先保住近场（远景先被裁）', () {
      // 大预算得到"理想产量"，小预算应只损失远景。
      final big = GrassField(terrain: terrain, maxBlades: 400000).sampleLayout();
      final small = GrassField(terrain: terrain, maxBlades: 60000).sampleLayout();

      int near(List<GrassBlade> bs) => bs
          .where((b) => b.x * b.x + b.z * b.z <= 15.0 * 15.0)
          .length;

      final nearBig = near(big), nearSmall = near(small);
      expect(nearBig, greaterThan(1000));
      expect(nearSmall / nearBig, greaterThan(0.95),
          reason: '15m 内不该被预算裁剪（近场优先级）');
      expect(small.length, lessThan(big.length),
          reason: '小预算确实裁掉了东西（远景）');
    });

    test('丛簇：邻近叶片间距显著小于平均间距', () {
      // 平均间距 ~ 1/sqrt(密度)；丛簇分布下最近邻距离应明显更小。
      final blades = GrassField(terrain: terrain, maxBlades: 8000).sampleLayout();
      expect(blades.length, greaterThan(1000));
      final rng = math.Random(7);
      var nearestSum = 0.0;
      const probes = 200;
      for (var i = 0; i < probes; i++) {
        final b = blades[rng.nextInt(blades.length)];
        var nearest = double.infinity;
        for (final o in blades) {
          final dx = o.x - b.x, dz = o.z - b.z;
          final d2 = dx * dx + dz * dz;
          if (d2 > 1e-9 && d2 < nearest) nearest = d2;
        }
        nearestSum += math.sqrt(nearest);
      }
      final avgNearest = nearestSum / probes;
      // 均匀 8000 根 / ~13000m² → 平均间距 ~1.3m；丛簇下最近邻应 < 0.5m。
      expect(avgNearest, lessThan(0.5));
    });
  });
}
