import fs from 'node:fs'; import { spawnSync } from 'node:child_process';
const [port, outPrefix] = process.argv.slice(2);
const adb = '/opt/android-sdk/platform-tools/adb';
const t = (await (await fetch(`http://127.0.0.1:${port}/json`)).json()).find(x => (x.url || '').includes('reader.html'));
const ws = new WebSocket(t.webSocketDebuggerUrl); await new Promise(r => ws.onopen = r);
let id = 0; const pend = new Map();
ws.onmessage = e => { const m = JSON.parse(e.data); if (pend.has(m.id)) { pend.get(m.id)(m); pend.delete(m.id); } };
const ev = expr => new Promise(res => { const i = ++id; pend.set(i, m => res(m.result && m.result.result ? m.result.result.value : m)); ws.send(JSON.stringify({ id: i, method: 'Runtime.evaluate', params: { expression: expr, awaitPromise: true, returnByValue: true } })); });
const dialogVisible = () => { const r = spawnSync(adb, ['shell', 'dumpsys', 'window', 'windows'], { encoding: 'utf-8', maxBuffer: 16 << 20 }); return /Application Not Responding|isn't responding/.test(r.stdout || ''); };
const shot = name => {
  for (let tries = 0; tries < 5; tries++) {
    spawnSync(adb, ['shell', 'am', 'broadcast', '-a', 'android.intent.action.CLOSE_SYSTEM_DIALOGS']);
    if (dialogVisible()) spawnSync(adb, ['shell', 'input', 'tap', '627', '671']);
    spawnSync('sleep', ['4']);
    if (!dialogVisible()) break;
  }
  const r = spawnSync(adb, ['exec-out', 'screencap', '-p'], { maxBuffer: 64 << 20 });
  fs.writeFileSync(name, r.stdout); console.log('saved', name, 'dialog=', dialogVisible());
};
const base = { vertical: true, columns: 2, gap: 40, fontSize: 20, lineHeight: 1.8, letterSpacing: 0.05, indent: 1, paraSpacing: 0.5, fontFamily: '"ReaderImported", serif', margins: { top: 40, bottom: 40, left: 30, right: 30 } };
for (const [name, mode, s] of [['B-vertical-2col', 'B', base], ['A-vertical-2col-unsupported', 'A', base], ['H-horizontal-2col', 'H', Object.assign({}, base, { vertical: false })]]) {
  await ev(`window.__reader.open({ src: '/book/zh.xhtml', mode: ${JSON.stringify(mode)}, settings: ${JSON.stringify(s)} })`);
  await ev('window.__reader.goSpread(0)');
  shot(`${outPrefix}-${name}-spread0.png`);
}
ws.close();
