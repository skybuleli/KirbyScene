# 传送伪速度与音频混音停滞

## 证据范围

原应用两次在坐标序列 `24,30,0,-40,70,-90`（z=0）的第 6 点之后无应答。
实际下发过 `velocity=(-2820.06,-3.53,0)`。先前线程采样在
`../audio-lifecycle/stall-sample.txt`：主线程等待 `update3dAudio` 的锁，音频线程在 WAV 混音。

单线程原生复现直接编译当前依赖 SoLoud 核心、WAV 和 NULL 后端，不依赖窗口／CoreAudio。
同一空间位置下，0、-12、+2820.06m/s 混音均完成；-2820.06m/s 在 3 秒外部超时内无法完成。
结果见 `native-results.txt`。这排除了“必须由两个应用线程的锁顺序才能触发”的解释；
不宣称已定位重采样器内部的精确循环缺陷。探针的 getSamplerate 返回基础采样率，
不是多普勒修正后的采样率，不能拿它证明倍率不变。

## 复现命令

在项目根运行（需 clang++，依赖缓存版本为 4.1.7）：

```bash
S=/Users/liliang/.pub-cache/hosted/pub.dev/flutter_soloud-4.1.7/src/soloud
clang++ -std=c++17 -O1 -DWITH_NULL -DNO_XIPH_LIBS \
  -I"$S/include" -I"$S/src/audiosource/wav" \
  docs/verification/audio-velocity/audio_velocity_probe.cpp \
  docs/verification/audio-velocity/probe_mp3.cpp \
  "$S"/src/core/*.cpp "$S"/src/backend/null/*.cpp \
  "$S"/src/audiosource/wav/*.cpp -o build/audio_velocity_probe
python3 - <<'PY'
import subprocess
for velocity in ['0', '-12', '-2820.06', '2820.06']:
    try:
        r = subprocess.run(['build/audio_velocity_probe', velocity],
                           capture_output=True, text=True, timeout=3)
        print(velocity, r.returncode, r.stdout)
    except subprocess.TimeoutExpired:
        print(velocity, '混音超时（由宿主终止探针）')
PY
```

## 应用修复与验证

- `AudioMotion` 拒绝超出 64m/s 的角色位移速度、无效时间与非有限数据。
- 传送／重玩显式重置采样；保留正常奔跑／跳跃速度与 3D 声像／多普勒。
- 移除临时 2D 开关；未修改 SoLoud 缓存源码、未加锁或引擎重置看门狗。
- `velocity-tests.log`：195 项测试全部通过；分析零问题，macOS debug 构建成功。
- `velocity-teleport.log`：默认 3D 配置 72 次传送通过，最终存在活跃声部及非零输出。
- `velocity-audio.log`：原审计 37/37 通过，静音前 0.0030 → 静音后 0。
- 后续两次重复审计均因帧不推进判负（`teleport-repeat*.log`），未继续执行后面的玩法／天气。
  `recheck-sample.txt` 显示主线程在事件等待，不是原音频锁等待；连续 state 均应答，帧恒 4686。
  尚不能称为持续前台稳定性验收通过，也不能将这两次判负抹去。

原 `build/` 与 `.dart_tool/` 在本轮开始时缺失，曾造成启动文件不存在／依赖未解析。
已重新 pub get 和构建；不是新增代码导致 2150 个真实语义错误。
2D A/B 运行未成功开展，不用它作为因果证据。

## 补充对照及未完成项

- `filtered_motion_probe.dart` 调用实际 Dart `AudioMotion`，对 72 个 70↔-71 的跳变
  生成过滤后的速度，再分别交给原生混音探针：72/72 完成（`filtered-native-results.txt`）。
  NULL 后端无法测量音频设备 underrun，不宣称硬件无欠载。
- `teleport-idle.log`：另加每次传送前 500ms 空闲的对照，在第 39 次因帧未推进判负；
  后续 state 持续应答，帧恒 5784、音频速度为 0。这不是一次额外的成功验收。
- 对该停帧点连续五次各 1 秒原生采样（本地 `build/frame-stall-samples/`），
  未见 `update3dAudio`；主线程与 raster 线程均在事件等待。不能据此命名为 Impeller 死锁。
- 最后的无输入新进程对照未执行成功：退出旧进程后，LaunchServices 的 `open`
  返回 -600，没有新帧数据。没有进行代码回退或归因；本轮最后未确认 App 重新运行。

