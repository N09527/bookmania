// Minimal DevTools client for the Bookmania reader shell (debug builds only).
// Usage: node cdp.mjs <port> <expression>   → prints the JSON value of the expression
const [port = '9333', expr = 'window.__reader.status()'] = process.argv.slice(2);
setTimeout(() => { console.log(JSON.stringify({ timeout: true })); process.exit(3); }, 20000).unref();
const targets = await (await fetch(`http://127.0.0.1:${port}/json`, { signal: AbortSignal.timeout(10000) })).json();
const target = targets.find(t => (t.url || '').includes('/shell/reader.html'));
if (!target) { console.log(JSON.stringify({ noTarget: targets.map(t => t.url) })); process.exit(2); }
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
const r = await new Promise(res => {
  ws.onmessage = ev => { const m = JSON.parse(ev.data); if (m.id === 1) res(m); };
  ws.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: { expression: expr, returnByValue: true, awaitPromise: true } }));
});
ws.close();
const res = r.result || {};
if (res.exceptionDetails) { console.log(JSON.stringify({ exception: res.exceptionDetails.text || res.exceptionDetails })); process.exit(1); }
console.log(JSON.stringify(res.result ? res.result.value : null));
