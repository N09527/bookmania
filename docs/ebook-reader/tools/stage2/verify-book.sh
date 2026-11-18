#!/bin/bash
# Open a chapter through the image reader entry point (exercises the hand-off), then page to the
# end by tapping, recording what is fully visible on every page. Usage: verify-book.sh <manga> <chapter> <tapX> <label>
ADB=${ADB:-adb}; PKG=io.github.n09527.bookmania.debug
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HERE/out}
REPO=${REPO:-$(cd "$HERE/../../../.." && pwd)}
manga=$1; chapter=$2; tapx=$3; label=$4; out=$OUT/runs/$label.jsonl
mkdir -p $OUT/runs; : > $out
$ADB shell am force-stop $PKG; sleep 2
$ADB shell am start -n $PKG/eu.kanade.tachiyomi.ui.reader.ReaderActivity --el manga $manga --el chapter $chapter >/dev/null 2>&1
t=$(date +%s); act=""
while [ $(( $(date +%s) - t )) -lt 180 ]; do
  act=$($ADB shell dumpsys activity activities 2>/dev/null | grep mResumedActivity | grep -o "[A-Za-z.]*Activity " | tail -1)
  case "$act" in *EbookReaderActivity*) break;; esac
  sleep 3
done
echo "activity: $act"
case "$act" in *EbookReaderActivity*) ;; *) exit 3;; esac
pid=$($ADB shell pidof $PKG | tr -d '\r')
$ADB forward --remove-all >/dev/null 2>&1; $ADB forward tcp:9333 localabstract:webview_devtools_remote_$pid >/dev/null
probe=$(cat $HERE/probe.js)
t=$(date +%s)
until node $HERE/cdp.mjs 9333 "JSON.stringify(window.__reader && window.__reader.status())" 2>/dev/null | grep -q '\\"ready\\":true'; do
  [ $(( $(date +%s) - t )) -gt 180 ] && { echo "not ready"; exit 4; }; sleep 3
done
prev=""; same=0
for i in $(seq 1 300); do
  line=$(node $HERE/cdp.mjs 9333 "$probe" 2>/dev/null)
  echo "$line" >> $out
  key=$(python3 -I -c 'import json,sys; v=json.loads(json.loads(sys.argv[1])); print(v["src"], v["st"]["page"], v["st"]["pages"], v["st"]["ready"])' "$line" 2>/dev/null)
  if [ "$key" = "$prev" ]; then same=$((same+1)); else same=0; fi
  [ $same -ge 2 ] && break
  prev="$key"
  $ADB shell input tap $tapx 900
  sleep 1.2
  # wait while a new document is being laid out
  for k in 1 2 3 4 5 6 7 8 9 10; do node $HERE/cdp.mjs 9333 "JSON.stringify(window.__reader.status())" 2>/dev/null | grep -q '\\"ready\\":true' && break; sleep 1; done
done
echo "steps: $i, log: $out"
