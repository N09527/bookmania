// Drive the prototype inside an Android WebView over the DevTools protocol.
// Usage: node cdp-run.mjs <port> <outDir> <label>
import fs from 'node:fs';
import path from 'node:path';

const [port = '9333', outDir = 'out-android', label = 'android'] = process.argv.slice(2);
fs.mkdirSync(outDir, { recursive: true });
const targets = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
const target = targets.find(t => (t.url || '').includes('reader.html'));
if (!target) { console.error('no reader target', targets.map(t => t.url)); process.exit(2); }
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
let seq = 0; const pending = new Map();
ws.onmessage = ev => { const m = JSON.parse(ev.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); } };
const send = (method, params = {}) => new Promise(res => { const id = ++seq; pending.set(id, res); ws.send(JSON.stringify({ id, method, params })); });
async function ev(expr) {
  const r = await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true });
  if (r.error || (r.result && r.result.exceptionDetails)) throw new Error(JSON.stringify(r.error || r.result.exceptionDetails).slice(0, 800));
  return r.result.result.value;
}
async function shot(name) {
  const r = await send('Page.captureScreenshot', { format: 'png' });
  if (r.result && r.result.data) fs.writeFileSync(path.join(outDir, name), Buffer.from(r.result.data, 'base64'));
}
const J = JSON.stringify;
const report = { label, userAgent: await ev('navigator.userAgent'), viewport: await ev('[innerWidth, innerHeight, devicePixelRatio]'),
  supportsColumnWrap: await ev("CSS.supports('column-wrap', 'wrap')"), cases: [], location: [] };

const base = { vertical: true, columns: 2, gap: 40, fontSize: 20, lineHeight: 1.8, letterSpacing: 0.05, indent: 1, paraSpacing: 0.5,
  fontFamily: '"ReaderImported", serif', margins: { top: 40, bottom: 40, left: 30, right: 30 } };
const cases = [
  ['B-vertical-2col', 'B', base], ['B-vertical-1col', 'B', Object.assign({}, base, { columns: 1 })],
  ['A-vertical-2col', 'A', base],
  ['H-horizontal-2col', 'H', Object.assign({}, base, { vertical: false })],
];
for (const [name, mode, s] of cases) {
  const opened = await ev(`window.__reader.open({ src: '/book/zh.xhtml', mode: ${J(mode)}, settings: ${J(s)} })`);
  const an = await ev('window.__reader.analyze()');
  const seqIdx = []; let partial = 0;
  for (let k = 0; k < an.spreads; k++) {
    const v = await ev(`window.__reader.visibleAt(${k})`);
    partial += v.partial; for (const l of v.lists) seqIdx.push(...l);
  }
  let missing = 0, dup = 0, outOfOrder = 0; const seen = new Set();
  for (let i = 0; i < seqIdx.length; i++) { if (seen.has(seqIdx[i])) dup++; seen.add(seqIdx[i]); if (i && seqIdx[i] < seqIdx[i - 1]) outOfOrder++; }
  for (let i = 0; i < an.totalChars; i++) if (!seen.has(i)) missing++;
  await ev('window.__reader.goSpread(0)'); await new Promise(r => setTimeout(r, 1500));
  await shot(`${label}-${name}-spread0.png`);
  const first3 = [];
  for (let k = 0; k < Math.min(3, an.spreads); k++) first3.push((await ev(`window.__reader.visibleAt(${k})`)).columns);
  const t = an.text.replace(/\s/g, '');
  const secIdx = t.indexOf('【安全測試】'); let hit = null;
  if (secIdx >= 0) {
    const k = await ev(`window.__reader.goToChar(${secIdx})`);
    const pts = await ev("window.__reader.linkRects('#note1')");
    hit = pts.length ? await ev(`window.__reader.hit(${pts[0].x}, ${pts[0].y})`) : 'link not visible';
    await new Promise(r => setTimeout(r, 1500)); await shot(`${label}-${name}-security-spread${k}.png`);
  }
  const frames = await ev('window.__reader.frameInfo()');
  report.cases.push({ name, mode, opened, totalChars: an.totalChars, columns: an.columns, columnCountFromScroll: an.columnCountFromScroll,
    spreads: an.spreads, monotonicViolations: an.monotonicViolations, straddles: an.straddles, clipped: an.inlineOverflow, overhang: an.overhang,
    walk: { visible: seqIdx.length, missing, duplicated: dup, outOfOrder, partiallyVisible: partial }, first3, footnoteHit: hit,
    frames: frames.map(f => ({ title: f.title, writingMode: f.writingMode, fontFaces: f.fontFaces })) });
  console.log(name, JSON.stringify(report.cases[report.cases.length - 1]));
}
// Reading location across setting changes (B, vertical two columns)
{
  await ev(`window.__reader.open({ src: '/book/zh.xhtml', mode: 'B', settings: ${J(base)} })`);
  const an = await ev('window.__reader.analyze()');
  const k0 = Math.min(5, an.spreads - 1); await ev(`window.__reader.goSpread(${k0})`);
  const loc = await ev('window.__reader.location()'); const steps = [];
  for (const [lab, patch] of [['fontSize 20→26', { fontSize: 26 }], ['lineHeight 1.8→2.2', { fontSize: 26, lineHeight: 2.2 }], ['back to defaults', {}]]) {
    const ns = Object.assign({}, base, patch);
    const rl = await ev(`window.__reader.relayout(${J(ns)})`); await ev('window.__reader.analyze()');
    const k = await ev(`window.__reader.goToChar(${loc})`); const v = await ev(`window.__reader.visibleAt(${k})`);
    steps.push({ change: lab, spread: k, locVisible: v.lists.some(a => a.includes(loc)), relayoutMs: Math.round(rl.relayoutMs) });
  }
  report.location.push({ name: 'loc-B', startSpread: k0, loc, steps });
  console.log('loc-B', JSON.stringify(report.location[0]));
}
fs.writeFileSync(path.join(outDir, `${label}-report.json`), JSON.stringify(report, null, 2));
console.log('UA', report.userAgent, 'viewport', report.viewport, 'column-wrap', report.supportsColumnWrap);
ws.close();
