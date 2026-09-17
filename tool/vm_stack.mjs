#!/usr/bin/env node
// 通过 Dart VM Service 抓**运行中 App 的 Dart 调用栈**。
//
// 为什么需要它：App"卡住"的时候，`sample` 只能给到原生帧 —— Dart 代码在
// JIT 里跑，符号是 `???`，看不出是哪段 Dart 在自旋。而 VM Service 的
// `getStack` 是**由 VM 自己的线程**处理的，即使主 isolate 正卡在死循环/微任务
// 洪流里也能应答（它会短暂中断 isolate 取栈）。于是它是定位
// "主线程不动了"这类问题的唯一直接证据。
//
// 用法（URL 就是 `flutter run` 打印的那个）：
//
//     node tool/vm_stack.mjs http://127.0.0.1:57949/dQRMHWr1Sxg=/
//     node tool/vm_stack.mjs <url> --all      # 打印全部 isolate
//     node tool/vm_stack.mjs <url> --json     # 原始 JSON
//
// 判读要点：
//   * 栈里出现**同一批帧反复出现**（尤其是 `_rootRun` / `_runGuarded` /
//     `runZoned` 之下的业务函数），就是"微任务洪流"：某个 Future 回调在
//     自己之后又排了一个微任务，队列永远不空 → 事件循环（定时器、socket、
//     键盘）**永远轮不到**。表现就是"按键没反应，几十秒后才恢复"。
//   * 只看到 `_RawReceivePort._handleMessage` 之类的框架帧时，栈顶那几帧才是
//     关键，往下找第一个不属于 `dart:async` 的帧。
// 用 Node 内置的全局 WebSocket（与其他 tool/vm_*.mjs 一致，无需依赖）。
const base = process.argv[2];
const WANT_ALL = process.argv.includes('--all');
const WANT_JSON = process.argv.includes('--json');
if (!base) {
  console.error('用法：node tool/vm_stack.mjs <VM Service URL，如 http://127.0.0.1:57949/TOKEN=/>');
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
    // 卡住的 isolate 取栈可能稍慢，给宽一点。
    const t = setTimeout(() => {
      if (pending.delete(msgId)) reject(new Error(`${method} 超时`));
    }, 15000);
    const done = (fn) => (v) => {
      clearTimeout(t);
      fn(v);
    };
    pending.set(msgId, { resolve: done(resolve), reject: done(reject) });
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
const isolates = (vm.isolates ?? []).filter((i) => WANT_ALL || i.name !== 'vm-service');
if (!isolates.length) {
  console.error('没有找到 isolate：', JSON.stringify(vm).slice(0, 400));
  process.exit(1);
}

const out = [];
for (const iso of isolates) {
  let stack = null;
  let err = null;
  try {
    stack = await send('getStack', { isolateId: iso.id, limit: 64 });
  } catch (e) {
    err = e.message;
  }
  out.push({ isolate: iso, stack, err });
}

if (WANT_JSON) {
  console.log(JSON.stringify(out, null, 2));
  ws.close();
  process.exit(0);
}

for (const { isolate, stack, err } of out) {
  console.log(`\n=== isolate ${isolate.id}  ${isolate.name ?? ''}  ${isolate.isPaused ? '(paused)' : ''} ===`);
  if (err) {
    console.log(`  ✗ 取栈失败：${err}`);
    continue;
  }
  const frames = stack?.frames ?? [];
  if (!frames.length) {
    console.log('  （空栈 —— isolate 可能正阻塞在原生调用里）');
    continue;
  }
  // `getStack` 返回的是**最内层在前**；倒过来打印更接近直观的调用顺序。
  for (const f of [...frames].reverse()) {
    const fn = f.function?.name ?? '?';
    // 只显示文件名，去掉很长的绝对路径尾巴。
    const file = (f.function?.location?.script?.uri ?? '').replace(/^file:\/\/.*\/(lib|test)\//, '$1/');
    const line = f.function?.location?.line;
    console.log(`  ${fn}  ${file ? `(${file}${line != null ? `:${line}` : ''})` : ''}`);
  }
  console.log(`  —— 共 ${frames.length} 帧`);
}

ws.close();
process.exit(0);
