import fs from 'node:fs'; import { spawnSync } from 'node:child_process';
const [port, outPrefix] = process.argv.slice(2);
const t = (await (await fetch(`http://127.0.0.1:${port}/json`)).json()).find(x => (x.url || '').includes('reader.html'));
const ws = new WebSocket(t.webSocketDebuggerUrl); await new Promise(r => ws.onopen = r);
let id = 0; const pend = new Map();
ws.onmessage = e => { const m = JSON.parse(e.data); if (pend.has(m.id)) { pend.get(m.id)(m); pend.delete(m.id); } };
const ev = expr => new Promise(res => { const i = ++id; pend.set(i, m => res(m.result && m.result.result ? m.result.result.value : m)); ws.send(JSON.stringify({ id: i, method: 'Runtime.evaluate', params: { expression: expr, awaitPromise: true, returnByValue: true } })); });
const shot = name => { spawnSync('sleep', ['3']); const r = spawnSync('/opt/android-sdk/platform-tools/adb', ['exec-out', 'screencap', '-p'], { maxBuffer: 64 << 20 }); fs.writeFileSync(name, r.stdout); console.log('saved', name); };
const s = { vertical: true, columns: 1, gap: 40, fontSize: 20, lineHeight: 1.8, letterSpacing: 0.05, indent: 1, paraSpacing: 0.5, fontFamily: '"ReaderImported", serif', margins: { top: 40, bottom: 40, left: 30, right: 30 } };
await ev(`window.__reader.open({ src: '/book/zh.xhtml', mode: 'B', settings: ${JSON.stringify(s)} })`);
const info = await ev(`(() => {
  const S = window.__reader.state; window.__reader.analyze();
  const f = S.frames[0], d = f.contentDocument, colOf = S.colOf, w = d.createTreeWalker(d.body, NodeFilter.SHOW_TEXT), r = d.createRange();
  let idx = 0, maxc = -1; const groups = [];
  for (let n = w.nextNode(); n; n = w.nextNode()) for (let j = 0; j < n.data.length; j++) {
    if (/\\s/.test(n.data[j])) continue;
    if (colOf[idx] < maxc && n.parentElement.tagName.toLowerCase() === 'rt' && !groups.some(g => g.node === n)) {
      const ruby = n.parentElement.closest('ruby'); const base = ruby.firstChild;
      r.setStart(base, 0); r.setEnd(base, 1); const b = r.getClientRects()[0];
      r.setStart(n, 0); r.setEnd(n, n.data.length); const q = r.getClientRects()[0];
      groups.push({ node: n, rt: n.data, base: base.data, baseCol: maxc, rtCol: colOf[idx], baseRect: [b.left, b.top, b.width, b.height].map(Math.round), rtRect: [q.left, q.top, q.width, q.height].map(Math.round) });
    }
    maxc = Math.max(maxc, colOf[idx]); idx++;
  }
  return groups.map(g => { delete g.node; return g; });
})()`);
console.log(JSON.stringify(info));
const g = info[0];
const frameRect = await ev(`(() => { const r = window.__reader.state.frames[0].getBoundingClientRect(); return [r.left, r.top, r.width, r.height, devicePixelRatio, window.__reader.state.geo.contentH + window.__reader.state.geo.pageGap]; })()`);
console.log('frame', JSON.stringify(frameRect));
await ev(`window.__reader.goSpread(${g.baseCol})`); shot(`${outPrefix}-page${g.baseCol}-base.png`);
await ev(`window.__reader.goSpread(${g.baseCol - 1})`); shot(`${outPrefix}-page${g.baseCol - 1}-previous.png`);
ws.close();
