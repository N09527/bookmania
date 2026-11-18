#!/bin/bash
# Open a chapter through the image reader entry point and report which activity ends up in front,
# what the screen says, and whether the app crashed. Usage: other-cases.sh <manga> <chapter> <label>
ADB=${ADB:-adb}; PKG=io.github.n09527.bookmania.debug
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HERE/out}
REPO=${REPO:-$(cd "$HERE/../../../.." && pwd)}
mkdir -p "$OUT/runs" "$OUT/shots"
manga=$1; chapter=$2; label=$3
$ADB shell am force-stop $PKG; sleep 2; $ADB logcat -c 2>/dev/null
$ADB shell am start -n $PKG/eu.kanade.tachiyomi.ui.reader.ReaderActivity --el manga $manga --el chapter $chapter >/dev/null 2>&1
sleep 45
for i in 1 2 3; do
  out=$(timeout 120 python3 -I $HERE/ui.py dump 2>/dev/null)
  echo "$out" | grep -q aerr_wait && { timeout 60 python3 -I $HERE/ui.py tap "id:aerr_wait" >/dev/null; sleep 10; continue; }
  break
done
act=$($ADB shell dumpsys activity activities 2>/dev/null | grep mResumedActivity | grep -o "[A-Za-z.]*Activity " | tail -1)
$ADB exec-out screencap -p > $OUT/shots/case-$label.png
echo "[$label] front: $act"
echo "$out" | grep -E "error_title|error_message|toolbar_title" | sed 's/^ */  /' | cut -c1-200
echo "  crashes: $($ADB logcat -d 2>/dev/null | grep -c 'FATAL EXCEPTION')"
$ADB logcat -d 2>/dev/null | grep -E "Toast|toast" | tail -2 | cut -c1-200
