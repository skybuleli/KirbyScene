import 'package:flutter_test/flutter_test.dart';
import 'package:kirby_scene/ui/perf.dart';

void main() {
  FrameTimingSample sample(int start, int build) => FrameTimingSample(
    startMicros: start,
    buildMicros: build,
    rasterMicros: 5000,
  );

  test('实际时间跨度决定 FPS，停帧不能被当成正常一秒窗口', () {
    final normal = aggregatePerf([
      sample(0, 1000),
      sample(500000, 3000),
      sample(1000000, 2000),
    ])!;
    final stalled = aggregatePerf([
      sample(0, 1000),
      sample(500000, 3000),
      sample(10000000, 2000),
    ])!;
    expect(normal.fps, 2);
    expect(stalled.fps, 0.2);
    expect(normal.uiAvgMs, 2);
    expect(normal.uiP95Ms, 3);
    expect(normal.rasterAvgMs, 5);
  });

  test('空窗口、单帧、零跨度没有有效 FPS', () {
    expect(aggregatePerf([]), isNull);
    expect(aggregatePerf([sample(0, 1000)]), isNull);
    expect(aggregatePerf([sample(0, 1000), sample(0, 2000)]), isNull);
  });

  test('p95 使用最近秩，21 帧取第 20 个而不是第 19 个', () {
    final window = aggregatePerf(
      List.generate(21, (i) => sample(i * 50000, (i + 1) * 1000)),
    )!;
    expect(window.uiP95Ms, 20);
    expect(window.fps, 20);
    expect(window.rasterP95Ms, 5);
  });

  test('固定窗口的 HUD 与日志输出格式完全匹配', () {
    const window = PerfWindow(
      frames: 61,
      seconds: 1,
      uiAvgMs: 4.25,
      uiP95Ms: 8.5,
      rasterAvgMs: 6.25,
      rasterP95Ms: 12.5,
    );
    final hud = formatPerfLine(window);
    final log = formatPerfLog(window);

    expect(hud, 'fps 60.0 · ui 4.3ms · raster 6.3ms', reason: 'HUD 实际输出：$hud');
    expect(
      log,
      '[PERF] fps=60.0 frames=61 window=1.000s '
      'ui=4.25ms p95ui=8.50ms raster=6.25ms p95raster=12.50ms',
      reason: '日志实际输出：$log',
    );
  });
}
