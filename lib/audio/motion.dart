import 'package:vector_math/vector_math.dart' as vm;

/// 音频使用的角色运动采样；传送、重生不是物理运动。
class AudioMotion {
  /// 当前角色奔跑约 12m/s，跳跃初速 8.5m/s；为落地和坡面留足余量。
  /// 超出该范围视为位置跳变，不能作为多普勒或脚步输入。
  static const maxSpeed = 64.0;

  final velocity = vm.Vector3.zero();
  final _previous = vm.Vector3.zero();
  bool _hasPrevious = false;

  void reset() {
    _hasPrevious = false;
    velocity.setZero();
  }

  void update(double dt, vm.Vector3 position) {
    velocity.setZero();
    if (!position.x.isFinite || !position.y.isFinite || !position.z.isFinite) {
      reset();
      return;
    }
    if (_hasPrevious && dt.isFinite && dt > 1e-4) {
      velocity
        ..setFrom(position)
        ..sub(_previous)
        ..scale(1 / dt);
      final speedSquared = velocity.length2;
      if (!speedSquared.isFinite || speedSquared > maxSpeed * maxSpeed) {
        velocity.setZero();
      }
    }
    _previous.setFrom(position);
    _hasPrevious = true;
  }
}
