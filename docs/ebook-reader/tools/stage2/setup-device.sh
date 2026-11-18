#!/bin/bash
# Prepare the emulator for stage 2 checks: install the debug APK, skip onboarding,
# enable the existing "external local source" option and push the test books.
set -u
ADB=${ADB:-adb}
PKG=io.github.n09527.bookmania.debug
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HERE/out}
REPO=${REPO:-$(cd "$HERE/../../../.." && pwd)}
mkdir -p "$OUT/runs" "$OUT/shots"
F=$REPO/core/ebook/src/test/resources/fixtures
APK=$REPO/app/build/outputs/apk/bookmania/debug/app-bookmania-x86_64-debug.apk
step=${1:-all}
if [ "$step" = all ] || [ "$step" = install ]; then
  $ADB shell settings put global airplane_mode_on 1
  $ADB shell am broadcast -a android.intent.action.AIRPLANE_MODE --ez state true >/dev/null 2>&1
  echo "install: $(timeout 900 $ADB install -r "$APK" 2>&1 | tail -1)"
fi
if [ "$step" = all ] || [ "$step" = prefs ]; then
  cat > $OUT/prefs.xml <<XML
<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<map>
    <boolean name="__APP_STATE_onboarding_complete" value="true" />
    <boolean name="pref_external_local_source" value="true" />
</map>
XML
  $ADB shell am force-stop $PKG
  $ADB push $OUT/prefs.xml /data/local/tmp/prefs.xml >/dev/null
  $ADB shell "run-as $PKG mkdir -p shared_prefs; run-as $PKG cp /data/local/tmp/prefs.xml shared_prefs/${PKG}_preferences.xml; run-as $PKG ls shared_prefs"
fi
if [ "$step" = all ] || [ "$step" = books ]; then
  L=/sdcard/Android/data/$PKG/files/local
  put() { $ADB shell mkdir -p "'$L/$1'" && $ADB push "$2" "$L/$1/" >/dev/null && echo "pushed $1/$(basename "$2")"; }
  put "直排測試書 EPUB" $F/zh-vertical.epub
  put "橫排測試書 EPUB" $F/zh-horizontal.epub
  put "縦書き EPUB" $F/ja-vertical.epub
  put "直排測試書 AZW3" $F/zh-vertical.azw3
  put "橫排測試書 AZW3" $F/zh-horizontal.azw3
  put "橫排測試書 MOBI6" $F/zh-horizontal-mobi6.mobi
  put "合併式 MOBI" $F/zh-vertical-joint.mobi
  put "圖文 EPUB" $F/text-with-images.epub
  put "圖文 MOBI6" $F/text-with-images-mobi6.mobi
  put "漫畫 固定版面 EPUB" $F/comic-fixed.epub
  put "漫畫 流動版面 EPUB" $F/comic-reflowable.epub
  put "漫畫 CBZ" $OUT/comic-pages.cbz
  put "DRM 測試" $F/drm-adept.epub
  put "DRM 測試" $F/drm-flagged.mobi
  put "損毀檔" $F/corrupt-truncated.epub
  put "損毀檔" $F/not-an-ebook.epub
  put "EPUB2 NCX" $F/epub2-ncx.epub
  $ADB shell "ls -R '$L'" | head -60
fi
