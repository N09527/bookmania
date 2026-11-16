// Run verifyFast() inside an Android WebView over the DevTools protocol, with progress logs.
// Usage: node cdp-fast.mjs <port> <outDir> <label>
import fs from 'node:fs';
import { spawnSync } from 'node:child_process';
import path from 'node:path';

const [port = '9333', outDir = 'out-android', label = 'android'] = process.argv.slice(2);
fs.mkdirSync(outDir, { recursive: true });
const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);
const targets = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
const target = targets.find(t => (t.url || '').includes('reader.html'));
if (!target) { log('no reader target', JSON.stringify(targets.map(t => t.url))); process.exit(2); }
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
let seq = 0; const pending = new Map();
ws.onmessage = ev => { const m = JSON.parse(ev.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); } };
const send = (method, params = {}) => new Promise(res => { const id = ++seq; pending.set(id, res); ws.send(JSON.stringify({ id, method, params })); });
const withTimeout = (p, ms, what) => { let t; return Promise.race([p, new Promise((_, rej) => { t = setTimeout(() => rej(new Error('timeout: ' + what)), ms); })]).finally(() => clearTimeout(t)); };
async function ev(expr, ms = 600000) {
  const r = await withTimeout(send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true }), ms, expr.slice(0, 60));
  if (r.error || (r.result && r.result.exceptionDetails)) throw new Error(JSON.stringify(r.error || r.result.exceptionDetails).slice(0, 800));
  return r.result.result.value;
}
// Page.captureScreenshot never returns on this software-rendered emulator: use adb screencap instead.
async function shot(name) {
  await new Promise(r => setTimeout(r, 2500));
  const r = spawnSync('/opt/android-sdk/platform-tools/adb', ['exec-out', 'screencap', '-p'], { maxBuffer: 64 << 20, timeout: 120000 });
  if (r.status === 0 && r.stdout && r.stdout.length > 1000) { fs.writeFileSync(path.join(outDir, name), r.stdout); log('screenshot', name); }
  else log('screenshot failed', name, r.status, String(r.stderr || '').slice(0, 200));
}
const J = JSON.stringify;
// The page target can exist before reader.js has executed (slow devices): wait for the shell.
for (let t0 = Date.now(); ; ) {
  const ready = await ev("document.readyState === 'complete' && typeof window.__reader === 'object'");
  if (ready) break;
  if (Date.now() - t0 > 300000) { log('shell never became ready'); process.exit(3); }
  await new Promise(r => setTimeout(r, 2000));
}
const report = { label, userAgent: await ev('navigator.userAgent'), viewport: await ev('[innerWidth, innerHeight, devicePixelRatio]'),
  supportsColumnWrap: await ev("CSS.supports('column-wrap', 'wrap')"), cases: [], location: null };
log('UA', report.userAgent, 'viewport', J(report.viewport), 'column-wrap', report.supportsColumnWrap);

const base = { vertical: true, columns: 2, gap: 40, fontSize: 20, lineHeight: 1.8, letterSpacing: 0.05, indent: 1, paraSpacing: 0.5,
  fontFamily: '"ReaderImported", serif', margins: { top: 40, bottom: 40, left: 30, right: 30 } };
const cases = [
  ['B-vertical-2col', 'B', base],
  ['A-vertical-2col', 'A', base],
  ['H-horizontal-2col', 'H', Object.assign({}, base, { vertical: false })],
  ['B-vertical-1col', 'B', Object.assign({}, base, { columns: 1 })],
];
for (const [name, mode, s] of cases) {
  log('open', name);
  const opened = await ev(`window.__reader.open({ src: '/book/zh.xhtml', mode: ${J(mode)}, settings: ${J(s)} })`);
  log('verify', name);
  const v = await ev('window.__reader.verifyFast()');
  const t = v.text.replace(/\s/g, ''); delete v.text;
  const frames = await ev('window.__reader.frameInfo()');
  let hit = null;
  const secIdx = t.indexOf('【安全測試】');
  if (secIdx >= 0 && mode !== 'A') {
    const k = await ev(`window.__reader.goToChar(${secIdx})`);
    const pts = await ev("window.__reader.linkRects('#note1')");
    hit = pts.length ? await ev(`window.__reader.hit(${pts[0].x}, ${pts[0].y})`) : 'link not visible';
    if (name === 'B-vertical-2col') { await new Promise(r => setTimeout(r, 2000)); await shot(`${label}-${name}-security-spread${k}.png`); }
  }
  if (name === 'B-vertical-2col' && v.monotonicViolations > 0) {
    // Which columns hold a ruby whose annotation is measured in an earlier column?
    const rubyCols = await ev(`(() => {
      const S = window.__reader.state; window.__reader.analyze();
      const d = S.frames[0].contentDocument, colOf = S.colOf, w = d.createTreeWalker(d.body, NodeFilter.SHOW_TEXT);
      let idx = 0, maxc = -1; const cols = [];
      for (let n = w.nextNode(); n; n = w.nextNode()) for (let j = 0; j < n.data.length; j++) {
        if (/\\s/.test(n.data[j])) continue;
        if (colOf[idx] < maxc && n.parentElement.tagName.toLowerCase() === 'rt' && cols.indexOf(maxc) < 0) cols.push(maxc);
        maxc = Math.max(maxc, colOf[idx]); idx++;
      }
      return cols;
    })()`);
    log('ruby-at-column-start columns', J(rubyCols));
    v.rubyAtColumnStart = rubyCols;
    if (rubyCols.length) {
      const k = Math.floor(rubyCols[0] / 2);
      for (const kk of [k - 1, k]) if (kk >= 0) { await ev(`window.__reader.goSpread(${kk})`); await shot(`${label}-${name}-ruby-col${rubyCols[0]}-spread${kk}.png`); }
    }
  }
  if (name === 'B-vertical-2col') {
    const fig = t.indexOf('【第３１段】');
    const k = await ev(`window.__reader.goToChar(${fig})`); await new Promise(r => setTimeout(r, 2000)); await shot(`${label}-${name}-figure-spread${k}.png`);
  }
  await ev('window.__reader.goSpread(0)'); await new Promise(r => setTimeout(r, 2000));
  await shot(`${label}-${name}-spread0.png`);
  const res = { name, mode, timings: opened.timings, verify: v, footnoteHit: hit,
    frames: frames.map(f => ({ title: f.title, writingMode: f.writingMode, fontFaces: f.fontFaces })) };
  report.cases.push(res);
  log('result', name, J(res));
}
// Reading location across a settings change (B, vertical two columns)
{
  log('location test');
  await ev(`window.__reader.open({ src: '/book/zh.xhtml', mode: 'B', settings: ${J(base)} })`);
  const an = await ev('(() => { const a = window.__reader.analyze(); delete a.text; return a; })()');
  const k0 = Math.min(5, an.spreads - 1); await ev(`window.__reader.goSpread(${k0})`);
  const loc = await ev('window.__reader.state.colOf.indexOf(' + (k0 * 2) + ')'); const steps = [];
  for (const [lab, patch] of [['fontSize 20→26', { fontSize: 26 }], ['back to defaults', {}]]) {
    const ns = Object.assign({}, base, patch);
    await ev(`window.__reader.relayout(${J(ns)})`);
    await ev('(() => { window.__reader.analyze(); return 1; })()');
    const k = await ev(`window.__reader.goToChar(${loc})`);
    const v = await ev(`window.__reader.charVisible(${loc})`);
    steps.push({ change: lab, spread: k, locVisible: v });
    log('location step', lab, k, v);
  }
  report.location = { startSpread: k0, loc, steps };
}
fs.writeFileSync(path.join(outDir, `${label}-report.json`), JSON.stringify(report, null, 2));
log('done');
ws.close();
