#!/bin/bash
# Boot wait -> airplane mode -> install probe -> launch -> devtools forward -> run cdp-fast.mjs
export PATH=/opt/android-sdk/platform-tools:$PATH
SP=/tmp/claude-0/-home-user/4fcda4e8-218e-5f43-8a17-9102d2b74ae4/scratchpad
log() { echo "$(date +%H:%M:%S) $*"; }
start=$(date +%s)
until [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do
  pgrep -f qemu-system >/dev/null || { log "EMULATOR DIED"; exit 3; }
  [ $(( $(date +%s) - start )) -gt 2400 ] && { log "BOOT TIMEOUT"; exit 4; }
  sleep 10
done
log "booted after $(( $(date +%s) - start ))s"
adb shell settings put global airplane_mode_on 1; adb shell am broadcast -a android.intent.action.AIRPLANE_MODE --ez state true >/dev/null 2>&1
log "airplane_mode_on=$(adb shell settings get global airplane_mode_on | tr -d '\r')"
adb shell dumpsys webviewupdate | grep -i "current webview package" | sed 's/^ */WEBVIEW /'
log "install: $(adb install -r $SP/probe/app/build/outputs/apk/debug/app-debug.apk 2>&1 | tail -1)"
adb shell wm size 2000x1200; adb shell wm density 320; adb shell settings put system accelerometer_rotation 0
adb shell am start -n dev.probe.webview/.ProbeActivity >/dev/null 2>&1
t=$(date +%s); S=""
until [ -n "$S" ] || [ $(( $(date +%s) - t )) -gt 600 ]; do S=$(adb shell cat /proc/net/unix 2>/dev/null | grep -a -o "webview_devtools_remote_[0-9]*" | head -1); sleep 5; done
[ -z "$S" ] && { log "NO DEVTOOLS SOCKET"; exit 5; }
adb forward tcp:9333 localabstract:$S >/dev/null; log "devtools $S"
t=$(date +%s)
until curl -s http://127.0.0.1:9333/json 2>/dev/null | grep -q "reader.html" || [ $(( $(date +%s) - t )) -gt 600 ]; do sleep 5; done
log "target ready"
cd $SP/proto && node cdp-fast.mjs 9333 $SP/proto/out-android api26-wv69 2>&1
log "cdp-fast exit=$?"
adb logcat -d | grep WVPROBE | grep -E "BLOCKED|NAV|DENIED" | tail -5
log "PIPELINE DONE"
