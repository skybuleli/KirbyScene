#!/usr/bin/env node
// 直连运行中的 KirbyScene **桌面端**（App 内回环端口 7008）做远程验证。
//
// 为什么要有它：桌面端会话常常由用户在自己的终端（或别的 agent 宿主）拉起，
// 本脚本让我们即使无法自己启动 App，也能读状态、发命令、拿截图。
//
// 用法：
//   node tool/inproc_eval.mjs '{"op":"state"}'
//   node tool/inproc_eval.mjs '{"op":"cmd","command":{"cmd":"teleport","x":10,"z":10}}'
//   node tool/inproc_eval.mjs '{"op":"screenshot"}' --out shot.png
//
// 协议（lib/mcp/inproc_host_io.dart）：换行分隔 JSON，op = state / cmd / screenshot / ping。
import net from 'node:net';
import fs from 'node:fs';

const PORT = Number(process.env.KIRBY_INPROC_PORT || 7008);
const request = process.argv[2] || '{"op":"ping"}';
const outIdx = process.argv.indexOf('--out');
const outPath = outIdx > -1 ? process.argv[outIdx + 1] : null;

const socket = net.createConnection({ host: '127.0.0.1', port: PORT });
let buffer = '';
let done = false;

socket.setTimeout(10000);

socket.on('connect', () => {
  // 协议按行分帧：请求必须带换行，否则服务端留在缓冲区永不回。
  socket.write(`${request}\n`);
});

socket.on('data', (chunk) => {
  buffer += chunk.toString('utf8');
  const nl = buffer.indexOf('\n');
  if (nl === -1) return;
  const line = buffer.slice(0, nl);
  finish(line);
});

socket.on('timeout', () => fail(`连接 ${PORT} 超时（App 没在跑？）`));
socket.on('error', (e) => fail(`连不上 127.0.0.1:${PORT} —— ${e.message}`));

function finish(line) {
  if (done) return;
  done = true;
  let reply;
  try {
    reply = JSON.parse(line);
  } catch {
    console.error('非 JSON 响应：', line);
    process.exit(1);
  }
  if (outPath && reply.ok && reply.png) {
    fs.writeFileSync(outPath, Buffer.from(reply.png, 'base64'));
    console.log('已保存截图', outPath);
  } else {
    console.log(JSON.stringify(reply, null, 2));
  }
  socket.end();
  process.exit(reply.ok === false ? 1 : 0);
}

function fail(msg) {
  if (done) return;
  done = true;
  console.error(msg);
  process.exit(1);
}
