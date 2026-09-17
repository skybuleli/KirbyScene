/// 鱼虾**行为契约**的纯逻辑测试。
///
/// 为什么测这些而不是测"渲染出来长什么样"：水下生物最典型的穿帮是
/// **行为上的**，而且全都不用渲染一帧就能验出来 ——
///
///   * 鱼游到浅滩上"搁浅"（身体穿出水面、贴在地上）；
///   * 被玩家惊到却原地不动（惊逃写成了死代码）；
///   * 跃出水面之后再也没回到水里（落水判定反了，鱼会一直飞出画面）；
///   * 同一 seed 跑出两条不同的河（程序化生成不可复现 → 换平台就变样）。
///
/// 这些都靠 `AquaticFauna.advance` 的状态断言锁定 —— 它刻意不碰
/// `InstancedMesh`，所以能在 `flutter test` 里直接跑。
library;
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:kirby_scene/game/aquatic_fauna.dart';
import 'package:kirby_scene/game/flow.dart';
import 'package:kirby_scene/game/terrain.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// 一次推进的步长（60Hz）。
const double _dt = 1.0 / 60.0;

void main() {
  late Terrain terrain;
  late RiverFlow flow;

  setUpAll(() {
    // 地形与流场是只读的，所有用例共用一份（构造断面表不便宜）。
    terrain = Terrain();
    flow = RiverFlow(terrain);
  });

  AquaticFauna build({int fish = 12, int shrimp = 8, int seed = 707}) =>
      AquaticFauna(
        terrain: terrain,
        flow: flow,
        fishCount: fish,
        shrimpCount: shrimp,
        zHalfRange: 18.0,
        seed: seed,
      );

  final farAway = vm.Vector3(0, 0, 0); // 玩法区中心，离河道约 30m

  group('落点', () {
    test('鱼出生就在水里，且贴着水面之下（不会一开局就露背）', () {
      final fauna = build();
      for (var i = 0; i < fauna.fishCount; i++) {
        final x = fauna.fishX(i);
        final z = fauna.fishZ(i);
        final waterY = flow.waterYAt(z);
        final bed = terrain.heightAt(x, z);

        expect(flow.isInWater(x, z), isTrue, reason: '第 $i 条鱼落在岸上');
        expect(fauna.fishY(i), greaterThan(bed), reason: '第 $i 条鱼陷进河床');
        expect(fauna.fishY(i), lessThan(waterY), reason: '第 $i 条鱼一出生就在水面之上');
        expect(
          flow.waterYAt(z) - bed,
          greaterThan(fauna.fishSize(i) * 1.2),
          reason: '第 $i 条鱼的水深不够它游',
        );
      }
    });

    test('虾出生在近岸缓流带，且个头不穿出水面', () {
      final fauna = build();
      for (var i = 0; i < fauna.shrimpCount; i++) {
        final x = fauna.shrimpX(i);
        final z = fauna.shrimpZ(i);
        final size = fauna.shrimpSize(i);
        expect(flow.isInWater(x, z), isTrue);
        // 趴着的高度（与 applyTransforms 用的是同一个式子）。
        expect(terrain.heightAt(x, z) + size * 0.26, lessThan(flow.waterYAt(z)));
        expect(flow.lateralAt(x, z), lessThan(0.95), reason: '虾跑到岸上去了');
      }
    });
  });

  group('巡游', () {
    test('连续巡游 15 秒，没有一条游上岸或穿出水面', () {
      final fauna = build();
      for (var frame = 0; frame < 900; frame++) {
        fauna.advance(_dt, farAway);

        if (frame % 25 != 0) continue;
        for (var i = 0; i < fauna.fishCount; i++) {
          final x = fauna.fishX(i);
          final z = fauna.fishZ(i);
          final waterY = flow.waterYAt(z);

          expect(flow.isInWater(x, z), isTrue,
              reason: '第 $frame 帧：第 $i 条鱼离开了水体');
          expect(flow.lateralAt(x, z), lessThan(0.95),
              reason: '第 $frame 帧：第 $i 条鱼横着撞出岸线');
          expect(z, inInclusiveRange(-18.0, 18.0), reason: '第 $frame 帧：越出活动河段');
          if (!fauna.fishIsAirborne(i)) {
            expect(fauna.fishY(i), lessThan(waterY),
                reason: '第 $frame 帧：第 $i 条鱼的头穿出水面');
            expect(fauna.fishY(i), greaterThan(terrain.heightAt(x, z)),
                reason: '第 $frame 帧：第 $i 条鱼陷进河床');
          }
        }

        for (var i = 0; i < fauna.shrimpCount; i++) {
          final x = fauna.shrimpX(i);
          final z = fauna.shrimpZ(i);
          expect(flow.isInWater(x, z), isTrue,
              reason: '第 $frame 帧：第 $i 只虾爬上岸');
          expect(
            terrain.heightAt(x, z) + fauna.shrimpSize(i) * 0.26,
            lessThan(flow.waterYAt(z)),
            reason: '第 $frame 帧：第 $i 只虾穿出水面',
          );
        }
      }
    });

    test('鱼确实在挪动（不是一帧都没动过的静物）', () {
      final fauna = build();
      final startX = List<double>.generate(fauna.fishCount, fauna.fishX);
      final startZ = List<double>.generate(fauna.fishCount, fauna.fishZ);

      for (var frame = 0; frame < 300; frame++) {
        fauna.advance(_dt, farAway);
      }

      var moved = 0;
      for (var i = 0; i < fauna.fishCount; i++) {
        final d = math.sqrt(
          math.pow(fauna.fishX(i) - startX[i], 2) +
              math.pow(fauna.fishZ(i) - startZ[i], 2),
        );
        if (d > 0.5) moved++;
      }
      expect(moved, greaterThan(fauna.fishCount ~/ 2),
          reason: '5 秒里过半的鱼几乎没动，巡游逻辑没生效');
    });
  });

  group('惊逃', () {
    test('玩家贴到鱼身边，它就不再是巡游状态', () {
      final fauna = build();
      // 站到第 3 条鱼身上。
      final player = vm.Vector3(fauna.fishX(3), 0, fauna.fishZ(3));
      fauna.advance(_dt, player);

      expect(fauna.fishMood(3), isNot(FishMood.cruising),
          reason: '玩家站在它头上它还在悠哉巡游');
    });

    test('受惊的鱼确实在远离玩家', () {
      final fauna = build();
      // 玩家**站着不动**（真实的"人站在岸边"），鱼应当自己游开。
      // 若让玩家一路跟着它走，鱼永远被顶在原地 —— 那测的是追踪，不是惊逃。
      final player = vm.Vector3(fauna.fishX(3), 0, fauna.fishZ(3));
      fauna.advance(_dt, player);

      if (fauna.fishMood(3) != FishMood.startled) {
        // 被惊得直接跳出水面的那个分支：不归这条用例管（见"跃出水面"那组）。
        return;
      }

      double distance() => math.sqrt(
            math.pow(fauna.fishX(3) - player.x, 2) +
                math.pow(fauna.fishZ(3) - player.z, 2),
          );

      final before = distance();
      for (var frame = 0; frame < 30; frame++) {
        fauna.advance(_dt, player);
      }
      final after = distance();

      expect(after, greaterThan(before + 0.2),
          reason: '受惊后距离从 $before 变成了 $after —— 逃的方向反了或根本没动');
    });
  });

  group('跃出水面', () {
    test('鱼会自发跃出，落水时报告入水事件；入水点在水里、参数合理', () {
      final fauna = build();

      var airborneSeen = 0;
      var splashes = 0;
      final strengths = <double>[];
      final sizes = <double>[];

      // 玩家远远站着（不惊扰）：这里测的是**自发**跃出 —— 也就是"玩家走到
      // 河边站着不动，鱼会不会自己蹦出来"。靠"靠近才惊跳"的路径在实机里
      // 几乎等于没有（玩家不动，河就是静止的）。
      for (var frame = 0; frame < 2400 && splashes == 0; frame++) {
        fauna.advance(_dt, farAway);

        for (var i = 0; i < fauna.fishCount; i++) {
          if (fauna.fishIsAirborne(i)) airborneSeen++;
        }
        for (var k = 0; k < fauna.splashCount; k++) {
          final s = fauna.splashes[k];
          expect(flow.isInWater(s.x, s.z), isTrue,
              reason: '入水点不在水里 —— 鱼是飞到岸上落下来的');
          splashes++;
          strengths.add(s.strength);
          sizes.add(s.size);
        }
      }

      expect(airborneSeen, greaterThan(0), reason: '一次都没跳出过水面');
      expect(splashes, greaterThan(0), reason: '跃出之后没有落水事件');
      for (final v in strengths) {
        expect(v, inInclusiveRange(0.05, 0.45),
            reason: '涟漪强度超出水面涟漪能表达的范围');
      }
      for (final v in sizes) {
        expect(v, inInclusiveRange(0.2, 0.5), reason: '肇事鱼的体长不合理');
      }
    });

    test('跃出的鱼一定会回到水里（不会一直卡在空中）', () {
      final fauna = build();
      final everBreached = List<bool>.filled(fauna.fishCount, false);

      for (var frame = 0; frame < 2400; frame++) {
        fauna.advance(_dt, farAway);
        for (var i = 0; i < fauna.fishCount; i++) {
          if (fauna.fishMood(i) == FishMood.breaching) everBreached[i] = true;
        }
      }

      expect(everBreached.where((b) => b), isNotEmpty,
          reason: '这段时间里没有任何一条鱼跃出过');

      // 再跑 3 秒：跃出全程不到 1 秒，这足够任何一条在空中的鱼落回来。
      // 这样断言"结束时没有鱼在空中"才是确定的 —— 直接在主循环末尾检查会
      // 因为"恰好有一条正在跳"而偶发失败。
      for (var frame = 0; frame < 180; frame++) {
        fauna.advance(_dt, farAway);
      }
      for (var i = 0; i < fauna.fishCount; i++) {
        expect(fauna.fishIsAirborne(i), isFalse,
            reason: '第 $i 条鱼在模拟结束时还在水面上 —— 落水判定失效');
        expect(fauna.fishMood(i), isNot(FishMood.breaching));
      }
    });
  });

  group('确定性与诊断', () {
    test('同 seed 的两份世界，跑同样的帧数后逐条一致', () {
      final a = build(seed: 4242);
      final b = build(seed: 4242);

      for (var frame = 0; frame < 240; frame++) {
        a.advance(_dt, farAway);
        b.advance(_dt, farAway);
      }

      for (var i = 0; i < a.fishCount; i++) {
        expect(a.fishX(i), b.fishX(i), reason: '第 $i 条鱼的 x 不一致');
        expect(a.fishZ(i), b.fishZ(i), reason: '第 $i 条鱼的 z 不一致');
        expect(a.fishMood(i), b.fishMood(i));
      }
      for (var i = 0; i < a.shrimpCount; i++) {
        expect(a.shrimpX(i), b.shrimpX(i));
        expect(a.shrimpZ(i), b.shrimpZ(i));
      }
    });

    test('换 seed 会换一片鱼的分布', () {
      final a = build(seed: 1);
      final b = build(seed: 2);
      var differing = 0;
      for (var i = 0; i < a.fishCount; i++) {
        if ((a.fishX(i) - b.fishX(i)).abs() > 1e-9) differing++;
      }
      expect(differing, greaterThan(a.fishCount ~/ 2));
    });

    test('counts 反映真实实例数（鱼是身体 + 尾鳍两个实例）', () {
      final fauna = build(fish: 10, shrimp: 6);
      final counts = fauna.counts;
      expect(counts['fish'], 10);
      expect(counts['shrimp'], 6);
      expect(counts['faunaInstances'], 10 * 2 + 6);
    });
  });
}
