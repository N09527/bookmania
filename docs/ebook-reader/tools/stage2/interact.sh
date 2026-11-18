#!/bin/bash
# Links, page keys and rotation on the vertical EPUB (manga 14, chapter 16).
ADB=${ADB:-adb}; PKG=io.github.n09527.bookmania.debug
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HERE/out}
REPO=${REPO:-$(cd "$HERE/../../../.." && pwd)}
mkdir -p "$OUT/runs" "$OUT/shots"
U="timeout 120 python3 -I $HERE/ui.py"
cdp() { node $HERE/cdp.mjs 9333 "$1" 2>/dev/null; }
status() { cdp 'JSON.stringify([((document.querySelector("#stage iframe")||{}).src||"").replace(/^.*\/book\//,""), window.__reader.status()])'; }
waitready() { for k in $(seq 1 40); do status | grep -q '\\"ready\\":true' && return 0; sleep 2; done; return 1; }
$ADB shell am force-stop $PKG; sleep 2
$ADB shell am start -n $PKG/eu.kanade.tachiyomi.ui.reader.ReaderActivity --el manga 14 --el chapter 16 >/dev/null 2>&1
for k in $(seq 1 60); do $ADB shell dumpsys activity activities | grep mResumedActivity | grep -q EbookReaderActivity && break; sleep 3; done
pid=$($ADB shell pidof $PKG | tr -d '\r'); $ADB forward --remove-all; $ADB forward tcp:9333 localabstract:webview_devtools_remote_$pid >/dev/null
waitready; echo "start: $(status)"
# --- page keys
$ADB shell input keyevent 93; sleep 3; echo "after PAGE_DOWN: $(status)"
$ADB shell input keyevent 92; sleep 3; echo "after PAGE_UP: $(status)"
$ADB shell input keyevent 21; sleep 3; echo "after DPAD_LEFT (vertical: next): $(status)"
$ADB shell input keyevent 25; sleep 3; echo "after VOLUME_DOWN (option off by default): $(status)"
# --- links on the last page of chapter 1
cdp 'window.__reader.goPage(1000); "ok"' >/dev/null; sleep 2; echo "last page of ch01: $(status)"
links=$(cdp "$(cat $HERE/links.js)"); echo "links: $links"
ext=$(python3 -I -c 'import json,sys; l=json.loads(json.loads(sys.argv[1])); e=[a for a in l if a["href"].startswith("http")]; print(e[0]["x"], e[0]["y"]) if e else print("")' "$links")
if [ -n "$ext" ]; then
  $ADB shell input tap $ext; sleep 6
  $U dump | grep -E "Open this link|example.com|Open in browser|Cancel" | cut -c1-160
  $ADB exec-out screencap -p > $OUT/shots/link-external-dialog.png
  $U tap "Cancel" >/dev/null; sleep 3
fi
links=$(cdp "$(cat $HERE/links.js)")
cross=$(python3 -I -c 'import json,sys; l=json.loads(json.loads(sys.argv[1])); e=[a for a in l if "ch02" in a["href"]]; print(e[0]["x"], e[0]["y"]) if e else print("")' "$links")
if [ -n "$cross" ]; then $ADB shell input tap $cross; sleep 4; waitready; echo "after cross-chapter link: $(status)"; fi
$ADB exec-out screencap -p > $OUT/shots/link-cross-chapter.png
# --- rotation keeps the text position
before=$(cdp "$(cat $HERE/probe.js)")
$ADB shell settings put system accelerometer_rotation 0; $ADB shell settings put system user_rotation 1; sleep 12; waitready
after=$(cdp "$(cat $HERE/probe.js)")
$ADB exec-out screencap -p > $OUT/shots/rotated-landscape.png
python3 -I - "$before" "$after" <<'PY'
import json, sys
b = json.loads(json.loads(sys.argv[1])); a = json.loads(json.loads(sys.argv[2]))
ob = b['all'].find(b['vis']); oa = a['all'].find(a['vis'])
print('rotation: before page', b['st']['page'] + 1, '/', b['st']['pages'], '-> after page', a['st']['page'] + 1, '/', a['st']['pages'])
print('  first visible char index before:', ob, '| visible range after:', oa, '..', oa + len(a['vis']) - 1,
      '| kept:', ob >= 0 and oa >= 0 and oa <= ob < oa + len(a['vis']))
PY
$ADB shell settings put system user_rotation 0; sleep 10
