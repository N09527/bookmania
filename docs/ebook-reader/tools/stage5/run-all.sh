#!/bin/bash
# Stage 5 checks on the emulator, in order (later steps use positions saved by earlier ones).
# Usage: ADB=/path/to/adb ./run-all.sh [first step number]
#        STEPS="3 5 7-40" ./run-all.sh   (only these steps; numbers as printed by a full run)
# The ids are the test books on the emulator used for the stage 5 report (python3 -I check_stage5.py ids).
set -u
cd "$(dirname "$0")"
from=${1:-1}
n=0
wanted() {
  [ -z "${STEPS:-}" ] && { [ "$1" -ge "$from" ]; return; }
  for w in $STEPS; do
    case $w in
      *-*) [ "$1" -ge "${w%-*}" ] && [ "$1" -le "${w#*-}" ] && return 0 ;;
      *) [ "$1" -eq "$w" ] && return 0 ;;
    esac
  done
  return 1
}
run() {
  n=$((n + 1))
  wanted "$n" || return
  echo "=== $n: $* ($(date +%H:%M:%S))"
  timeout 3600 python3 -I check_stage5.py "$@" 2>&1
  echo "=== $n done ($(date +%H:%M:%S))"
}
# Reading position: close and reopen, per format and layout
run restore 14 16 epub-vertical --pages 12
run restore 13 15 azw3-vertical --pages 12
run restore 3 1 mobi-joint-vertical --pages 12
run restore 8 10 epub-horizontal --pages 8
run restore 9 11 mobi6-horizontal --pages 8
run restore 7 9 azw3-horizontal --pages 8
run restore 14 16 epub-vertical-2col-landscape --columns landscape --landscape --pages 6
run restore 8 10 epub-horizontal-2col --columns on --pages 6
# Rotation and a settings change while reading
run rotate 14 16 epub-vertical --pages 5
run settings 8 10 epub-horizontal --pages 5
# Restore order: location, then text, then fraction
run fallback 14 16 epub-vertical
# Chapter list and Recents, incognito mode, read / unread from the chapter list
run chapter_list 14 16
run incognito 14 16
run parity 14 16 OEBPS/text/ch01.xhtml
# Table of contents (EPUB navigation document, MOBI 6 NCX index, AZW3) and the whole-book slider
run toc 14 16 epub-vertical 2
run toc 9 11 mobi6-horizontal 2
run toc 13 15 azw3-vertical 1
run slider 14 16 epub-vertical 0.25
run slider 8 10 epub-horizontal 0.25
run end 8 10 epub-horizontal
# Tap zones (existing reader settings), volume keys
for mode in 0 1 2 3 4 5; do run tapzones 14 16 epub-vertical "$mode" NONE; done
for inv in HORIZONTAL VERTICAL BOTH; do run tapzones 14 16 epub-vertical 1 "$inv"; done
run tapzones 8 10 epub-horizontal 0 NONE
run volume 14 16
# Text / image switch and the stored classification
run switch 4 5 epub-with-pictures images
run switch 8 10 epub-without-pictures no-images
run switch_back 14 16 epub-one-picture 12
run switch_comic 11 13
run classify 15 17
