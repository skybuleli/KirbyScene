#!/usr/bin/env node
// 玩法端到端复验：收集 12 颗星核 → 通关判据 → 重玩归零。
// 判据与 sky/audio 审计一致：state.ready + frame 持续前进；坐标来自
// world.dart _spawnPickups 的确定性布点（三环 8/14/19.5，各 4 颗）。

import net from 'node:net';
import { execFileSync } from 'node:child_process';

const PORT = 7008;
const APP = 'build/macos/Build/Products/Debug/kirby_scene.app';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function call(payload, timeoutMs = 8000) {
  return new Promise((resolve, reject) => {
    const sock = net.createConnection({ host: '127.0.0.1', port: PORT });
    let buf = '';
    let done = false;
    const finish = (fn) => { if (!done) { done = true; sock.destroy(); fn(); } };
    sock.setTimeout(timeoutMs);
    sock.on('connect', () => sock.write(`${JSON.stringify(payload)}\n`));
    sock.on('data', (c) => {
      buf += c.toString('utf8');
      const nl = buf.indexOf('\n');
      if (nl === -1) return;
      finish(() => resolve(JSON.parse(buf.slice(0, nl))));
    });
    sock.on('timeout', () => finish(() => reject(new Error('state 超时'))));
    sock.on('error', (e) => finish(() => reject(new Error(e.message))));
  });
}

const num = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : 0);

function pickups() {
  // 与 world.dart _spawnPickups 一致：相位偏移用的是**全局 index**，
  // 不是环内序号（用错的话 11/12 颗对不上，实测）。
  const rings = [[8.0, 4], [14.0, 4], [19.5, 4]];
  const out = [];
  let idx = 0;
  for (const [r, n] of rings) {
    for (let i = 0; i < n; i++) {
      const a = (i / n) * Math.PI * 2 + idx * 0.35;
      out.push({ x: Math.cos(a) * r, z: Math.sin(a) * r, idx: idx++ });
    }
  }
  return out;
}

let failures = 0;
const check = (label, ok, detail = '') => {
  console.log(`  ${ok ? '✓' : '✗'} ${label}${detail ? `  —— ${detail}` : ''}`);
  if (!ok) failures++;
};

async function framesAdvance(minFrames, timeoutMs = 6000) {
  const t0 = Date.now();
  let a = (await call({ op: 'state' })).state;
  while (Date.now() - t0 < timeoutMs) {
    await sleep(250);
    const b = (await call({ op: 'state' })).state;
    if (b.frame - a.frame >= minFrames) return b;
    a = b;
  }
  execFileSync('open', ['-a', process.cwd() + '/' + APP], { stdio: 'ignore' });
  await sleep(1500);
  return (await call({ op: 'state' })).state;
}

const list = pickups();
let s = (await framesAdvance(5)).state ?? (await call({ op: 'state' })).state;
check('App 就绪且帧在推进', s.ready === true && s.frame > 0,
  `frame=${s.frame}`);
await call({ op: 'cmd', command: { cmd: 'restart' } });
await sleep(1200);
s = (await call({ op: 'state' })).state;
check('重开后计分为 0', s.score === 0, `score=${s.score}`);
const f0 = s.frame;

let collected = 0;
for (const p of list) {
  await call({ op: 'cmd', command: { cmd: 'teleport', x: p.x, z: p.z } });
  await sleep(900);
  const st = (await call({ op: 'state' })).state;
  if (st.score > collected) collected = st.score;
}
s = (await call({ op: 'state' })).state;
check('12 颗星核全部收集', s.score === 12, `score=${s.score}/12`);
check('通关判据 cleared=true', s.cleared === true);
// 帧推进是硬判据：冻结帧下 score 不更新，会把"没冻"误报成"收集失败"。
check('收集期间帧持续推进', s.frame > f0, `${f0} → ${s.frame}`);

await call({ op: 'cmd', command: { cmd: 'restart' } });
await sleep(1200);
s = (await call({ op: 'state' })).state;
check('重玩后计分归零', s.score === 0, `score=${s.score}`);
check('重玩后 cleared=false', s.cleared === false);
const back = Math.hypot(num(s.position?.[0]), num(s.position?.[2]));
check('角色回到出生点', back < 2.0, `距原点 ${back.toFixed(1)}m`);

console.log(failures === 0 ? '\n✓ 玩法端到端全部通过' : `\n✗ ${failures} 项未通过`);
process.exit(failures === 0 ? 0 : 1);
