#!/bin/bash
export PATH=/opt/android-sdk/platform-tools:$PATH
SP=/tmp/claude-0/-home-user/4fcda4e8-218e-5f43-8a17-9102d2b74ae4/scratchpad
log() { echo "$(date +%H:%M:%S) $*"; }
# 1) blockNetworkLoads(true) together with the virtual-origin interceptor
adb shell am force-stop dev.probe.webview; adb logcat -c
adb shell am start -n dev.probe.webview/.ProbeActivity --ez blockNetwork true >/dev/null 2>&1
t=$(date +%s); S=""
until [ -n "$S" ] || [ $(( $(date +%s) - t )) -gt 600 ]; do S=$(adb shell cat /proc/net/unix 2>/dev/null | grep -a -o "webview_devtools_remote_[0-9]*" | tail -1); sleep 5; done
adb forward --remove-all; adb forward tcp:9334 localabstract:$S >/dev/null
t=$(date +%s); until curl -s http://127.0.0.1:9334/json 2>/dev/null | grep -q "appassets" || [ $(( $(date +%s) - t )) -gt 300 ]; do sleep 5; done
curl -s http://127.0.0.1:9334/json | python3 -I -c "import json,sys; [print('BLOCKNET target', t.get('url')) for t in json.load(sys.stdin)]"
cat > /tmp/claude-0/-home-user/4fcda4e8-218e-5f43-8a17-9102d2b74ae4/scratchpad/proto/cdp-eval.mjs <<'JS'
const [port, expr] = process.argv.slice(2);
const t = (await (await fetch(`http://127.0.0.1:${port}/json`)).json()).find(x => (x.url || '').includes('appassets'));
const ws = new WebSocket(t.webSocketDebuggerUrl); await new Promise(r => ws.onopen = r);
ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id === 1) { console.log(JSON.stringify(m.result && m.result.result ? m.result.result.value : m)); ws.close(); } };
ws.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: { expression: expr, awaitPromise: true, returnByValue: true } }));
JS
log "BLOCKNET shell: $(node $SP/proto/cdp-eval.mjs 9334 'JSON.stringify({ready: document.readyState, reader: typeof window.__reader})')"
log "BLOCKNET open: $(node $SP/proto/cdp-eval.mjs 9334 "window.__reader.open({ src: '/book/zh.xhtml', mode: 'B', settings: { vertical: true, columns: 1, gap: 40, fontSize: 20, lineHeight: 1.8, letterSpacing: 0, indent: 1, paraSpacing: 0.5, fontFamily: 'serif', margins: { top: 40, bottom: 40, left: 30, right: 30 } } }).then(o => JSON.stringify({ frames: o.frames, columns: o.columnCount, title: window.__reader.state.frames[0].contentDocument.title, bodyChars: window.__reader.state.frames[0].contentDocument.body ? window.__reader.state.frames[0].contentDocument.body.textContent.length : -1 }))")"
adb logcat -d | grep WVPROBE | tail -4 | sed 's/^/BLOCKNET log /'
# 2) Baseline Yokai APK (upstream config; airplane mode already on)
log "airplane_mode_on=$(adb shell settings get global airplane_mode_on | tr -d '\r')"
adb shell am force-stop dev.probe.webview
log "yokai install: $(adb install -r $SP/apk/baseline-x86_64-debugsigned.apk 2>&1 | tail -1)"
adb logcat -c
adb shell monkey -p eu.kanade.tachiyomi.yokai -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
t=$(date +%s)
until adb shell dumpsys activity activities 2>/dev/null | grep -q "mResumedActivity.*eu.kanade.tachiyomi.yokai" || [ $(( $(date +%s) - t )) -gt 900 ]; do sleep 10; done
log "yokai resumed after $(( $(date +%s) - t ))s: $(adb shell dumpsys activity activities | grep -m1 mResumedActivity | tr -s ' ')"
sleep 60
adb exec-out screencap -p > $SP/proto/out-android/yokai-baseline-launch.png
adb logcat -d | grep -E "FATAL EXCEPTION|AndroidRuntime: Process|ANR in eu.kanade" | head -5 | sed 's/^/YOKAI crash? /'
log "yokai pid=$(adb shell pidof eu.kanade.tachiyomi.yokai | tr -d '\r')"
log "FOLLOWUP DONE"
