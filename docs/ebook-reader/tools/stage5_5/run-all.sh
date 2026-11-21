#!/bin/bash
# Stage 5.5 checks on the emulator, one after another (see README.md). ./run-all.sh 5 starts at item 5;
# STEPS="1 3 7-9" ./run-all.sh runs the items listed. Results: out/results.jsonl.
cd "$(dirname "$0")" || exit 1
export OUT="${OUT:-$PWD/out}"
mkdir -p "$OUT"
PKG=${PKG:-io.github.n09527.bookmania.debug}
CBZ="/sdcard/Android/data/$PKG/files/local/漫畫 CBZ/comic-pages.cbz"
ADB=${ADB:-adb}

i=0
want() {
  local n=$1
  if [ -n "$STEPS" ]; then
    for s in $STEPS; do
      if [[ $s == *-* ]]; then [ "$n" -ge "${s%-*}" ] && [ "$n" -le "${s#*-}" ] && return 0
      else [ "$n" -eq "$s" ] && return 0; fi
    done
    return 1
  fi
  [ "$n" -ge "${START:-1}" ]
}
run() {
  i=$((i + 1))
  want $i || return 0
  echo "=== $i: $* ($(date +%H:%M:%S))"
  $ADB logcat -c
  timeout 1800 python3 -I check_pageturn.py "$@"
  echo "--- exit $? ($(date +%H:%M:%S))"
  $ADB logcat -d -b crash -b main 2>/dev/null | grep -E "FATAL EXCEPTION|ANR in|has died|Fatal signal" >> "$OUT/system-events.log" || true
}
START=${1:-1}

# text reader: horizontal EPUB (left to right), vertical EPUB (right to left)
run text 8 10 none t-none
run text 8 10 slide t-slide-ltr
run text 8 10 curl t-curl-ltr
run text 8 10 curl t-curl-ltr-back --back
run text 14 16 slide t-slide-rtl
run text 14 16 curl t-curl-rtl
run text 14 16 curl t-curl-rtl-back --back
run text 8 10 curl t-curl-ltr-2col --columns on --landscape
run text 14 16 curl t-curl-rtl-2col --columns on --landscape
run text 8 10 curl t-curl-ltr-2col-back --columns on --landscape --back
run text 8 10 slide t-slide-ltr-2col --columns on --landscape
# image reader: comic CBZ
run image 10 12 l2r i-curl-l2r
run image 10 12 r2l i-curl-r2l
run image 10 12 vertical i-curl-vertical
run image 10 12 l2r i-curl-l2r-back --back
run image 10 12 l2r i-curl-l2r-double --double
run image 10 12 webtoon i-webtoon
run image 10 12 l2r i-off-l2r --curl off
# chapter panel: work 8 gets a picture chapter as its third file
run add_chapter 8 "$CBZ" zh-horizontal-vol3-pictures.cbz
run chapters 8 10 18 0
run settings_ui 8 10
run rapid 8 10 curl r-curl
run rapid 8 10 slide r-slide
echo "RUN-ALL DONE $(date +%H:%M:%S)"
