#!/usr/bin/env node
// 通过 CDP 对 KirbyScene 页面截图。
// 用法：node tool/cdp_shot.mjs out.png
const DEBUG_PORT = process.env.KIRBY_CDP_PORT || 9333;
const out = process.argv[2] || 'shot.png';
const fs = await import('node:fs');

const targets = await (await fetch(`http://127.0.0.1:${DEBUG_PORT}/json/list`)).json();
const page = targets.find(t => t.type === 'page');
if (!page) { console.error('没有页面 target'); process.exit(1); }

const ws = new WebSocket(page.webSocketDebuggerUrl);
let msgId = 0;
const pending = new Map();
function send(method, params) {
  return new Promise((resolve, reject) => {
    const id = ++msgId;
    pending.set(id, { resolve, reject });
    ws.send(JSON.stringify({ id, method, params }));
  });
}
ws.onmessage = (ev) => {
  const msg = JSON.parse(ev.data);
  if (msg.id && pending.has(msg.id)) {
    const { resolve, reject } = pending.get(msg.id);
    pending.delete(msg.id);
    msg.error ? reject(new Error(JSON.stringify(msg.error))) : resolve(msg.result);
  }
};
await new Promise(r => { ws.onopen = r; });

// 等一帧新画面（让引擎跑起来再截）。
await send('Runtime.evaluate', { expression: 'new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))', awaitPromise: true });
const shot = await send('Page.captureScreenshot', { format: 'png' });
fs.writeFileSync(out, Buffer.from(shot.data, 'base64'));
console.log('已保存', out);
ws.close();
process.exit(0);
