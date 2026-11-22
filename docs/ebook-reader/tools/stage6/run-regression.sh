#!/bin/bash
# Stage 6: the automatic checks of stages 2 to 5.5 again, on the installed debug APK, one part after the
# other. Each part writes into its own stage's folder (out6/); this script logs the parts in out/parts.log.
#   ./run-regression.sh                 every part
#   ./run-regression.sh s5 s4pages      only the parts named
# Parts: warmup s55new s55 s5 s4checks s4pages s3 s2 (see README.md).
HERE=$(cd "$(dirname "$0")" && pwd); cd "$HERE"
TOOLS=$(cd "$HERE/.." && pwd)
export ADB=${ADB:-adb}
mkdir -p out
LOG="$HERE/out/parts.log"
parts=("$@")
[ ${#parts[@]} -eq 0 ] && parts=(warmup s55new s55 s5 s4checks s4pages s3 s2)

events() {  # crashes and "not responding" in the system log since the part started
  { $ADB logcat -d -b crash 2>/dev/null; $ADB logcat -d -b events 2>/dev/null | grep -E "am_anr|am_crash"; } >> "$HERE/out/$1-events.log"
  $ADB logcat -c 2>/dev/null
}

run_part() {
  local part=$1
  echo "=== $part start $(date +%H:%M:%S)" >> "$LOG"
  $ADB logcat -c 2>/dev/null
  case $part in
    warmup)
      (cd "$TOOLS/stage5" && OUT="$HERE/out/warmup" timeout 1800 python3 -I check_stage5.py warmup 8 10) ;;
    s55new)  # the user's decisions of the stage 5.5 report 6.1, and the settings check with the new default
      (cd "$TOOLS/stage5_5" && OUT="$TOOLS/stage5_5/out6" STEPS="30-36 27" ./run-all.sh) ;;
    s55)
      (cd "$TOOLS/stage5_5" && OUT="$TOOLS/stage5_5/out6" STEPS="1-26 28-29" ./run-all.sh) ;;
    s5)
      $ADB shell settings put global airplane_mode_on 1
      $ADB shell am broadcast -a android.intent.action.AIRPLANE_MODE --ez state true >/dev/null 2>&1
      (cd "$TOOLS/stage5" && OUT="$TOOLS/stage5/out6" ./run-all.sh) ;;
    s4checks)
      (cd "$TOOLS/stage4" && OUT="$TOOLS/stage4/out6" ./run-all.sh checks) ;;
    s4pages)
      (cd "$TOOLS/stage4" && OUT="$TOOLS/stage4/out6" ./run-all.sh pages) ;;
    s3)
      (cd "$TOOLS/stage3" && export OUT="$TOOLS/stage3/out6" && mkdir -p "$OUT" &&
        timeout 7200 python3 -I check_settings.py reset defaults global direction persist scopes &&
        timeout 3600 python3 -I check_settings.py vol2 8 18 &&
        timeout 7200 python3 -I check_settings.py reset_levels fonts toolbar rotate &&
        FONT_FILE="${FONT_FILE:-}" CDP_TIMEOUT_MS=120000 timeout 7200 python3 -I check_settings.py font_speed side_panel) ;;
    s2)  # formats that are not plain text books: DRM, damaged files, comic EPUBs and CBZ, NCX, pictures
      (cd "$TOOLS/stage2" && export OUT="$TOOLS/stage2/out6" && mkdir -p "$OUT" &&
        for c in "1 2 drm-flagged-mobi" "1 3 drm-adept-epub" "6 7 not-an-ebook" "6 8 corrupt-truncated" \
                 "11 13 comic-fixed-epub" "12 14 comic-reflowable-epub" "10 12 comic-cbz" "2 4 epub2-ncx" \
                 "5 6 text-with-images-mobi6" "4 5 text-with-images-epub"; do
          set -- $c; timeout 900 ./other-cases.sh "$1" "$2" "$3"
        done) ;;
    *) echo "unknown part $part" ;;
  esac
  local status=$?
  events "$part"
  echo "=== $part end $(date +%H:%M:%S) exit $status" >> "$LOG"
}

for p in "${parts[@]}"; do
  run_part "$p" > "$HERE/out/$p.log" 2>&1
done
echo "REGRESSION DONE $(date +%H:%M:%S)" >> "$LOG"
