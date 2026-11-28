#!/bin/bash
# Makes the runtime's package (ios/Vendor/oneechan-runtime/build/embedded) self-contained for the app's build
# (.github/workflows/ios-jvm.yml): the prelinked static VM of each SDK is copied in, the link flags point at the
# copies (relative to the app project's folder, ios/), and bookmania-jvm.xcconfig turns the app's VM code on.
set -euo pipefail
R="$GITHUB_WORKSPACE/ios/Vendor/oneechan-runtime"
OUT="$R/build/embedded"
for p in iphoneos iphonesimulator; do
  mkdir -p "$OUT/lib/$p"
  cp "$R/jvm-ios/work/openj9-ios/$p/prelinked/libopenj9.a" "$OUT/lib/$p/"
done
sed -E -i '' 's#-force_load [^ ]*/openj9-ios/(iphoneos|iphonesimulator)/prelinked/libopenj9\.a#-force_load $(SRCROOT)/Vendor/oneechan-runtime/build/embedded/lib/\1/libopenj9.a#' "$OUT/jvm.xcconfig"
grep -q 'build/embedded/lib/iphoneos/libopenj9.a' "$OUT/jvm.xcconfig"
grep -q 'build/embedded/lib/iphonesimulator/libopenj9.a' "$OUT/jvm.xcconfig"
cat > "$OUT/bookmania-jvm.xcconfig" <<'XC'
// Written by .github/scripts/ios-jvm-prepare.sh: the app is built with the embedded Java VM.
BM_JVM_DEFINITIONS = BM_HAS_JVM=1
DEAD_CODE_STRIPPING = NO
XC
cat "$OUT/jvm.xcconfig"
du -sh "$OUT"/*
