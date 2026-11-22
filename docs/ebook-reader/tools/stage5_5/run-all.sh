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

# work 8 (horizontal EPUB) gets two more files: an EPUB whose pages do not repeat (make_varied_epub.py; the
# test book repeats the same sentences, so its spreads look almost alike in landscape) and a picture chapter
run add_chapter 8 /sdcard/Download/zh-varied.epub zh-varied.epub
run add_chapter 8 "$CBZ" zh-horizontal-vol3-pictures.cbz
# text reader: horizontal EPUB (left to right), vertical EPUB (right to left)
run text 8 10 none t-none
run text 8 10 slide t-slide-ltr
run text 8 10 curl t-curl-ltr
run text 8 10 curl t-curl-ltr-back --back
# the second animated turn of a reading session (each copy of the page must be the page on the screen)
run text 8 10 curl t-curl-ltr-second --warm
run text 8 10 slide t-slide-ltr-second --warm
run text 14 16 slide t-slide-rtl
run text 14 16 curl t-curl-rtl
run text 14 16 curl t-curl-rtl-back --back
run text 8 0 curl t-curl-ltr-2col --columns on --landscape --file zh-varied.epub
run text 8 0 curl t-curl-ltr-2col-back --columns on --landscape --back --file zh-varied.epub
run text 14 16 curl t-curl-rtl-2col --columns on --landscape
run text 14 16 curl t-curl-rtl-2col-back --columns on --landscape --back
run text 8 0 slide t-slide-ltr-2col --columns on --landscape --file zh-varied.epub
# image reader: comic CBZ
run image 10 12 l2r i-curl-l2r
run image 10 12 l2r i-curl-l2r-back --back
run image 10 12 r2l i-curl-r2l
run image 10 12 r2l i-curl-r2l-back --back
run image 10 12 vertical i-curl-vertical
run image 10 12 vertical i-curl-vertical-back --back
run image 10 12 l2r i-curl-l2r-double --double
run image 10 12 webtoon i-webtoon
run image 10 12 l2r i-off-l2r --curl off
# chapter panel (work 8: two text EPUBs of the original set, the EPUB and the CBZ added above)
run chapters 8 10 19 0
run settings_ui 8 10
run rapid 8 10 curl r-curl
run rapid 8 10 slide r-slide
echo "RUN-ALL DONE $(date +%H:%M:%S)"
