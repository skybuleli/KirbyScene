#!/usr/bin/env node
// 诊断：逐颗星核报告是否被收集，并打印该点的地形高度与角色落点。
// 用途是定位 gameplay_audit 的 11/12 —— 是坐标不匹配、落点未就绪还是收集半径不够。
import net from 'node:net';

const PORT = 7008;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function call(payload, timeoutMs = 8000) {
  return new Promise((resolve, reject) => {
    const sock = net.createConnection({ host: '127.0.0.1', port: PORT });
    let buf = ''; let done = false;
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

const rings = [[8.0, 4], [14.0, 4], [19.5, 4]];
const list = [];
let idx = 0;
for (const [r, n] of rings) {
  for (let i = 0; i < n; i++) {
    const a = (i / n) * Math.PI * 2 + idx * 0.35;
    list.push({ idx: idx++, x: Math.cos(a) * r, z: Math.sin(a) * r, r });
  }
}

await call({ op: 'cmd', command: { cmd: 'restart' } });
await sleep(1500);
let prev = 0;
for (const p of list) {
  await call({ op: 'cmd', command: { cmd: 'teleport', x: p.x, z: p.z } });
  await sleep(900);
  const st = (await call({ op: 'state' })).state;
  const got = st.score > prev;
  // 星核在 terrain.heightAt+1.15；角色 position 是脚底，比较二者差值即 dy。
  const dy = (st.groundY ?? NaN) - st.position[1];
  console.log(
    `${got ? '✓' : '✗'} #${String(p.idx).padStart(2)} r=${p.r} ` +
    `(${p.x.toFixed(2)}, ${p.z.toFixed(2)}) score=${st.score} ` +
    `pos=(${st.position.map((v) => v.toFixed(2)).join(',')}) ` +
    `groundY=${(st.groundY ?? NaN).toFixed(2)} airborne=${st.airborne} ` +
    `frame=${st.frame}`
  );
  if (got) prev = st.score;
}
const s = (await call({ op: 'state' })).state;
console.log(`\n最终 score=${s.score}/12 cleared=${s.cleared}`);
