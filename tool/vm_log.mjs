#!/usr/bin/env node
// 监听 Dart VM Service 的 Log 流，抓取 flutter run 应用的 debugPrint/异常输出。
// 用法：node tool/vm_log.mjs <vmServiceUrl> [秒数，默认 8]
const base = process.argv[2];
const seconds = Number(process.argv[3] || 8);
if (!base) {
  console.error('用法：node tool/vm_log.mjs <vmServiceUrl> [秒数]');
  process.exit(2);
}
const wsUrl = `${base.replace(/\/$/, '')}/ws`;
const ws = new WebSocket(wsUrl);
let id = 0;
const pending = new Map();

function send(method, params = {}) {
  return new Promise((resolve, reject) => {
    const msgId = ++id;
    pending.set(msgId, { resolve, reject });
    ws.send(JSON.stringify({ jsonrpc: '2.0', id: msgId, method, params }));
  });
}

ws.onmessage = (ev) => {
  const msg = JSON.parse(ev.data);
  if (msg.id && pending.has(msg.id)) {
    const { resolve, reject } = pending.get(msg.id);
    pending.delete(msg.id);
    msg.error ? reject(new Error(JSON.stringify(msg.error))) : resolve(msg.result);
    return;
  }
  if (msg.method === 'Log' && msg.params) {
    const ts = new Date().toISOString().slice(11, 19);
    console.log(`[${ts}] (${msg.params.kind ?? 'log'}) ${msg.params.message ?? ''}`);
    if (msg.params.error) console.log(msg.params.error);
  }
};

await new Promise((resolve, reject) => {
  ws.onopen = resolve;
  ws.onerror = () => reject(new Error(`连不上 VM Service：${wsUrl}`));
});

const vm = await send('getVM');
const isolateId = vm.isolates?.[0]?.id;
await send('streamListen', { streamId: 'Log' });
console.log(`>> 已订阅 Log 流（${seconds}s），isolate=${isolateId}`);
await new Promise((r) => setTimeout(r, seconds * 1000));
await send('streamCancel', { streamId: 'Log' });
ws.close();
process.exit(0);
