#!/usr/bin/env node
// 通过 Dart VM Service（flutter run 打印的那个 ws://127.0.0.1:<port>/<token>/ws）
// 触发**热重载**，用于桌面端会话由别人拉起、我们只能远程操作时的迭代。
//
// 用法：
//   node tool/vm_reload.mjs http://127.0.0.1:57949/dQRMHWr1Sxg=/
//
// 注意：VM Service 只能热重载（reloadSources），做不到 flutter-tool 级的热重启
// （重跑 main）。改到 initialize() 里的几何/节点组装时，仍需在会话终端按 R。
import fs from 'node:fs';

const base = process.argv[2];
if (!base) {
  console.error('用法：node tool/vm_reload.mjs <VM Service URL，如 http://127.0.0.1:57949/TOKEN=/>');
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
  }
};

await new Promise((resolve, reject) => {
  ws.onopen = resolve;
  ws.onerror = () => reject(new Error(`连不上 VM Service：${wsUrl}`));
});

const vm = await send('getVM');
const isolateId = vm.isolates?.[0]?.id;
if (!isolateId) {
  console.error('没有找到 isolate：', JSON.stringify(vm));
  process.exit(1);
}

const before = vm.isolates[0];
const result = await send('reloadSources', { isolateId, force: false });
console.log(JSON.stringify({ isolate: isolateId, before: before.name, result }, null, 2));
ws.close();
process.exit(0);
