// Step-by-step CDP evaluation with per-step timing and a timeout per step.
const port = process.argv[2] || '9333';
const t = (await (await fetch(`http://127.0.0.1:${port}/json`)).json()).find(x => (x.url || '').includes('reader.html'));
const ws = new WebSocket(t.webSocketDebuggerUrl); await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
ws.onclose = e => console.log('ws closed', e.code);
let id = 0; const pend = new Map();
ws.onmessage = e => { const m = JSON.parse(e.data); if (pend.has(m.id)) { pend.get(m.id)(m); pend.delete(m.id); } };
const ev = (expr, ms = 600000) => new Promise((res) => { const i = ++id; const to = setTimeout(() => { pend.delete(i); res({ timeout: true }); }, ms);
  pend.set(i, m => { clearTimeout(to); res(m.result && m.result.result ? m.result.result.value : m); });
  ws.send(JSON.stringify({ id: i, method: 'Runtime.evaluate', params: { expression: expr, awaitPromise: true, returnByValue: true } })); });
const step = async (label, expr, ms) => { const t0 = Date.now(); const v = await ev(expr, ms); console.log(new Date().toISOString().slice(11, 19), label, ((Date.now() - t0) / 1000).toFixed(1) + 's', JSON.stringify(v).slice(0, 700)); return v; };
await step('ping', '1+1', 60000);
await step('state', 'JSON.stringify({mode: window.__reader.state.mode, frames: window.__reader.state.frames.length, cols: window.__reader.state.columnCount})', 60000);
await step('analyze', '(() => { const a = window.__reader.analyze(); delete a.text; return a; })()', 900000);
await step('verifyFast', '(() => { const v = window.__reader.verifyFast(); delete v.text; return v; })()', 900000);
ws.close();
