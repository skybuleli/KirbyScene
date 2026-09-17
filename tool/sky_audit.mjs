#!/usr/bin/env node
// 天空验收：**截图（带帧前进判据）→ 客观度量 → ASCII 目视**，一条命令走完。
//
// 为什么需要它：天气/天空这类改动是"看起来怎么样"的问题，而我们（agent）看不到画面。
// 于是验收只能落在两件事上：**可复现的截图**，以及**能从像素反推的客观量**。
// 这个脚本把上一轮的三个临时脚本（build/sky_stats、build/cloud_check、build/sky_ascii）
// 合成一个，并补上截图侧最贵的那条教训 —— **帧前进判据**。
//
// ## 两个必须记住的坑（都是实测踩出来的，别删）
//
// 1. **窗口不在前台时帧循环会冻结**，`screenshot` 仍然"成功"，但它是**同一帧**。
//    表现极像"改动没生效"或"性能崩了"（曾经量出 rain 只有 5fps）。
//    所以每次截图**前后各读一次 `state.frame`**，不前进就先拉前台重试。
// 2. **不能只取 R 通道当亮度**。夜空是饱和蓝（R≈0、B≈30），只取 R 会把
//    "深蓝夜空"量成"纯黑"，整张表就废了。这里一律算真亮度
//    `0.299R + 0.587G + 0.114B`。
//
// ## 解码器
//
// Flutter `toImage` 出的是 **16-bit** PNG，且逐行滤波。反滤波必须遍历**整行字节**
// （`x < stride`）：写成 `x < bpp` 只还原每行第一个像素，其余保持已滤波原值 ——
// 画面会变成椒盐噪点，而**整行均值、直方图、低分辨率 ASCII 看着全都正常**，
// 非常容易蒙混过关。本脚本已与 `sips -s format bmp`（macOS ImageIO）逐点校验一致。
//
// ## 用法
//
//     # 只分析已有截图（不需要 App 在跑）
//     node tool/sky_audit.mjs build/reverify/clear.png build/reverify/rain.png
//     node tool/sky_audit.mjs build/reverify/*.png --ascii
//     node tool/sky_audit.mjs build/reverify/night.png --ascii --hp   # 高通：减逐行中位数
//
//     # 逐档截图 + 度量（需要 App 在跑：tool/dev.sh --macos）
//     node tool/sky_audit.mjs --weathers clear,cloudy,rain,night
//     node tool/sky_audit.mjs --weathers rain --ascii --hp --fps
//
// 选项：
//     --weathers a,b,c   逐档 set_weather → 等过渡 → 校验帧前进 → 截图 → 度量
//     --camera YAW,PITCH 每档截图前先把相机摆回固定位姿（弧度，同 set_camera）。
//                        **跨版本比指标必须带它**：云在 8~46° 仰角上，
//                        俯角一变（默认 5.66° vs 平视 0°）天空带里看到的东西就不同，
//                        指标自然对不上（实测同一张地图 cloudy 的 σ 12.2 vs 18.1）。
//     --out-dir DIR      截图输出目录（默认 build/reverify）
//     --ascii            每个图额外打印 ASCII 天空带
//     --hp               ASCII 用**高通**渲染（减逐行中位数）。不传就是原图渲染。
//                        **强烈建议开**：天空本身是"上暗下亮"的强渐变，原图渲染时
//                        渐变会把字符表整个吃掉（近地平线那几行永远是 @），云看不出来。
//     --fps              逐档测帧率（需要 App；会先拉前台，否则量到的是冻结帧的假值）
//     --band F           天空带占画面高度的比例（默认 0.30）
//     --cols N --rows N  ASCII 分辨率（默认 128 x 26）
//     --fov N            相机竖直 fov（度，默认 60，与 world.dart 的 buildCamera 一致）
//     --pitch N          相机默认俯角（度，默认 5.66）—— 只用于 ASCII 右侧的仰角标注
//     --app PATH         用于 `open` 拉前台（默认 build/macos/.../kirby_scene.app）
//     --reps N           每档截图张数（默认 1）
//
// ## 判读时还要记住的三件事
//
// 1. **云指标对机位敏感**（云是离散的，8~46° 仰角）：同一版代码、只把 yaw 从
//    默认归到 0，cloudy 就从 σ18.1/亮云2.18% 变成 σ7.7/亮云0.00%。
//    跨版本比**必须用 `--camera` 归位**。
// 2. **窗口尺寸与长宽比也会变**（`open` 会把窗口恢复成默认大小：实测同一轮里
//    先 1600x1674、后 2880x1800）。fovY 固定、所以天空带的**仰角范围**不变，
//    但 fovX 随长宽比变 → 横向能看到的天空宽度不同 → 云量跟着变。
//    比指标前先把窗口尺寸固定住，并看一眼输出里的 `WxH`。
// 3. **夜景不要用"云量"解读这些数**：天空带里的星星/银河/月亮同样会被算进去
//    （实测夜空 `亮云` 高达 7%，那是一片弥散银河，不是云）。
//
// 判据（截图模式）：`state.ready` / 每档 `frame` 前进 / 截图非空。任一不过 → 退出码 1。

import net from 'node:net';
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { execFileSync } from 'node:child_process';

const PORT = Number(process.env.KIRBY_INPROC_PORT || 7008);
const args = process.argv.slice(2);
const opt = (name, def) => {
  const i = args.indexOf(name);
  return i > -1 && args[i + 1] && !args[i + 1].startsWith('--') ? args[i + 1] : def;
};
const has = (name) => args.includes(name);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const outDir = opt('--out-dir', 'build/reverify');
const weathers = opt('--weathers', '')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean);
const wantAscii = has('--ascii') || has('--hp');
const wantHp = has('--hp');
const wantFps = has('--fps');
// `--band` 之类的数值参数经 opt() 拿到的是字符串，统一在这里转。
const BAND = Number(opt('--band', 0.30));
const COLS = Number(opt('--cols', 128));
const ROWS = Number(opt('--rows', 26));
const FOV_DEG = Number(opt('--fov', 60));
const PITCH_DEG = Number(opt('--pitch', 5.66));
const REPS = Number(opt('--reps', 1));
// 相机位姿（yaw,pitch，弧度）。不传就不动相机。
const camera = opt('--camera', null)
  ?.split(',')
  .map((v) => Number(v));
const appPath = opt('--app', 'build/macos/Build/Products/Debug/kirby_scene.app');
// 位置参数里排除掉选项本身与其取值，剩下的就是待分析的 PNG。
const files = args.filter((a, i) => !a.startsWith('--')
  && !(i > 0 && args[i - 1].startsWith('--')));

// 画面上缘的仰角 = fov/2 − 俯角；往下每像素线性递减（透视相机下这就是近似解析式，
// 已在 MEMORY 里用实测核过：fov 60°、俯角 5.66° → 上缘 24.34°）。
const TOP_ELEV = FOV_DEG / 2 - PITCH_DEG;

// ------------------------------------------------------------------
// PNG 解码（16-bit / 8-bit，灰度 / RGB / RGBA）
// ------------------------------------------------------------------

function decodePNG(file) {
  const buf = fs.readFileSync(file);
  let off = 8;
  let w = 0;
  let h = 0;
  let bd = 0;
  let ct = 0;
  const idat = [];
  while (off < buf.length) {
    const len = buf.readUInt32BE(off);
    const type = buf.toString('ascii', off + 4, off + 8);
    const d = buf.subarray(off + 8, off + 8 + len);
    if (type === 'IHDR') {
      w = d.readUInt32BE(0);
      h = d.readUInt32BE(4);
      bd = d[8];
      ct = d[9];
    } else if (type === 'IDAT') idat.push(d);
    else if (type === 'IEND') break;
    off += 12 + len;
  }
  if (!w || !h) throw new Error(`${file} 不是可解析的 PNG`);

  const raw = zlib.inflateSync(Buffer.concat(idat));
  const ch = ct === 6 ? 4 : ct === 2 ? 3 : 1;
  const sb = bd / 8; // 每样本字节数
  const bpp = ch * sb; // 每像素字节数
  const stride = w * bpp; // 每行字节数（反滤波要按它遍历！）
  const lum = new Uint8Array(w * h);
  let prev = Buffer.alloc(stride);
  let p = 0;
  for (let y = 0; y < h; y++) {
    const ft = raw[p++];
    const cur = Buffer.from(raw.subarray(p, p + stride));
    p += stride;
    for (let x = 0; x < stride; x++) {
      const a = x >= bpp ? cur[x - bpp] : 0;
      const b = prev[x];
      const c = x >= bpp ? prev[x - bpp] : 0;
      let v = cur[x];
      if (ft === 1) v = (v + a) & 255;
      else if (ft === 2) v = (v + b) & 255;
      else if (ft === 3) v = (v + ((a + b) >> 1)) & 255;
      else if (ft === 4) {
        const pp = a + b - c;
        const pa = Math.abs(pp - a);
        const pb = Math.abs(pp - b);
        const pc = Math.abs(pp - c);
        v = (v + (pa <= pb && pa <= pc ? a : pb <= pc ? b : c)) & 255;
      }
      cur[x] = v;
    }
    // 高字节即位深归一化后的 8-bit 量级；亮度必须三通道合算（见文件头第 2 条坑）。
    for (let x = 0; x < w; x++) {
      const o = x * bpp;
      lum[y * w + x] = Math.round(
        0.299 * cur[o]
          + 0.587 * (ch > 1 ? cur[o + sb] : cur[o])
          + 0.114 * (ch > 2 ? cur[o + 2 * sb] : cur[o]),
      );
    }
    prev = cur;
  }
  return { file, w, h, bd, ct, ch, sb, bpp, lum };
}

// ------------------------------------------------------------------
// 度量
// ------------------------------------------------------------------

const pct = (n, d) => `${((n / d) * 100).toFixed(2)}%`;

function reportStats(d) {
  const { w, h, lum } = d;
  const n = w * h;
  let sum = 0;
  let dark = 0;
  let black = 0;
  let hi = 0;
  for (let i = 0; i < n; i++) {
    const v = lum[i];
    sum += v;
    if (v < 32) dark++;
    if (v < 8) black++;
    if (v > 170) hi++;
  }
  console.log(
    `全图    均值${(sum / n).toFixed(1)}  暗(<32)${pct(dark, n)}  近黑(<8)${pct(black, n)}`
      + `  高亮(>170)${pct(hi, n)}`,
  );

  const bh = Math.floor(h * BAND);
  const sky = [];
  for (let y = 0; y < bh; y++) for (let x = 0; x < w; x++) sky.push(lum[y * w + x]);
  const skyMean = sky.reduce((a, b) => a + b, 0) / sky.length;
  console.log(
    `天空带(y<${(BAND * 100) | 0}%)  均值${skyMean.toFixed(1)}`
      + `  近黑${pct(sky.filter((v) => v < 8).length, sky.length)}`,
  );

  let line = '行带均值(每5%)  ';
  for (let b = 0; b < 20; b++) {
    const y0 = Math.floor((h * b) / 20);
    const y1 = Math.max(y0 + 1, Math.floor((h * (b + 1)) / 20));
    let s = 0;
    let c = 0;
    for (let y = y0; y < y1; y++) for (let x = 0; x < w; x++) { s += lum[y * w + x]; c++; }
    line += `${(s / c).toFixed(0)} `;
  }
  console.log(line);
}

/// 云结构。云的像素特征不是"整体更亮"（阴天天空反而更暗），而是**团块状起伏**。
///
/// **指标必须分"亮云 / 暗云"两侧报**，因为云不一定比天空亮：
///   1. 晴天白云的实例色亮度约 0.7~1.0，而晴天天空本身就接近饱和白 ——
///      两者亮度几乎相等，**云真的会"隐入天空"**（同一机位实测：cloudy 的
///      "亮云"只有 0.00%，换成暗天空的雨天就是 2.37%）；
///   2. 逆光/背光侧的云比天空**更暗**，只看"更亮"会整个漏掉。
/// 所以判读要"亮云 + 暗云 + 总对比"三个一起看，必要时配 `--ascii` 目视。
///
/// 逐行减中位数是关键：天空是"上暗下亮"的强渐变，不做这一步，"近地平线更亮"
/// 会被误判成云。减掉之后剩下的就是"云相对同高度天空亮多少"。
function reportCloud(d) {
  const { w, h, lum } = d;
  const bh = Math.floor(h * BAND);
  if (bh < 4) return;

  const med = [];
  for (let y = 0; y < bh; y++) {
    const row = [];
    for (let x = 0; x < w; x++) row.push(lum[y * w + x]);
    row.sort((a, b) => a - b);
    med.push(row[row.length >> 1]);
  }

  const n = w * bh;
  const mask = new Uint8Array(n);
  let s = 0;
  let s2 = 0;
  let bright = 0;
  let dark = 0;
  for (let y = 0; y < bh; y++) {
    const m = med[y];
    for (let x = 0; x < w; x++) {
      const v = lum[y * w + x];
      s += v;
      s2 += v * v;
      if (v > m + 22) {
        bright++;
        mask[y * w + x] = 1;
      } else if (v < m - 22) {
        dark++;
      }
    }
  }
  const mean = s / n;
  const std = Math.sqrt(Math.max(0, s2 / n - mean * mean));

  // 最大 4-连通亮团：稀疏噪点连不成大团，能连成几百像素的才叫"一团云"。
  const seen = new Uint8Array(n);
  const stack = [];
  let best = 0;
  for (let i = 0; i < n; i++) {
    if (!mask[i] || seen[i]) continue;
    let size = 0;
    stack.length = 0;
    stack.push(i);
    seen[i] = 1;
    while (stack.length) {
      const q = stack.pop();
      size++;
      const x = q % w;
      const y = (q / w) | 0;
      if (x > 0 && mask[q - 1] && !seen[q - 1]) { seen[q - 1] = 1; stack.push(q - 1); }
      if (x < w - 1 && mask[q + 1] && !seen[q + 1]) { seen[q + 1] = 1; stack.push(q + 1); }
      if (y > 0 && mask[q - w] && !seen[q - w]) { seen[q - w] = 1; stack.push(q - w); }
      if (y < bh - 1 && mask[q + w] && !seen[q + w]) { seen[q + w] = 1; stack.push(q + w); }
    }
    if (size > best) best = size;
  }

  console.log(
    `云结构  起伏σ${std.toFixed(1)}  亮云${pct(bright, n)}  暗云${pct(dark, n)}`
      + `  总对比${pct(bright + dark, n)}  最大亮团${best}px(${pct(best, n)})`,
  );

  // 逐条带亮云占比：判断"云有没有铺满整条天空带"，而不是挤在某一段
  // （早期版本全部云团挤在带内顶部 1~2 条里，就是靠这个量发现的）。
  const SLICES = 8;
  let line = '  逐条带亮云%  ';
  for (let k = 0; k < SLICES; k++) {
    const y0 = Math.floor((bh * k) / SLICES);
    const y1 = Math.max(y0 + 1, Math.floor((bh * (k + 1)) / SLICES));
    let c = 0;
    let m = 0;
    for (let y = y0; y < y1; y++) {
      const mm = med[y];
      for (let x = 0; x < w; x++) { m++; if (lum[y * w + x] > mm + 22) c++; }
    }
    line += `${((c / m) * 100).toFixed(1)} `;
  }
  console.log(line);
}

/// ASCII 天空带。`hp = true` 走高通（减逐行中位数），云形一目了然；
/// 不传则按原图渲染（量程 = 带内 min..max）—— 后者能看整条渐变，但云会被淹没。
function reportAscii(d, hp) {
  const { w, h, lum } = d;
  const bh = Math.floor(h * BAND);
  if (bh < 4) return;

  const med = [];
  for (let y = 0; y < bh; y++) {
    const row = [];
    for (let x = 0; x < w; x++) row.push(lum[y * w + x]);
    row.sort((a, b) => a - b);
    med.push(row[row.length >> 1]);
  }
  const valAt = (y, x) => (hp ? lum[y * w + x] - med[y] : lum[y * w + x]);

  let mn = Infinity;
  let mx = -Infinity;
  for (let y = 0; y < bh; y++) {
    for (let x = 0; x < w; x++) {
      const v = valAt(y, x);
      if (v < mn) mn = v;
      if (v > mx) mx = v;
    }
  }
  const ramp = ' .:-=+*#%@';
  const span = Math.max(1, mx - mn);
  console.log(`  ASCII 天空带${hp ? '（高通：减逐行中位数）' : '（原图）'} 量程 ${mn}..${mx}`);
  for (let r = 0; r < ROWS; r++) {
    const y0 = Math.floor((bh * r) / ROWS);
    const y1 = Math.max(y0 + 1, Math.floor((bh * (r + 1)) / ROWS));
    let line = '';
    for (let c = 0; c < COLS; c++) {
      const x0 = Math.floor((w * c) / COLS);
      const x1 = Math.max(x0 + 1, Math.floor((w * (c + 1)) / COLS));
      let s = 0;
      let n = 0;
      for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) { s += valAt(y, x); n++; }
      line += ramp[
        Math.min(ramp.length - 1, Math.floor(((s / n - mn) / span) * ramp.length))
      ];
    }
    // 右侧标仰角：画面上缘 = fov/2 − 俯角，向下线性递减。
    const yMid = (y0 + y1) / 2;
    const elev = TOP_ELEV - (yMid / h) * FOV_DEG;
    console.log(`  ${line} ${elev.toFixed(1)}°`);
  }
}

function reportFile(file, { ascii = wantAscii, hp = wantHp } = {}) {
  let d;
  try {
    d = decodePNG(file);
  } catch (e) {
    console.error(`✗ ${file}: ${e.message}`);
    return false;
  }
  console.log(`\n=== ${file} ${d.w}x${d.h} bd=${d.bd} ct=${d.ct} ===`);
  reportStats(d);
  reportCloud(d);
  if (ascii) reportAscii(d, hp);
  return true;
}

// ------------------------------------------------------------------
// inproc 客户端（App 内回环端口 7008，协议见 lib/mcp/inproc_host_io.dart）
// ------------------------------------------------------------------

function call(payload, timeoutMs = 8000) {
  return new Promise((resolve, reject) => {
    const sock = net.createConnection({ host: '127.0.0.1', port: PORT });
    let buffer = '';
    let done = false;
    const finish = (fn) => {
      if (done) return;
      done = true;
      sock.destroy();
      fn();
    };
    sock.setTimeout(timeoutMs);
    // 协议按行分帧：请求必须带换行，否则服务端留在缓冲区永不回。
    sock.on('connect', () => sock.write(`${JSON.stringify(payload)}\n`));
    sock.on('data', (chunk) => {
      buffer += chunk.toString('utf8');
      const nl = buffer.indexOf('\n');
      if (nl === -1) return;
      let reply;
      try {
        reply = JSON.parse(buffer.slice(0, nl));
      } catch {
        return finish(() => reject(new Error(`非 JSON 响应：${buffer.slice(0, 120)}`)));
      }
      finish(() => resolve(reply));
    });
    sock.on('timeout', () =>
      finish(() => reject(new Error(`连接 ${PORT} 超时（App 没在跑？）`))));
    sock.on('error', (e) =>
      finish(() => reject(new Error(`连不上 127.0.0.1:${PORT} —— ${e.message}`))));
  });
}

const pullFrame = async () => (await call({ op: 'state' }))?.state?.frame ?? 0;

/// 把窗口拉到前台。帧循环在窗口不前台时冻结，而冻住的表现很像"改动没生效"
/// 或"性能崩了"，所以截图/测帧前主动尽力拉一次。
function bringToFront() {
  try {
    execFileSync('open', ['-a', path.resolve(appPath)], { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
}

/// 确认帧在推进；不推进才拉前台重试。
/// 返回 null 表示确实冻住了（调用方负责报错）。
///
/// **先看再拉**（而不是无条件拉）：`open -a` 会把窗口恢复成默认尺寸，
/// 于是同一轮里前面的截图是 1600x1674、后面的变成 2880x1800 —— fovX 随长宽比变，
/// 横向能看到的天空宽度就不同，指标跟着变（实测踩过）。没必要就别动窗口。
async function ensureRunning(label) {
  for (let i = 0; i < 3; i++) {
    const before = await pullFrame();
    await sleep(1200);
    const after = await pullFrame();
    if (after > before) return { before, after };
    console.log(`   ${label}：帧未前进（${before} → ${after}），拉前台重试…`);
    bringToFront();
    await sleep(2000);
  }
  console.error(`✗ ${label}：帧循环冻结（已拉前台重试 3 次）。`);
  return null;
}

// ------------------------------------------------------------------
// 主流程
// ------------------------------------------------------------------

async function main() {
  // ---- A) 逐档截图 ----
  if (weathers.length > 0) {
    fs.mkdirSync(outDir, { recursive: true });
    let ready;
    try {
      ready = await call({ op: 'state' }, 5000);
    } catch (e) {
      console.error(`✗ ${e.message}\n  截图模式需要 App 在跑： tool/dev.sh --macos`);
      process.exit(1);
    }
    if (!ready?.state?.ready) {
      console.error('✗ App 未就绪：', JSON.stringify(ready));
      process.exit(1);
    }
    console.log(`==> 已就绪：weather=${ready.state.weather} frame=${ready.state.frame}`);

    const rows = [];
    for (const weather of weathers) {
      // 先归位再切天气：不归位的话上一档的操作（比如为了截月亮而转向）
      // 会把这一档的天空带内容整个换掉，指标就失去可比性。
      if (camera && camera.length === 2 && camera.every((n) => Number.isFinite(n))) {
        await call({ op: 'cmd', command: { cmd: 'set_camera', yaw: camera[0], pitch: camera[1] } });
        await sleep(800);
      }
      const setReply = await call({ op: 'cmd', command: { cmd: 'set_weather', kind: weather } });
      const okSet = setReply?.result?.ok === true && setReply?.result?.weather === weather;
      // 天气过渡约 1.7s（60fps 下）。留足余量，否则截到的是过渡中间态。
      await sleep(4500);

      let run = (await ensureRunning(`${weather} 截图前`)) !== null;
      const saved = [];

      for (let rep = 0; rep < REPS; rep++) {
        const fBefore = await pullFrame();
        const shot = await call({ op: 'screenshot' }, 30000);
        const target = path.join(
          outDir,
          REPS > 1 ? `${weather}-${rep + 1}.png` : `${weather}.png`,
        );
        if (shot?.ok && shot.png) {
          fs.writeFileSync(target, Buffer.from(shot.png, 'base64'));
          saved.push(target);
        }
        const fAfter = await pullFrame();
        // 帧前进判据：截图前后必须推进，否则这张图是冻住的那一帧。
        if (!(fAfter > fBefore)) {
          console.error(`✗ ${weather}：截图期间帧冻结（${fBefore} → ${fAfter}）`);
          run = false;
        }
      }

      let fps = null;
      if (wantFps) {
        const t0 = Date.now();
        const f0 = await pullFrame();
        await sleep(5000);
        const f1 = await pullFrame();
        fps = (f1 - f0) / ((Date.now() - t0) / 1000);
      }

      const st = (await call({ op: 'state' }))?.state ?? {};
      rows.push({
        weather,
        okSet,
        run,
        files: saved,
        fps,
        bytes: saved.reduce((a, f) => a + fs.statSync(f).size, 0),
        frame: st.frame,
      });
    }

    console.log('\n=== 截图结果 ===');
    for (const r of rows) {
      console.log(
        '  ' + [
          r.weather.padEnd(7),
          r.okSet ? '切档 ✓' : '切档 ✗',
          r.run ? '帧前进 ✓' : '帧冻结 ✗',
          r.files.length > 0
            ? `截图 ${r.files.length} 张 (${(r.bytes / 1024).toFixed(0)}KB)`
            : '截图 ✗',
          r.fps === null ? '' : `≈${r.fps.toFixed(1)}fps`,
        ].filter(Boolean).join('  |  '),
      );
    }
    const failed = rows.some((r) => !r.okSet || !r.run || r.files.length === 0);
    if (failed) {
      console.error('\n✗ 截图验收未全部通过。');
      process.exit(1);
    }
    console.log('✓ 截图验收通过（就绪 / 切档 / 帧前进 / 截图非空）。');
  }

  // ---- B) 度量截图 ----
  // 截图模式下量的是**实际写盘的那几张**（`--reps > 1` 时文件名带序号）。
  const targets = weathers.length > 0
    ? weathers
      .flatMap((w) => (fs.existsSync(path.join(outDir, `${w}.png`))
        ? [path.join(outDir, `${w}.png`)]
        : Array.from({ length: REPS }, (_, i) => path.join(outDir, `${w}-${i + 1}.png`))
          .filter((f) => fs.existsSync(f))))
    : files;
  if (targets.length === 0 && weathers.length === 0) {
    console.error('用法见文件头。至少给一个 png，或用 --weathers 逐档截图。');
    process.exit(1);
  }
  let bad = 0;
  for (const f of targets) if (!reportFile(f)) bad++;
  if (bad > 0) process.exit(1);
}

main().catch((e) => {
  console.error('✗ 验收中断：', e.message);
  process.exit(1);
});
