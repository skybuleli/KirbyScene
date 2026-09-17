import 'package:flutter_test/flutter_test.dart';
import 'package:kirby_scene/audio/motion.dart';
import 'package:vector_math/vector_math.dart' as vm;

void main() {
  test('首次采样与显式传送重置不产生假速度', () {
    final motion = AudioMotion();
    motion.update(0.02, vm.Vector3(100, 0, 0));
    expect(motion.velocity.length, 0);
    motion.update(0.02, vm.Vector3(100.1, 0, 0));
    expect(motion.velocity.x, closeTo(5, 0.001));
    motion.reset();
    motion.update(0.02, vm.Vector3(-100, 0, 0));
    expect(motion.velocity.length, 0);
  });

  test('记录到的 70 到 -71 传送拒绝为速度，下一帧恢复正常', () {
    final motion = AudioMotion();
    motion.update(0.05, vm.Vector3(70, 0, 0));
    motion.update(0.05, vm.Vector3(-71, 0, 0));
    expect(motion.velocity.length, 0);
    motion.update(0.05, vm.Vector3(-70.5, 0, 0));
    expect(motion.velocity.x, closeTo(10, 0.001));
  });

  test('速度边界按三维模长判定，正常跳跃与奔跑保留', () {
    final motion = AudioMotion();
    motion.update(1, vm.Vector3.zero());
    motion.update(1, vm.Vector3(11.7, 8.5, 0));
    expect(motion.velocity.x, closeTo(11.7, 0.001));
    expect(motion.velocity.y, closeTo(8.5, 0.001));
    motion.update(1, vm.Vector3(61.7, 58.5, 0));
    expect(motion.velocity.length, 0);
  });

  test('无效时间和非有限位置不泄漏旧速度或 NaN', () {
    for (final dt in [0.0, -1.0, double.nan, double.infinity, 1e-6]) {
      final motion = AudioMotion();
      motion.update(1, vm.Vector3.zero());
      motion.update(1, vm.Vector3(5, 0, 0));
      motion.update(dt, vm.Vector3(6, 0, 0));
      expect(motion.velocity.length, 0);
    }
    for (final x in [double.nan, double.infinity, double.negativeInfinity]) {
      final motion = AudioMotion();
      motion.update(1, vm.Vector3.zero());
      motion.update(1, vm.Vector3(x, 0, 0));
      expect(motion.velocity.length, 0);
      motion.update(1, vm.Vector3(100, 0, 0));
      expect(motion.velocity.length, 0);
    }
  });
}
