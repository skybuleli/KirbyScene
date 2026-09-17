import 'dart:convert';
import 'package:kirby_scene/audio/motion.dart';
import 'package:vector_math/vector_math.dart' as vm;

void main() {
  final motion = AudioMotion();
  final velocities = <double>[];
  motion.update(0.05, vm.Vector3(70, 0, 0));
  for (var i = 0; i < 72; i++) {
    // 不依赖显式 reset，直接验证过滤器能阻止原先的极端跳变。
    motion.update(0.05, vm.Vector3(i.isEven ? -71 : 70, 0, 0));
    velocities.add(motion.velocity.x);
  }
  print(jsonEncode(velocities));
}
