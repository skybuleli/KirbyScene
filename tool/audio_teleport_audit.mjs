#!/usr/bin/env node
// 音频开启时反复远距离传送：桥接应答与帧推进缺一不可。
// 每次请求有宿主超时；它只判失败，不能中断 App 内同步 FFI。
import net from 'node:net';
import { execFileSync } from 'node:child_process';
const sleep = ms => new Promise(r => setTimeout(r, ms));
const rounds = Number(process.argv[2] || 12);
// 可选节流对照；默认保留原复现时序，不把等待当成音频修复。
const idleMs = process.argv.includes('--idle') ? 500 : 0;
if (!Number.isInteger(rounds) || rounds < 1 || rounds > 100) {
  throw new Error('轮数必须为 1 到 100 的整数');
}
const points = [[24,0],[30,0],[0,0],[-40,0],[70,0],[-90,0]];
function call(payload) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(7008, '127.0.0.1'); let buffer = '';
    const timer = setTimeout(() => socket.destroy(new Error('桥接超过 5 秒无应答')), 5000);
    socket.on('connect', () => socket.write(JSON.stringify(payload)+'\n'));
    socket.on('data', d => {
      buffer += d; const n = buffer.indexOf('\n'); if (n < 0) return;
      clearTimeout(timer); socket.destroy();
      try { const v = JSON.parse(buffer.slice(0,n)); if (!v.ok || v.result?.ok === false) throw new Error(JSON.stringify(v)); resolve(v); } catch(e) { reject(e); }
    });
    socket.on('error', e => { clearTimeout(timer); reject(e); });
  });
}
const cmd = command => call({op:'cmd',command});
const state = async () => (await call({op:'state'})).state;
try {
  execFileSync('open', [process.cwd()+'/build/macos/Build/Products/Debug/kirby_scene.app']);
  // open 只确认启动请求送达，首建启动可能尚未监听；就绪后才开始审计。
  const readyDeadline = Date.now() + 30000;
  let ready = false;
  while (Date.now() < readyDeadline) {
    try { ready = (await state()).ready === true; } catch (e) {
      if (e.code !== 'ECONNREFUSED') throw e;
    }
    if (ready) break;
    await sleep(250);
  }
  if (!ready) throw new Error('App 未就绪');
  await cmd({cmd:'arm_audio'});
  await cmd({cmd:'release_keys',all:true});
  await cmd({cmd:'set_weather',kind:'clear'});
  const deadline = Date.now()+15000;
  while (!((await state()).audio?.started && (await state()).audio?.bakeDone)) {
    if (Date.now()>deadline) throw new Error('音频未起播');
    await sleep(100);
  }
  await sleep(1000);
  for (let i=0;i<rounds;i++) {
    for (const [x,z] of points) {
      if (idleMs) await sleep(idleMs);
      const before = await state();
      console.log(`传送 ${i+1}/${rounds} (${x},${z}) frame=${before.frame}`);
      await cmd({cmd:'teleport',x,z});
      await sleep(170 + (i%4)*37);
      const after = await state();
      if (!after.ready || after.frame<=before.frame) throw new Error('帧未前进');
      if (!Number.isFinite(after.audio?.characterSpeed) || after.audio.characterSpeed > 64.01) {
        throw new Error('传送后的音频速度超出运动采样边界');
      }
    }
  }
  await cmd({cmd:'teleport',x:0,z:0});
  await sleep(1000);
  const levels = (await cmd({cmd:'audio_levels'})).result;
  if (!levels.ok || levels.activeVoices===0) throw new Error('未确认活跃音频声部');
  console.log(`通过：${rounds*points.length} 次远距离传送，最终音频=${JSON.stringify(levels)}`);
} catch(e) {
  console.error(`失败：${e.message}`);
  process.exitCode = 1;
}
