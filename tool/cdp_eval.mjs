#!/usr/bin/env node
// 在 KirbyScene 的 Chrome 调试会话（dev.sh，端口 9333）里执行一段 JS 并打印结果。
// 用法：node tool/cdp_eval.mjs 'window.kirbyMcp.state'
const DEBUG_PORT = process.env.KIRBY_CDP_PORT || 9333;

const targets = await (await fetch(`http://127.0.0.1:${DEBUG_PORT}/json/list`)).json();
const page = targets.find(t => t.type === 'page');
if (!page) {
  console.error('没有找到页面 target：', targets.map(t => `${t.type} ${t.url}`));
  process.exit(1);
}

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

ws.onerror = (e) => { console.error('WS 错误', e.message ?? e); process.exit(1); };

await new Promise(r => { ws.onopen = r; });

const expr = process.argv[2];
const result = await send('Runtime.evaluate', {
  expression: expr,
  returnByValue: true,
  awaitPromise: true,
});
if (result.exceptionDetails) {
  console.error('页面异常：', JSON.stringify(result.exceptionDetails, null, 2));
} else {
  console.log(JSON.stringify(result.result.value, null, 2));
}
ws.close();
process.exit(0);
