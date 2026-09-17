/// 游戏 HUD：收集进度、天气、操作提示与通关横幅。
///
/// 刻意不做成 3D 世界内的文本（那需要 `WidgetComponent` 去渲染到纹理），
/// 阶段一用普通的 Flutter 覆盖层最省也最清晰。

library;
import 'dart:ui' show FramePhase;

import 'package:flutter/foundation.dart' show debugPrint, kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../game/sky.dart';
import '../game/world.dart';
import 'perf.dart';

const _kPink = Color(0xFFFF9EC4);
const _kGold = Color(0xFFFFD54F);

class GameHud extends StatelessWidget {
  const GameHud({super.key, required this.world, this.demoMode = false});

  final KirbyWorld world;

  /// 自动演示模式（URL `?demo=1`）：底部提示会改成演示说明。
  final bool demoMode;

  @override
  Widget build(BuildContext context) {
    final total = world.pickups.length;
    final progress = total == 0 ? 0.0 : world.score / total;

    return Stack(
      children: [
        // 左上：标题 + 收集进度
        Positioned(
          left: 18,
          top: 16,
          child: _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'KirbyScene',
                  style: TextStyle(
                    color: _kPink,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 2),
                const Text(
                  '星空草原 · 第一阶段',
                  style: TextStyle(color: Colors.white70, fontSize: 11),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Icon(Icons.star_rounded, color: _kGold, size: 18),
                    const SizedBox(width: 6),
                    Text(
                      '${world.score} / $total',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                SizedBox(
                  width: 148,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 5,
                      backgroundColor: Colors.white24,
                      valueColor: const AlwaysStoppedAnimation(_kGold),
                    ),
                  ),
                ),
                // 诊断行只在演示模式显示：相机跟随角色，光看画面判断不出
                // 角色有没有真的在走（无头抓帧时尤其容易误判）。
                if (demoMode) ...[
                  const SizedBox(height: 5),
                  Text(
                    'node(${world.player.position.x.toStringAsFixed(1)},'
                    '${world.player.position.z.toStringAsFixed(1)}) · '
                    'ctrl(${world.controller.debugX.toStringAsFixed(1)},'
                    '${world.controller.debugZ.toStringAsFixed(1)}) · '
                    'n=${world.controller.updateCount} · '
                    't=${world.elapsedTime.toStringAsFixed(1)}s',
                    style: const TextStyle(color: Colors.white38, fontSize: 9.5),
                  ),
                ],
                // 显式开启诊断才挂计时回调，不影响默认 HUD 或发布版。
                if (!kReleaseMode && const bool.fromEnvironment('KIRBY_PERF')) ...[
                  const SizedBox(height: 5),
                  _PerfLine(world: world),
                ],
              ],
            ),
          ),
        ),

        // 右上：天气
        Positioned(
          right: 18,
          top: 16,
          child: _Card(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_weatherIcon(world.sky.kind), color: _kPink, size: 18),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      world.weatherLabel,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Text(
                      '按 1 / 2 / 3 或 T 切换',
                      style: TextStyle(color: Colors.white54, fontSize: 10),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),

        // 底部：操作提示
        Positioned(
          left: 0,
          right: 0,
          bottom: 14,
          child: Center(
            child: _Pill(
              text: demoMode
                  ? '自动演示中（?demo=1）· 键盘仍可随时接管'
                  : 'WASD 移动 · Shift 加速 · 空格跳跃 · 拖拽转视角 · 滚轮缩放 · R 重开',
            ),
          ),
        ),

        // 通关横幅
        if (world.cleared)
          Positioned.fill(
            child: IgnorePointer(
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 34, vertical: 22),
                  decoration: BoxDecoration(
                    color: const Color(0xE62A1B2E),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: _kGold, width: 1.5),
                    boxShadow: const [
                      BoxShadow(color: Color(0x88000000), blurRadius: 28),
                    ],
                  ),
                  child: const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.auto_awesome, color: _kGold, size: 34),
                      SizedBox(height: 10),
                      Text(
                        '全部星核已收集！',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(height: 6),
                      Text(
                        '按 R 再玩一次',
                        style: TextStyle(color: Colors.white70, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  static IconData _weatherIcon(WeatherKind kind) => switch (kind) {
        WeatherKind.clear => Icons.wb_sunny_rounded,
        WeatherKind.cloudy => Icons.cloud_rounded,
        WeatherKind.rain => Icons.grain_rounded,
        WeatherKind.night => Icons.nightlight_rounded,
      };
}

/// 使用引擎给出的帧起始时间聚合两秒窗口，避免回调批量送达影响 FPS。
/// raster 是栅格线程耗时，不应标为纯 GPU 时间。
class _PerfLine extends StatefulWidget {
  const _PerfLine({required this.world});
  final KirbyWorld world;

  @override
  State<_PerfLine> createState() => _PerfLineState();
}

class _PerfLineState extends State<_PerfLine> {
  final List<FrameTimingSample> _samples = [];
  String _text = '等待帧计时…';

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    super.dispose();
  }

  void _onTimings(List<FrameTiming> timings) {
    if (!mounted) return;
    for (final t in timings) {
      _samples.add(FrameTimingSample(
        startMicros: t.timestampInMicroseconds(FramePhase.buildStart),
        buildMicros: t.buildDuration.inMicroseconds,
        rasterMicros: t.rasterDuration.inMicroseconds,
      ));
    }
    if (_samples.length < 2 ||
        _samples.last.startMicros - _samples.first.startMicros < 2000000) {
      return;
    }
    final window = aggregatePerf(_samples);
    _samples.clear();
    if (window == null) return;
    _text = formatPerfLine(window);
    debugPrint('${formatPerfLog(window)} weather=${widget.world.sky.kind.name}');
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => Text(
        _text,
        style: const TextStyle(color: Colors.white54, fontSize: 9.5),
      );
}

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: const Color(0xCC1B1220),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0x33FF9EC4)),
      ),
      child: child,
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xB31B1220),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: const TextStyle(color: Colors.white70, fontSize: 11.5),
      ),
    );
  }
}
