const [port, mode, vertical, columns] = process.argv.slice(2);
const t = (await (await fetch(`http://127.0.0.1:${port}/json`)).json()).find(x => (x.url || '').includes('reader.html'));
const ws = new WebSocket(t.webSocketDebuggerUrl); await new Promise(r => ws.onopen = r);
let id = 0; const pend = new Map();
ws.onmessage = e => { const m = JSON.parse(e.data); if (pend.has(m.id)) { pend.get(m.id)(m); pend.delete(m.id); } };
const ev = expr => new Promise(res => { const i = ++id; pend.set(i, m => res(m.result && m.result.result ? m.result.result.value : m)); ws.send(JSON.stringify({ id: i, method: 'Runtime.evaluate', params: { expression: expr, awaitPromise: true, returnByValue: true } })); });
const s = { vertical: vertical === 'true', columns: Number(columns), gap: 40, fontSize: 20, lineHeight: 1.8, letterSpacing: 0.05, indent: 1, paraSpacing: 0.5, fontFamily: '"ReaderImported", serif', margins: { top: 40, bottom: 40, left: 30, right: 30 } };
await ev(`window.__reader.open({ src: '/book/zh.xhtml', mode: ${JSON.stringify(mode)}, settings: ${JSON.stringify(s)} })`);
console.log(JSON.stringify(await ev(`(() => {
  const S = window.__reader.state; const a = window.__reader.analyze();
  const d = S.frames[0].contentDocument, colOf = S.colOf, w = d.createTreeWalker(d.body, NodeFilter.SHOW_TEXT);
  let idx = 0, maxc = -1, total = 0, rt = 0; const nonRt = [];
  for (let n = w.nextNode(); n; n = w.nextNode()) for (let j = 0; j < n.data.length; j++) {
    if (/\\s/.test(n.data[j])) continue;
    if (colOf[idx] < maxc) { total++; if (n.parentElement.tagName.toLowerCase() === 'rt') rt++; else if (nonRt.length < 5) nonRt.push(n.data[j]); }
    maxc = Math.max(maxc, colOf[idx]); idx++;
  }
  return { mode: ${JSON.stringify(mode)}, columns: a.columns, monotonicViolations: a.monotonicViolations, counted: total, inRt: rt, nonRtSample: nonRt };
})()`)));
ws.close();
