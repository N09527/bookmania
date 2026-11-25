#!/bin/bash
# Checks the app built by ios-build.sh and packages it as an unsigned IPA (Payload/Bookmania.app in a zip) named
# $1, in ios/dist/. The app must contain the reader shell, the licences and both languages, and carry the version of
# app/build.gradle.kts. The bundle facts and the IPA's size and SHA-256 are printed as notices.
set -euo pipefail

name="$1"
app=ios/build/Build/Products/Release-iphoneos/Bookmania.app
missing=""
for f in Bookmania Info.plist ebook/reader.html ebook/reader.js LICENSE NOTICE-foliate-js.txt Assets.car \
         zh-Hant.lproj/Localizable.strings en.lproj/Localizable.strings; do
  [ -e "$app/$f" ] || missing="$missing $f"
done
if [ -n "$missing" ]; then
  echo "::error title=App bundle::missing:${missing}"
  exit 1
fi

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Info.plist")
minos=$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$app/Info.plist")
archs=$(lipo -archs "$app/Bookmania")
files=$(cd "$app" && find . -type f | wc -l | tr -d ' ')
echo "::notice title=App bundle::version ${version} (${build}), minimum iOS ${minos}, ${archs}; ${files} files"
expected_version=$(sed -n 's/^val _versionName = "\(.*\)"$/\1/p' app/build.gradle.kts)
expected_build=$(sed -n 's/^ *versionCode = \([0-9]*\)$/\1/p' app/build.gradle.kts)
if [ "$version" != "$expected_version" ] || [ "$build" != "$expected_build" ]; then
  echo "::error title=App bundle::version ${version} (${build}), but app/build.gradle.kts has ${expected_version} (${expected_build})"
  exit 1
fi

rm -rf ios/dist
mkdir -p ios/dist/Payload
cp -R "$app" ios/dist/Payload/
(cd ios/dist && zip -qry "$name" Payload)
rm -rf ios/dist/Payload
size=$(stat -f %z "ios/dist/$name")
sum=$(shasum -a 256 "ios/dist/$name" | cut -d' ' -f1)
echo "::notice title=IPA::${name} ${size} bytes, SHA-256 ${sum}"
