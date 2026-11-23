// Stage 6, acceptance item 9: waits for the reader shell of a starting App and polls its status every
// 0.1 s over one DevTools connection, until the first layout is ready. Prints JSON with the time of this
// computer (ms since 1970) when the shell page appeared and when it was ready, and the shell's status.
// Usage: node open_poll.mjs <port> <limit ms>   (the adb forward to the App's DevTools socket is set up by the caller)
const [port = '9333', limit = '300000'] = process.argv.slice(2);
const deadline = Date.now() + Number(limit);
const sleep = ms => new Promise(r => setTimeout(r, ms));
let target = null;
while (Date.now() < deadline && !target) {
  try {
    const targets = await (await fetch(`http://127.0.0.1:${port}/json`, { signal: AbortSignal.timeout(2000) })).json();
    target = targets.find(t => (t.url || '').includes('/shell/reader.html')) || null;
  } catch (e) { /* no socket yet */ }
  if (!target) await sleep(100);
}
if (!target) { console.log(JSON.stringify({ timeout: 'no shell page' })); process.exit(2); }
const shellAt = Date.now();
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
let id = 0;
const pending = new Map();
ws.onmessage = ev => { const m = JSON.parse(ev.data); const p = pending.get(m.id); if (p) { pending.delete(m.id); p(m); } };
const evaluate = expr => new Promise(res => {
  const i = ++id;
  pending.set(i, res);
  ws.send(JSON.stringify({ id: i, method: 'Runtime.evaluate', params: { expression: expr, returnByValue: true } }));
});
while (Date.now() < deadline) {
  const r = await evaluate('JSON.stringify(window.__reader ? window.__reader.status() : null)');
  const v = r.result && r.result.result && r.result.result.value;
  const s = v ? JSON.parse(v) : null;
  if (s && s.ready && s.seq >= 1) {
    console.log(JSON.stringify({ shellAt, readyAt: Date.now(), status: s }));
    ws.close();
    process.exit(0);
  }
  await sleep(100);
}
console.log(JSON.stringify({ timeout: 'not ready', shellAt }));
process.exit(3);
