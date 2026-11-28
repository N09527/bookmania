#!/bin/bash
# The cross-platform sync test: Android's sync code (Kotlin, OkHttp) and the iOS version's (Swift, URLSession) take
# turns on one real WebDAV server (WsgiDAV, https://github.com/mar10/wsgidav, MIT; test only, not shipped).
#   1. Kotlin writes a library, progress, settings and two book files (LiveWebDavTest, android-write).
#   2. Swift reads and checks them, downloads the files, reads further and sends its progress (SyncLiveTests, ios-check).
#   3. Kotlin checks the iOS progress (android-check).
# Needs: wsgidav and cheroot (pip), the Android build (offline is fine) and Swift. Run from the repository root.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
mkdir -p "$work/root"
cp "$here/wsgidav.yaml" "$work/"
(cd "$work" && exec "${WSGIDAV:-wsgidav}" --config=wsgidav.yaml) > "$work/server.log" 2>&1 &
server=$!
trap 'kill $server 2>/dev/null; rm -rf "$work"' EXIT
for _ in $(seq 1 50); do
  curl -s -o /dev/null http://127.0.0.1:8765/ && break
  sleep 0.2
done
export BOOKMANIA_WEBDAV_URL=http://127.0.0.1:8765/dav/ BOOKMANIA_WEBDAV_USER=reader BOOKMANIA_WEBDAV_PASSWORD=secret

BOOKMANIA_WEBDAV_ROLE=android-write ./gradlew --offline -q :core:sync:testDebugUnitTest --tests 'yokai.core.sync.LiveWebDavTest' --rerun
echo "1. Kotlin wrote:"; (cd "$work/root" && find . -type f | sort)
BOOKMANIA_WEBDAV_ROLE=ios-check swift test --package-path ios/BookmaniaCore --filter SyncLiveTests 2>&1 | grep -E "✔|✘|error|recorded" 
echo "2. On the server now:"; (cd "$work/root" && find . -type f | sort)
BOOKMANIA_WEBDAV_ROLE=android-check ./gradlew --offline -q :core:sync:testDebugUnitTest --tests 'yokai.core.sync.LiveWebDavTest' --rerun
echo "3. Kotlin checked the iOS progress."
grep -o 'tests="[0-9]*" skipped="[0-9]*" failures="[0-9]*" errors="[0-9]*"' core/sync/build/test-results/testDebugUnitTest/TEST-yokai.core.sync.LiveWebDavTest.xml
