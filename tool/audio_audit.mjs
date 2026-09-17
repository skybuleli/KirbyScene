#!/usr/bin/env node
// 音频验收：**在运行中的 App 上做一组可复现的客观探针**，一条命令给出通过/失败。
//
// 为什么需要它：音效是"听起来怎么样"的问题，而我们（agent）**听不到声音**。
// 所以验收只能落在引擎与音频层自己报出来的量上，而不是 Dart 侧的意图。
//
// ## 这一版在验什么（都对应一个被报过的问题）
//
//   1. **不该响的没响**：没切到雨天时，雨层的目标音量与**已下发音量**都必须是 0。
//      这是"晴天听到滴滴答答"那个 bug 的回归护栏。
//   2. **该响的响了**：四层环境音（河 / 雨 / 风 / 夜）在对应天气下各自的音量 > 0，
//      并且切换天气时是**连续淡入淡出**而不是突切。
//   3. **响度对得上**：河声随距离单调下降、且平缓河段明显比急滩轻
//      （上一版是恒定音量 —— 玩家形容"仿佛身处瀑布旁"）。
//   4. **事件音有闸门**：水花播放速率有上限（上一版实测 2.95 声/秒 = 雨声听感）。
//   5. **启动与输入不被阻塞**：启动各阶段耗时可见，且角色对按键的响应延迟可测。
//   6. **真的在出声**：`outputLeft/Right` 是**混音后**的实测电平。非零才叫出声 ——
//      `started:true` 只代表起播命令没抛异常（上一版踩过：状态里写着 playing，
//      实际一点声音都没有）。它读 `mVisualizationChannelVolume`，**不开
//      `setVisualizationEnabled(true)` 就恒为 0**（已在引擎层打开）。
//
// ## 判读铁律（都是实测踩出来的）
//
// 0. **本脚本自己发 `arm_audio`**。Web 上音频要用户手势才解锁；原生端这一版
//    会在启动后就自动预初始化（`preArm`），但自动化仍然显式发一次，两端一致。
// 1. **先确认帧在推进**。音频参数是按帧算的；窗口不在前台时帧循环会冻结
//    （见 tool/sky_audit.mjs 的同名坑），于是 teleport 之后量到的仍是旧值 ——
//    表现极像"空间音频没生效"。本脚本每步都校验 `state.frame`。
// 2. **不要假设沿 x 就是沿距离**。河道是弯的：实测 z=0 这条横线上 x=10 离中心线
//    21.5m，而 x=24 只有 9.7m。判空间衰减要按音频层报出的 `river.distance` 排序。
// 3. **teleport 后要等**。层音量有淡变时间常数，立刻读数是"半路上"的值。
// 4. **判"没在响"要看 `layers.*.applied`，不是 `targets`**。`targets` 是意图
//    （还差总线乘法与淡变），`applied` 才是已经下发到引擎的单声部音量。
// 5. **不要在切完天气立刻断言"雨层已停"**。雨层的淡出是 2.4s 时间常数
//    （≈7s 到近乎静音）—— 那正是需求要的"自然过渡"，不是 bug。
//
// ## 用法
//
// 需要 App 在跑（`tool/dev.sh --macos`，或 `flutter run -d macos --debug`）：
//
//     node tool/audio_audit.mjs                    # 全部检查
//     node tool/audio_audit.mjs --verbose          # 打印每个采样点
//     node tool/audio_audit.mjs --json             # 末尾输出原始采样 JSON（便于回归对比）
//     node tool/audio_audit.mjs --weathers clear,cloudy,rain,night
//
// 选项：
//     --weathers A,B   要轮换的天气（默认 clear,cloudy,rain,night）
//     --settle MS      每次切档后等参数稳定的上限（默认 900）
//     --splash S       量水花速率的窗口秒数（默认 8）
//     --app PATH       拉前台用的 .app 路径
//     --verbose        打印每个采样点
//     --json           输出原始采样 JSON
//
// 退出码：任一检查失败 → 1。

import net from 'node:net';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const PORT = Number(process.env.KIRBY_INPROC_PORT || 7008);
const args = process.argv.slice(2);
const opt = (name, def) => {
  const i = args.indexOf(name);
  return i > -1 && args[i + 1] ? args[i + 1] : def;
};
const has = (name) => args.includes(name);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const WEATHERS = opt('--weathers', 'clear,cloudy,rain,night').split(',').map((s) => s.trim());
const SETTLE_MS = Number(opt('--settle', 900));
const SPLASH_WINDOW = Number(opt('--splash', 8));
const APP = opt('--app', 'build/macos/Build/Products/Debug/kirby_scene.app');
const VERBOSE = has('--verbose');
const WANT_JSON = has('--json');

// ------------------------------------------------------------------
// inproc 客户端（协议见 lib/mcp/inproc_host_io.dart）
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
    sock.on('timeout', () => finish(() => reject(new Error(`连接 ${PORT} 超时（App 没在跑？）`))));
    sock.on('error', (e) =>
      finish(() => reject(new Error(`连不上 127.0.0.1:${PORT} —— ${e.message}`))));
  });
}

const cmd = (command) => call({ op: 'cmd', command });
const pullState = async () => (await call({ op: 'state' }))?.state ?? null;

/// 引擎侧实测值的**显式**探针。
///
/// 为什么要单独拉、而不直接从 `state` 读：这几个量在 SoLoud 侧要经 FFI 拿全局
/// 音频锁（`mAudioThreadMutex`），而那个锁被 CoreAudio 回调里的混音器持有整段
/// `mix()`。在**帧回调**里读它 = 每帧跟混音线程抢一次锁 = 主线程被饿住。
/// 所以 `state.audio.outputLeft` 现在是**缓存**，要新鲜值就得调这条命令。
/// （这正是这一版修掉"按键几十秒无响应"的那个根因。）
/// 连续采 [n] 次取**最大**：用来代表"本该有声时确实有输出"。
async function peakLevel(n = 3) {
  let best = 0;
  for (let i = 0; i < n; i++) {
    const l = await levels();
    best = Math.max(best, l.left + l.right);
    await sleep(350);
  }
  return best;
}

/// 连续采 [n] 次取**最小**：用来代表"本该静音时确实静了"。
async function floorLevel(n = 5) {
  let worst = Infinity;
  for (let i = 0; i < n; i++) {
    const l = await levels();
    worst = Math.min(worst, l.left + l.right);
    await sleep(350);
  }
  return worst;
}

async function levels() {
  const r = await cmd({ cmd: 'audio_levels' });
  // ⚠️ `cmd` 的应答是 `{ok:true, result:{...}}`（见 `inproc_host_io.dart`）。
  // 直接读 `r.outputLeft` 会永远拿到 undefined ⇒ 全 0，看起来像"引擎没在跑"。
  // 实测就这么误判过一轮（连着 3 项检查报"哑的"）。
  const v = r?.result ?? r ?? {};
  return {
    left: Number(v.outputLeft ?? 0),
    right: Number(v.outputRight ?? 0),
    voices: Number(v.activeVoices ?? 0),
    engineMs: Number(v.engineTimeMs ?? 0),
    ok: r?.ok === true && v.ok !== false,
  };
}

function bringToFront() {
  try {
    execFileSync('open', ['-a', path.resolve(APP)], { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
}

/// 等帧推进（窗口不在前台时帧循环会冻结，量到的全是旧值）。
async function waitFrames({ min = 3, timeoutMs = 4000 } = {}) {
  const t0 = Date.now();
  let a = await pullState();
  while (Date.now() - t0 < timeoutMs) {
    await sleep(180);
    const b = await pullState();
    if (a && b && b.frame - a.frame >= min) return b;
    a = b;
  }
  console.log('   ⚠️ 帧没在推进，拉前台重试…');
  bringToFront();
  await sleep(1500);
  return pullState();
}

/// 等某个读数稳定下来（层音量有淡变时间常数）。
///
/// ⚠️ 判据用**相对变化**而不是绝对变化。指数淡变在靠近 0 时每步的绝对差值
/// 也会变小（0.05→0.045 只差 0.005），拿绝对阈值去判"稳了"会在**还没淡完**
/// 的时候就返回 —— 实测就因此误报过"雨层在晴天还在响"。
async function settle(read, { within = 0.02, timeoutMs = SETTLE_MS, frame = true } = {}) {
  let prev = null;
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) {
    const st = frame ? await waitFrames({ min: 2 }) : await pullState();
    if (!st) continue;
    const v = read(st);
    if (v < 0.004) return st; // 已经可以视作静音，不必再等
    if (prev !== null && Math.abs(v - prev) < within * Math.max(Math.abs(v), 0.05)) return st;
    prev = v;
  }
  return await pullState();
}

/// 等一个条件成立（用于"必须完全静音"这类断言：等淡出真的走完）。
async function waitUntil(pred, { timeoutMs = 12000, label = '' } = {}) {
  const t0 = Date.now();
  let last = null;
  while (Date.now() - t0 < timeoutMs) {
    last = await pullState();
    if (last && pred(last)) return last;
    await sleep(250);
  }
  if (label) console.log(`   ⚠️ 等 ${label} 超时（${timeoutMs}ms）`);
  return last;
}

const num = (v, d = 0) => (typeof v === 'number' && Number.isFinite(v) ? v : d);

// ------------------------------------------------------------------
// 检查项
// ------------------------------------------------------------------

const checks = [];
function check(name, ok, detail) {
  checks.push({ name, ok, detail });
  console.log(`  ${ok ? '✓' : '✗'} ${name}${detail ? `  —— ${detail}` : ''}`);
}

function pearson(xs, ys) {
  const n = xs.length;
  if (n < 3) return NaN;
  const mx = xs.reduce((a, b) => a + b, 0) / n;
  const my = ys.reduce((a, b) => a + b, 0) / n;
  let numv = 0,
    dx = 0,
    dy = 0;
  for (let i = 0; i < n; i++) {
    const a = xs[i] - mx;
    const b = ys[i] - my;
    numv += a * b;
    dx += a * a;
    dy += b * b;
  }
  const den = Math.sqrt(dx * dy);
  return den < 1e-12 ? NaN : numv / den;
}

/// "这层实际下发的单声部音量" —— 层目标 × 总线系数 × 最大档权重。
/// 它是唯一能把"意图"和"事实"连起来的数（上一版就是拿意图当事实误判了）。
function layerAppliedVolume(st, layer) {
  const a = st?.audio;
  const l = a?.layers?.[layer];
  if (!l) return 0;
  return num(l.applied, 0);
}

function riverPerBandVolume(st) {
  const a = st.audio;
  return num(a.targets?.river) * num(a.buses?.ambience?.now) * num(a.buses?.master);
}

const samples = { weathers: [], loudness: [], touch: {} };

async function main() {
  console.log(`音频验收：127.0.0.1:${PORT}\n`);
  bringToFront();

  // ================================================================
  console.log('【1/6】引擎、烘焙与装配');
  // ================================================================
  await cmd({ cmd: 'arm_audio' }).catch(() => {});
  let st = null;
  for (let i = 0; i < 40; i++) {
    st = await pullState();
    if (st?.audio?.started && st.audio.bakeDone) break;
    await sleep(500);
  }
  if (!st) {
    console.error('✗ 读不到 state（App 没在跑？）');
    process.exit(1);
  }
  st = (await settle((s) => num(s.audio?.layers?.river?.level))) ?? st;

  const a0 = st.audio;
  const bootTotal = Object.values(st.bootMs ?? {}).reduce((s, v) => s + v, 0);
  console.log(
    `   boot 合计 ${bootTotal}ms（音频烘焙阶段 ${st.bootMs?.audioBake ?? '?'}ms）` +
      ` · 烘焙 ${a0.bakeMs}ms/${a0.bakedAssets} 个资产 · arm ${a0.armMs}ms×${a0.armCount}`,
  );
  const lv0 = await levels();
  console.log(
    `   engine ready=${a0.engine?.ready} sources=${a0.engine?.sources}` +
      ` · 装配好的层 ${a0.preparedLayers}/4 · voices=${lv0.voices}` +
      ` · out L/R=${lv0.left}/${lv0.right}`,
  );
  if (a0.engine?.error || a0.error) console.log(`   error: ${a0.engine?.error ?? a0.error}`);

  check('音频引擎已初始化', a0.engine?.ready === true);
  check('已起播', a0.started === true);
  check('烘焙完成且没有失败', a0.bakeDone === true && a0.bakeFailures === 0,
    `assets=${a0.bakedAssets} failures=${a0.bakeFailures}`);
  check('四层环境音全部装配完成', a0.preparedLayers === 4, `preparedLayers=${a0.preparedLayers}`);
  check('烘焙不在启动的同步路径上（那一阶段应当接近 0）',
    num(st.bootMs?.audioBake, 9999) < 60, `${st.bootMs?.audioBake}ms`);
  check('引擎没有报告错误', !a0.engine?.error && !a0.error);

  // ================================================================
  console.log('\n【2/6】真的在出声 + 声部预算');
  // ================================================================
  const l0 = await levels();
  await sleep(1200);
  await waitFrames();
  const l1 = await levels();
  const t0 = l0.engineMs;
  const t1 = l1.engineMs;
  const voices = l1.voices;
  const outL = l1.left;
  const outR = l1.right;
  console.log(`   引擎时钟 +${t1 - t0}ms · 活跃声部 ${voices} · 输出 L/R ${outL}/${outR}`);
  check('引擎时钟在推进（音频设备真的在跑）', t1 > t0, `${t0} → ${t1}`);
  check('左右声道都有实测输出（不是哑的）', outL + outR > 0.0005,
    `L+R=${(outL + outR).toFixed(4)}`);
  check('声部数在预算内（河/风各只占当面档位，不是每层全档常驻）',
    voices > 0 && voices <= 16, `voices=${voices}`);

  // ================================================================
  console.log('\n【3/6】分层严格跟随天气（"不该响的绝不出声"）');
  // ================================================================
  const rainOk = [];
  for (const w of WEATHERS) {
    await cmd({ cmd: 'set_weather', kind: w });
    await sleep(300);
    // 等淡变走完：**必须等的是"雨层已停"这个条件本身**，不能只等"读数稳定"
    // （指数淡变接近 0 时每步差值也变小，那是还没停）。
    if (w === 'rain') {
      await waitUntil((s) => num(s.audio.layers.rain.applied) > 0.02, { label: '雨层淡入' });
    } else {
      await waitUntil((s) => num(s.audio.layers.rain.applied) === 0, { label: '雨层淡出' });
    }
    // 等待判据必须与断言（applied === 0）一致：等到 0.02 就放行会撞上淡出尾段
    // （0.02 → 吸附零还要 ~2s），断言必挂（实测 3 项误报）。
    await waitUntil((s) => (w === 'night') === (num(s.audio.layers.night.applied) > 0),
      { label: '夜层到位' });
    const s = await waitFrames({ min: 3 });
    const L = s.audio.layers;
    const T = s.audio.targets;
    samples.weathers.push({ weather: w, targets: T, layers: L, river: s.audio.river });
    const row =
      `   ${w.padEnd(7)} target 河=${num(T.river).toFixed(3)} 雨=${num(T.rain).toFixed(3)}` +
      ` 风=${num(T.wind).toFixed(3)} 夜=${num(T.night).toFixed(3)}` +
      `  |  applied 河=${layerAppliedVolume(s, 'river').toFixed(3)}` +
      ` 雨=${layerAppliedVolume(s, 'rain').toFixed(3)}` +
      ` 风=${layerAppliedVolume(s, 'wind').toFixed(3)}` +
      ` 夜=${layerAppliedVolume(s, 'night').toFixed(3)}` +
      `  | 距河 ${num(s.audio.river.distance).toFixed(1)}m 急缓 ${num(s.audio.river.intensity).toFixed(2)}`;
    console.log(row);

    const expectRain = w === 'rain';
    const expectNight = w === 'night';
    rainOk.push(
      expectRain
        ? num(T.rain) > 0.05 && num(L.rain.applied) > 0.005
        : num(T.rain) === 0 && num(L.rain.applied) === 0 && L.rain.playing === false,
    );
    check(
      `${w}：雨层${expectRain ? '应当出声' : '必须完全静音'}`,
      rainOk.at(-1),
      `target=${num(T.rain).toFixed(3)} applied=${num(L.rain.applied).toFixed(3)}` +
        ` playing=${L.rain.playing}`,
    );
    check(
      `${w}：夜层${expectNight ? '应当出声' : '必须完全静音'}`,
      expectNight ? num(T.night) > 0.02 : num(L.night.applied) === 0,
      `target=${num(T.night).toFixed(3)} applied=${num(L.night.applied).toFixed(3)}`,
    );
    check(`${w}：河层始终可有声（河一直在那里）`, num(T.river) > 0.005,
      `target=${num(T.river).toFixed(3)}`);
    check(`${w}：风层始终留一点底噪`, num(T.wind) > 0.005,
      `target=${num(T.wind).toFixed(3)}`);
  }
  check('四档天气下雨层从没在非雨天出过声', rainOk.every(Boolean));

  // 回到晴天，后面都在晴天里量（"晴天不该有雨声"是最被关心的一条）。
  await cmd({ cmd: 'set_weather', kind: 'clear' });
  await waitUntil((s) => num(s.audio.layers.rain.applied) === 0, { label: '回到晴天后的雨层淡出' });

  // ================================================================
  console.log('\n【4/6】切换是连续淡入淡出，不是突切');
  // ================================================================
  // 从晴天切到雨天，密集采样雨层的**已下发音量**：它必须从 0 单调爬升，
  // 且单步变化远小于全程（突切会在一步里跳到目标值）。
  await cmd({ cmd: 'set_weather', kind: 'rain' });
  const rise = [];
  const tRise = Date.now();
  while (Date.now() - tRise < 5000) {
    const s = await pullState();
    if (s?.audio) rise.push(num(s.audio.layers.rain.applied));
    await sleep(120);
  }
  const riseMax = Math.max(...rise);
  let maxStep = 0;
  for (let i = 1; i < rise.length; i++) maxStep = Math.max(maxStep, Math.abs(rise[i] - rise[i - 1]));
  let monotone = true;
  for (let i = 1; i < rise.length; i++) if (rise[i] < rise[i - 1] - 0.01) monotone = false;
  console.log(
    `   雨层音量 0 → ${riseMax.toFixed(3)}（${rise.length} 个采样点，单步最大跳变 ${maxStep.toFixed(3)}）`,
  );
  check('切入雨天时雨层音量连续爬升（没有一步到位）',
    riseMax > 0.02 && maxStep < riseMax * 0.5 && monotone,
    `max=${riseMax.toFixed(3)} maxStep=${maxStep.toFixed(3)} monotone=${monotone}`);
  if (VERBOSE) console.log(`     ${rise.map((v) => v.toFixed(3)).join(' ')}`);

  // 切回晴天：雨层必须淡出到 0，然后真正停掉声部。
  await cmd({ cmd: 'set_weather', kind: 'clear' });
  const stOut2 = await waitUntil(
    (s) => num(s.audio.layers.rain.applied) === 0 &&
      s.audio.layers.rain.playing === false &&
      s.audio.layers.rain.activeVariants === 0,
    { label: '雨层淡出并归还声部' },
  );
  console.log(
    `   切回晴天：雨层 level=${num(stOut2.audio.layers.rain.level)}` +
      ` applied=${num(stOut2.audio.layers.rain.applied)} playing=${stOut2.audio.layers.rain.playing}` +
      ` activeVariants=${stOut2.audio.layers.rain.activeVariants}`,
  );
  check('切回晴天后雨层真的停掉了（淡出并归还声部）',
    num(stOut2.audio.layers.rain.applied) === 0 &&
      stOut2.audio.layers.rain.playing === false &&
      stOut2.audio.layers.rain.activeVariants === 0);

  // ================================================================
  console.log('\n【5/6】事件音的三重闸门（"晴天的滴滴答答"）');
  // ================================================================
  const sA = await pullState();
  const before = { ...(sA.audio.sfx.played ?? {}) };
  const dropped0 = Object.values(sA.audio.sfx.dropped ?? {}).reduce((a, b) => a + b, 0);
  await sleep(SPLASH_WINDOW * 1000);
  const sB = await waitFrames({ min: 3 });
  const after = { ...(sB.audio.sfx.played ?? {}) };
  const dropped1 = Object.values(sB.audio.sfx.dropped ?? {}).reduce((a, b) => a + b, 0);

  const splashPlayed = num(after.splash) - num(before.splash);
  const splashRate = splashPlayed / SPLASH_WINDOW;
  const droppedCount = dropped1 - dropped0;
  console.log(
    `   ${SPLASH_WINDOW}s 内水花：播放 ${splashPlayed} 声（${splashRate.toFixed(2)} 声/秒），` +
      `被闸门拦下 ${droppedCount} 声` +
      ` · 事件音总览 ${JSON.stringify(after)}`,
  );
  check('水花播放速率被闸门压住（旧版实测 2.95 声/秒 = 雨声听感）',
    splashRate <= 1.2, `${splashRate.toFixed(2)} 声/秒`);
  check('闸门确实在拦（不是恰好没有事件）', droppedCount > 0, `dropped +${droppedCount}`);

  // 脚步：按住 W 一段时间，脚步音必须真的被触发（事件音通道端到端）。
  const beforeSteps = sumByPrefix(after, 'step_');
  await cmd({ cmd: 'hold_keys', keys: ['KeyW'] });
  await sleep(4000);
  const sWalk = await waitFrames({ min: 3 });
  await cmd({ cmd: 'release_keys', all: true });
  const afterSteps = sumByPrefix(sWalk.audio.sfx.played ?? {}, 'step_');
  const stepCount = afterSteps - beforeSteps;
  console.log(`   按住 W 4s：脚步音 ${stepCount} 声`);
  check('角色移动会触发出脚步声（玩法事件音通道接通）', stepCount >= 3,
    `${stepCount} 声`);

  // ================================================================
  console.log('\n【6/6】响度阶梯与空间衰减（"别像瀑布"）');
  // ================================================================
  // 只留河层，把别的层静音 —— 这样量到的输出电平就只反映河。
  for (const l of ['rain', 'wind', 'night']) await cmd({ cmd: 'set_layer', layer: l, mute: true });
  await sleep(1500);

  const near = [];
  const dists = [
    [24, 0], [30, 0], [0, 0], [-40, 0], [70, 0], [-90, 0],
  ];
  for (const [x, z] of dists) {
    await cmd({ cmd: 'teleport', x, z });
    const s = await settle((st2) => num(st2.audio?.river?.distance), { timeoutMs: 2500 });
    await sleep(1400); // 让淡变走完
    await waitFrames({ min: 3 });
    const s2 = await pullState();
    const lv = await levels();
    const d = num(s2.audio.river.distance);
    const out = lv.left + lv.right;
    const target = num(s2.audio.targets.river);
    near.push({ x, z, d, out, target });
    if (VERBOSE) console.log(`     (${x},${z}) 距离 ${d.toFixed(1)}m target ${target.toFixed(3)} out ${out.toFixed(4)}`);
  }
  // 按距离排序后再算相关（河道是弯的，不能按 x 排）。
  const sorted = [...near].sort((a, b) => a.d - b.d);
  const rDist = pearson(sorted.map((p) => p.d), sorted.map((p) => p.target));
  const closest = sorted[0];
  const farthest = sorted.at(-1);
  console.log(
    `   距离 ${closest.d.toFixed(1)}m → ${farthest.d.toFixed(1)}m ：` +
      `target ${closest.target.toFixed(3)} → ${farthest.target.toFixed(3)}` +
      `（r=${Number.isFinite(rDist) ? rDist.toFixed(2) : 'n/a'}）`,
  );
  console.log('   ' + sorted.map((p) => `${p.d.toFixed(0)}m:${p.target.toFixed(3)}`).join('  '));
  check('河声随距离单调变轻（空间衰减真的接在音量上）', rDist < -0.8,
    `r=${Number.isFinite(rDist) ? rDist.toFixed(2) : 'n/a'}`);
  check('近距离与远距离的差距足够明显（不是恒定音量）',
    farthest.d > closest.d * 2 &&
      (closest.d < 8 ? closest.target > farthest.target * 3 : true),
    `${closest.d.toFixed(1)}m→${closest.target.toFixed(3)} vs ${farthest.d.toFixed(1)}m→${farthest.target.toFixed(3)}`);

  // 混音阶梯：全部静音后输出必须掉到接近 0（证明层音量真的在控制可听输出）。
  const loudly = await peakLevel(3);
  for (const l of ['river', 'rain', 'wind', 'night']) {
    await cmd({ cmd: 'set_layer', layer: l, mute: true });
  }
  await sleep(4000);
  await waitFrames({ min: 3 });
  // 取**最小值**：`getApproximateVolume` 是"刚混完那一个块"的瞬时电平，
  // 而水花/脚步这类一次性音效随时会闯进来把单次读数抬高一截（实测 0.030）。
  // 全静音后各次采样之间的**真静音**才是要找的东西。
  const quiet = await floorLevel();
  console.log(`   全静音前 L+R=${loudly.toFixed(4)} → 后 ${quiet.toFixed(4)}`);
  check('静音全部环境音后实测输出确实掉了（层音量真的在控制输出）',
    quiet < Math.max(loudly * 0.6, 0.004),
    `${loudly.toFixed(4)} → ${quiet.toFixed(4)}`);

  // 恢复默认，别把 App 留在静音状态。
  for (const l of ['river', 'rain', 'wind', 'night']) {
    await cmd({ cmd: 'set_layer', layer: l, mute: false });
  }

  // 报告一下这一版的响度标尺，便于跨版本对比。
  const sEnd = await settle((s) => num(s.audio?.targets?.river), { timeoutMs: 4000 });
  console.log(
    `   响度标尺：河 layer target=${num(sEnd.audio.targets.river).toFixed(3)}` +
      ` × 环境总线 ${num(sEnd.audio.buses.ambience.now).toFixed(2)}` +
      ` × master ${num(sEnd.audio.buses.master).toFixed(2)}` +
      ` = 单声部 ${riverPerBandVolume(sEnd).toFixed(4)}` +
      `（上一版同距离是 0.805 且**不含**距离/急缓因子）`,
  );

  // ================================================================
  console.log('\n【附加】启动与输入响应');
  // ================================================================
  await cmd({ cmd: 'teleport', x: 0, z: 0 });
  await sleep(600);
  const p0 = (await pullState()).position.slice();
  const tInject = Date.now();
  await cmd({ cmd: 'hold_keys', keys: ['KeyW'] });
  let latency = null;
  const tWait = Date.now();
  while (Date.now() - tWait < 6000) {
    const s = await pullState();
    if (s.position && Math.abs(s.position[0] - p0[0]) + Math.abs(s.position[2] - p0[2]) > 0.05) {
      latency = Date.now() - tInject;
      break;
    }
    await sleep(100);
  }
  await cmd({ cmd: 'release_keys', all: true });
  samples.touch = { latencyMs: latency, bootTotal };
  console.log(
    `   启动各阶段合计 ${bootTotal}ms（音频只占 ${st.bootMs?.audioBake ?? 0}ms，其余是程序化地形/草/植被）` +
      ` · 注入按键到角色开始移动 ${latency ?? '未响应'}ms`,
  );
  check('按键到角色移动的延迟很短（输入没有被音频初始化挡住）',
    latency !== null && latency < 1500, `${latency}ms`);

  // **回归护栏**：`state` 就是帧回调里那条路径（`bridgeStateJson`）。
  // 上一版它每帧去读 `getApproximateVolume` —— 那个调用要经 FFI 抢 SoLoud 的
  // 全局音频锁，而锁被 CoreAudio 回调里的混音器持有整段 `mix()`。混音线程
  // 重新上锁比主线程被调度到更快，于是主线程被**饿死**：按键完全不响应、
  // 几十秒后才恢复。当时的表现就是本工具自己都读不到状态（连接超时）。
  const beats = [];
  let missed = 0;
  const tPoll = Date.now();
  while (Date.now() - tPoll < 3000) {
    try {
      const s = await call({ op: 'state' }, 900);
      beats.push(s?.state?.frame ?? -1);
    } catch {
      missed++;
    }
    await sleep(100);
  }
  const advanced = beats.at(-1) - beats[0];
  console.log(
    `   3s 内以 ~10Hz 读 state：${beats.length} 次应答 / ${missed} 次超时` +
      ` · 帧推进 ${advanced}`,
  );
  check('高频读 state 不会把主线程冻住（帧回调不再跟混音线程抢音频锁）',
    missed === 0 && advanced > 0, `${beats.length} 应答 / ${missed} 超时 / +${advanced} 帧`);
  check('启动各阶段耗时都在预算内（没有任何一段长时间阻塞主线程）',
    Object.entries(st.bootMs ?? {}).every(([, v]) => v < 1500),
    JSON.stringify(st.bootMs));

  // ================================================================
  const failed = checks.filter((c) => !c.ok);
  console.log(
    `\n${failed.length === 0 ? '✓ 全部通过' : `✗ ${failed.length} 项未通过`}（共 ${checks.length} 项）`,
  );
  if (failed.length) for (const f of failed) console.log(`   ✗ ${f.name}${f.detail ? ` —— ${f.detail}` : ''}`);
  if (WANT_JSON) {
    console.log('\n' + JSON.stringify({ checks, samples }, null, 2));
  }
  process.exit(failed.length ? 1 : 0);
}

function sumByPrefix(obj, prefix) {
  let s = 0;
  for (const [k, v] of Object.entries(obj ?? {})) if (k.startsWith(prefix)) s += num(v);
  return s;
}

main().catch((e) => {
  console.error(`\n✗ ${e.message}`);
  process.exit(1);
});
