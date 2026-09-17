#!/usr/bin/env node
// 天气复验：热重启/热重载 → 逐个天气切档 → inproc 截图 → 帧数判据。
//
// 为什么需要它：天气系统这次的改动（银河带 / 月晕 / 流星 / 积水涟漪 / 闪电）
// 全都落在 `SkySystem.build()` 的节点组装里，而**热重载（SIGUSR1）不重建已有对象**
// —— 只发 SIGUSR1 的话画面上什么都看不到，必须热重启（SIGUSR2）。
// 这个脚本把「热重启 → 等帧循环真的跑起来 → 逐档切天气 → 截图 → 校验帧数前进」
// 这条回路固化下来，避免每次手动敲一长串命令、也避免把"没效果"误判成代码问题。
//
// 前提：App 已由用户在**自己的终端**拉起（助手所在沙箱无法构建 macOS）：
//     tool/dev.sh --macos          # 或：flutter run -d macos
//
// 用法：
//     node tool/verify_weather.mjs                       # 热重启 + 夜晚/雨天复验
//     node tool/verify_weather.mjs --reload              # 用热重载（仅改 Dart 逻辑时）
//     node tool/verify_weather.mjs --weathers night,rain,clear
//     node tool/verify_weather.mjs --out-dir build/reverify
//     node tool/verify_weather.mjs --no-restart          # 只切档截图，不重启
//     node tool/verify_weather.mjs --pid 12345           # 指定 flutter run 的 pid
//     node tool/verify_weather.mjs --app path/to/kirby_scene.app
//
// 判据（缺一不可）：
//   1. `state.ready == true`      —— 初始化（含新几何）没抛异常；
//   2. `frame` 在两次采样间前进   —— 帧循环真的在跑（不在前台会冻结）；
//   3. 每个天气截图非空           —— 渲染路径可用。
// 任一条不过 → 退出码 1，便于挂进脚本流水线。

import net from 'node:net';
import fs from 'node:fs';
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

const outDir = opt('--out-dir', 'build/reverify');
const weathers = opt('--weathers', 'night,rain')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean);
const doRestart = !has('--no-restart');
const wantReload = has('--reload');
const explicitPid = opt('--pid', null);
const appPath = opt(
  '--app',
  'build/macos/Build/Products/Debug/kirby_scene.app',
);

/// 一次请求：换行分隔 JSON（协议见 lib/mcp/inproc_host_io.dart）。
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
        return finish(() =>
          reject(new Error(`非 JSON 响应：${buffer.slice(0, 120)}`)));
      }
      finish(() => resolve(reply));
    });
    sock.on('timeout', () =>
      finish(() => reject(new Error(`连接 ${PORT} 超时（App 没在跑？）`))));
    sock.on('error', (e) =>
      finish(() => reject(new Error(`连不上 127.0.0.1:${PORT} —— ${e.message}`))));
  });
}

/// 刚热重启时端口会有短暂的关闭/重绑窗口，所以带重试。
async function callRetry(payload, { tries = 30, gapMs = 1200, timeoutMs = 4000 } = {}) {
  let lastError;
  for (let i = 0; i < tries; i++) {
    try {
      return await call(payload, timeoutMs);
    } catch (e) {
      lastError = e;
      await sleep(gapMs);
    }
  }
  throw lastError;
}

async function pullState() {
  const reply = await call({ op: 'state' });
  return reply && reply.ok ? reply.state : null;
}

/// 找到 `flutter run` 的 pid。
///
/// 三种途径按可靠性降序：
///   1. `--pid` 显式指定；
///   2. dev.sh 写下的 `build/dev_run.pid`（flutter 的 `--pid-file`）；
///   3. `pgrep` —— 注意**命令行里没有字面量 "flutter run"**：
///      真实进程是 `dartvm .../flutter_tools.snapshot run -d macos`，
///      所以模式要匹配 `flutter_tools.snapshot run`（曾经只匹配 "flutter run"
///      导致明明会话在跑却报"找不到进程"）。
function findFlutterPid() {
  if (explicitPid) return Number(explicitPid);

  try {
    const fromFile = fs.readFileSync(path.join('build', 'dev_run.pid'), 'utf8').trim();
    if (fromFile && Number(fromFile) > 0) return Number(fromFile);
  } catch {
    // pid 文件不存在或读不了，退回 pgrep。
  }

  for (const pattern of ['flutter_tools.snapshot run', 'flutter run']) {
    try {
      const out = execFileSync('pgrep', ['-fl', pattern], { encoding: 'utf8' });
      const lines = out.split('\n').filter((l) => l.trim());
      if (lines.length === 0) continue;
      // 取最新（最后）一个，避免抓到历史残留进程。
      return Number(lines[lines.length - 1].trim().split(/\s+/)[0]);
    } catch {
      // 换下一个模式。
    }
  }
  return null;
}

/// 把 App 窗口拉到前台。帧循环在窗口不前台时会冻结，
/// 而冻住的表现很像"热重载没生效"，所以这里主动尽力拉一次。
function bringToFront() {
  try {
    execFileSync('open', ['-a', path.resolve(appPath)], { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
}

async function main() {
  // ---- 1) 热重启 / 热重载 ----
  if (doRestart) {
    const pid = findFlutterPid();
    if (!pid) {
      console.error(
        '✗ 没找到 `flutter run` 进程。\n'
          + '  请先在自己的终端跑： tool/dev.sh --macos   （或 flutter run -d macos）',
      );
      process.exit(1);
    }
    const signal = wantReload ? 'SIGUSR1' : 'SIGUSR2';
    console.log(`==> ${wantReload ? '热重载' : '热重启'}：${signal} → pid ${pid}`);
    process.kill(pid, signal);
    await sleep(3000);
  }

  // ---- 2) 等就绪 ----
  // 注意：callRetry 返回的是**完整响应**（`{ok, state}`），
  // 就绪与否看的是里面的 `state`；直接拿响应当 state 会永远判成"未就绪"。
  const firstReply = await callRetry({ op: 'state' }, { tries: 40, gapMs: 1500 });
  let state = firstReply?.state;
  if (!state || !state.ready) {
    console.error('✗ App 未就绪：', JSON.stringify(firstReply));
    process.exit(1);
  }
  console.log(`==> 已就绪：weather=${state.weather} frame=${state.frame}`);

  // ---- 3) 帧数判据 ----
  const firstFrame = state.frame;
  await sleep(2000);
  state = await pullState();
  if (!(state.frame > firstFrame)) {
    console.log('   帧循环冻结（窗口可能不在前台），尝试拉前台…');
    bringToFront();
    await sleep(3000);
    state = await pullState();
  }
  const frameBefore = state.frame;
  await sleep(1500);
  state = await pullState();
  const frameOk = state.frame > frameBefore;
  console.log(
    `==> 帧循环：${firstFrame} → ${state.frame} ${frameOk ? '✓' : '✗ 仍未前进'}`,
  );

  // ---- 4) 逐天气切档 + 截图 ----
  fs.mkdirSync(outDir, { recursive: true });
  const rows = [];
  for (const weather of weathers) {
    const reply = await call({
      op: 'cmd',
      command: { cmd: 'set_weather', kind: weather },
    });
    const okSet = reply?.result?.ok === true;
    console.log(
      `==> ${weather}：set_weather ${okSet ? 'ok' : `失败 ${JSON.stringify(reply)}`}`,
    );

    // 天气过渡约 1.7s（60fps 下）。留足余量，否则截到的是过渡中间态。
    await sleep(4500);
    const b = (await pullState())?.frame ?? 0;
    await sleep(1200);
    const a = (await pullState())?.frame ?? 0;

    const shot = await call({ op: 'screenshot' }, 25000);
    let file = null;
    if (shot?.ok && shot.png) {
      file = path.join(outDir, `${weather}.png`);
      fs.writeFileSync(file, Buffer.from(shot.png, 'base64'));
    }
    rows.push({
      weather,
      okSet,
      frameAdvanced: a > b,
      file,
      bytes: file ? fs.statSync(file).size : 0,
    });
  }

  // ---- 5) 汇总 ----
  console.log('\n=== 复验结果 ===');
  for (const r of rows) {
    const parts = [
      r.weather.padEnd(7),
      r.okSet ? '切档 ✓' : '切档 ✗',
      r.frameAdvanced ? '帧前进 ✓' : '帧冻结 ✗',
      r.file ? `截图 ${r.file} (${(r.bytes / 1024).toFixed(0)}KB)` : '截图 ✗',
    ];
    console.log('  ' + parts.join('  |  '));
  }

  const failed = !frameOk
    || rows.some((r) => !r.okSet || !r.frameAdvanced || !r.file);
  if (failed) {
    console.error('\n✗ 复验未全部通过。');
    process.exit(1);
  }
  console.log('\n✓ 复验通过（就绪 / 帧前进 / 逐档截图）。');
}

main().catch((e) => {
  console.error('✗ 复验中断：', e.message);
  process.exit(1);
});
