/// 程序化 PCM 合成的**公共底座**：噪声源、滤波器系数、无缝循环、WAV 编码。
///
/// 这一层刻意不 import Flutter、不 import 任何音频库 —— 波形就是一段
/// `Float64List`，于是"接缝连不连续""频谱对不对""响度有没有超标"全部可以在
/// `flutter test` 里断言，而不需要扬声器。整个 `lib/audio/` 的所有合成器都
/// 复用这里的原语，所以"无缝循环"这件事只有一处实现、一处修。
///
/// ## 为什么本项目要自己合成声音
///
/// 硬约束是**零美术资产**：地形、草、天空、水、水草全是程序化生成的，音频没有
/// 理由例外。一个 `rain.wav` 既是二进制资产，又是"只能是一种雨势"的死物；
/// 合成则顺手得到两个真东西：
///
///   * **同一份物理量的听觉版本**：雨的强度、风的阵性、河水的急缓都来自
///     驱动画面的同一批参数，画面与声音不是两套各调各的旋钮；
///   * **可测**：见上。
library;
import 'dart:math' as math;
import 'dart:typed_data';

/// Park–Miller 线性同余噪声源。
///
/// 刻意用**全浮点**运算（而不是 `& 0x7fffffff` 那种位掩码）：在 dart2js 下
/// `int` 是 double，位运算会走 JS 的 ToInt32，语义与 VM 不一致 —— 噪声一旦
/// "Web 与原生生成得不一样"，同一段循环在两端的音色就会不同。
/// 48271 × 2²¹ ≈ 1.0e14，远小于 2⁵³，double 里精确。
class PcmRng {
  PcmRng(int seed) : _state = (seed.abs() % 2147483646) + 1.0;

  double _state;

  /// 白噪声样本，范围 [-1, 1)。
  double white() {
    _state = (_state * 48271.0) % 2147483647.0;
    return _state / 1073741823.5 - 1.0;
  }

  /// [0, 1) 的均匀随机数。
  double unit() => (white() + 1.0) * 0.5;

  /// [-1, 1) 之间的均匀随机数（与 [white] 同义，语义化别名）。
  double bipolar() => white();
}

/// 一阶低通滤波器的系数（`y += (x - y) * a`），对应 -3dB 截止频率 [cutoffHz]。
double onePoleAlpha(double cutoffHz, int sampleRate) =>
    1.0 - math.exp(-2.0 * math.pi * cutoffHz / sampleRate);

/// 一阶高通：`y = a * (yPrev + x - xPrev)`，对应截止频率 [cutoffHz]。
///
/// 雨声与风声的"空气感"全在高频，低频必须削掉：不削的话声音会发闷，
/// 而且低频能量在电平表上占绝对多数，高频细节就被压没了。
double onePoleHighPassAlpha(double cutoffHz, int sampleRate) {
  final rc = 1.0 / (2.0 * math.pi * cutoffHz);
  final dt = 1.0 / sampleRate;
  return rc / (rc + dt);
}

/// 把频率吸附到"循环长度内的整数个周期"。
///
/// 循环音频里任何周期性成分都必须满足这一点：`f × seconds` 取整后落在循环
/// 边界上，`sin(2πf·t)` 在 t=0 与 t=seconds 处的相位才相同，包络才不会在每次
/// 循环时"重置"一下（听感上就是断断续续）。这是"无缝"的必要条件之一。
double loopLockedFreq(double freqHz, double seconds) {
  final cycles = math.max(1, (freqHz * seconds).round());
  return cycles / seconds;
}

/// 缓冲的峰值绝对值。
double peakOf(Float64List buf) {
  var m = 0.0;
  for (final v in buf) {
    final a = v.abs();
    if (a > m) m = a;
  }
  return m;
}

/// 缓冲的均方根。响度比较看它，而不是峰值：峰值一样的两段噪声，宽带的听起来
/// 会比窄带的响得多（等峰值不代表等响度）。
double rmsOf(Float64List buf) {
  if (buf.isEmpty) return 0;
  var s = 0.0;
  for (final v in buf) {
    s += v * v;
  }
  return math.sqrt(s / buf.length);
}

/// 把波形峰值缩放到 [peak]（避免削顶，也保证不同参数下响度大致可比）。
/// 返回实际使用的缩放系数。
double normalizePeak(Float64List buf, double peak) {
  final m = peakOf(buf);
  if (m < 1e-9) return 1.0;
  final k = peak / m;
  for (var i = 0; i < buf.length; i++) {
    buf[i] *= k;
  }
  return k;
}

/// overlap-add：把尾部 [tail] 段交叉淡入到开头，取前 [n] 个样本后首尾连续。
///
/// 循环音频最容易翻车的地方就是接缝：滤波器的瞬态、气泡的尾巴都会在首尾错位。
/// 做法是**多生成一段尾巴再交叉淡化**，于是 `out[n-1] → out[0]` 处的波形连续，
/// 引擎的采样级循环听不出接缝。
void foldTail(Float64List buf, int n, int tail) {
  final len = math.min(tail, buf.length - n);
  for (var i = 0; i < len; i++) {
    final k = i / len;
    buf[i] = buf[i] * k + buf[n + i] * (1.0 - k);
  }
}

/// 合成一段**无缝循环**：[seconds] 秒的样本范围 [-1, 1]。
///
/// [generate] 拿到长度为 `n + tail` 的缓冲与总长度，自己填样本即可；本函数负责
/// overlap-add 折叠与峰值归一。返回长度恰好为 `n` 的视图。
Float64List seamlessLoop({
  required double seconds,
  required int sampleRate,
  required PcmRng rng,
  required void Function(Float64List buf, int total, PcmRng rng) generate,
  double tailSeconds = 0.30,
  double peak = 0.92,
}) {
  final n = math.max(1, (seconds * sampleRate).round());
  final tail = math.max(1, (tailSeconds * sampleRate).round());
  final total = n + tail;
  final buf = Float64List(total);
  generate(buf, total, rng);
  normalizePeak(buf, peak);
  foldTail(buf, n, tail);
  return Float64List.sublistView(buf, 0, n);
}

/// 编码成 16-bit 单声道 PCM 的 WAV 字节。
///
/// 走 `ByteData` 手工写头（44 字节）：不引第三方编码库，也就不会有"Web 上编码器
/// 行为不同"的意外。
Uint8List encodeWav16(Float64List samples, {required int sampleRate}) {
  const headerBytes = 44;
  final dataBytes = samples.length * 2;
  final out = Uint8List(headerBytes + dataBytes);
  final view = ByteData.view(out.buffer);

  _writeAscii(out, 0, 'RIFF');
  view.setUint32(4, 36 + dataBytes, Endian.little);
  _writeAscii(out, 8, 'WAVE');
  _writeAscii(out, 12, 'fmt ');
  view.setUint32(16, 16, Endian.little); // fmt 块长度
  view.setUint16(20, 1, Endian.little); // PCM
  view.setUint16(22, 1, Endian.little); // 单声道
  view.setUint32(24, sampleRate, Endian.little);
  view.setUint32(28, sampleRate * 2, Endian.little); // 字节率
  view.setUint16(32, 2, Endian.little); // 块对齐
  view.setUint16(34, 16, Endian.little); // 位深
  _writeAscii(out, 36, 'data');
  view.setUint32(40, dataBytes, Endian.little);

  for (var i = 0; i < samples.length; i++) {
    final v = (samples[i].clamp(-1.0, 1.0) * 32767.0).round();
    view.setInt16(headerBytes + i * 2, v, Endian.little);
  }
  return out;
}

void _writeAscii(Uint8List out, int offset, String text) {
  for (var i = 0; i < text.length; i++) {
    out[offset + i] = text.codeUnitAt(i);
  }
}

/// 等功率交叉淡化的两个权重（`a² + b² == 1`）。
///
/// 用线性淡化（0.5/0.5）会让中点掉 3dB，听感上"经过档位时音量顿一下"；
/// 等功率则保持总功率不变，于是任何两档之间的过渡都是平的。
({double a, double b}) equalPower(double f) {
  final theta = f.clamp(0.0, 1.0) * math.pi * 0.5;
  return (a: math.cos(theta), b: math.sin(theta));
}

/// 一阶平滑（指数逼近）。`tau` 是时间常数（秒），95% 到位约需 3τ。
double smoothTowards(double current, double target, double dt, double tau) {
  if (tau <= 1e-6) return target;
  final k = 1.0 - math.exp(-dt / tau);
  return current + (target - current) * k;
}

/// 把"淡入淡出时长"换算成平滑时间常数。
///
/// 对外暴露的是**时长**（"0.8 秒淡入"是人能理解的说法），内部用指数逼近：
/// 3τ ≈ 95%，于是 `tau = seconds / 3`。
double tauForFadeSeconds(double seconds) => math.max(seconds / 3.0, 1e-4);
