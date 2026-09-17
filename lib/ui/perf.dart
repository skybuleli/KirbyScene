/// 帧计时纯数据与统计。raster 是栅格线程耗时，不等于 GPU 执行时间。
library;

class FrameTimingSample {
  const FrameTimingSample({
    required this.startMicros,
    required this.buildMicros,
    required this.rasterMicros,
  });

  final int startMicros;
  final int buildMicros;
  final int rasterMicros;
}

class PerfWindow {
  const PerfWindow({
    required this.frames,
    required this.seconds,
    required this.uiAvgMs,
    required this.uiP95Ms,
    required this.rasterAvgMs,
    required this.rasterP95Ms,
  });

  final int frames;
  final double seconds;
  final double uiAvgMs;
  final double uiP95Ms;
  final double rasterAvgMs;
  final double rasterP95Ms;

  /// N 帧只有 N-1 个帧起始间隔，不能将样本数直接当 FPS。
  double get fps => (frames - 1) / seconds;
}

/// 按实际帧起始时间跨度聚合，包含后台停帧间隔，不会把停帧伪装成高 FPS。
/// p95 采用最近秩定义：ceil(0.95 * N) - 1。
PerfWindow? aggregatePerf(Iterable<FrameTimingSample> samples) {
  final list = samples.toList()
    ..sort((a, b) => a.startMicros.compareTo(b.startMicros));
  if (list.length < 2) return null;
  final span = list.last.startMicros - list.first.startMicros;
  if (span <= 0) return null;
  final ui = list.map((s) => s.buildMicros).toList()..sort();
  final raster = list.map((s) => s.rasterMicros).toList()..sort();
  final rank = (list.length * 0.95).ceil() - 1;
  double average(List<int> values) =>
      values.fold<int>(0, (a, b) => a + b) / values.length / 1000;
  return PerfWindow(
    frames: list.length,
    seconds: span / 1000000,
    uiAvgMs: average(ui),
    uiP95Ms: ui[rank] / 1000,
    rasterAvgMs: average(raster),
    rasterP95Ms: raster[rank] / 1000,
  );
}

String formatPerfLine(PerfWindow p) =>
    'fps ${p.fps.toStringAsFixed(1)} · ui ${p.uiAvgMs.toStringAsFixed(1)}ms '
    '· raster ${p.rasterAvgMs.toStringAsFixed(1)}ms';

String formatPerfLog(PerfWindow p) =>
    '[PERF] fps=${p.fps.toStringAsFixed(1)} frames=${p.frames} '
    'window=${p.seconds.toStringAsFixed(3)}s '
    'ui=${p.uiAvgMs.toStringAsFixed(2)}ms p95ui=${p.uiP95Ms.toStringAsFixed(2)}ms '
    'raster=${p.rasterAvgMs.toStringAsFixed(2)}ms '
    'p95raster=${p.rasterP95Ms.toStringAsFixed(2)}ms';
