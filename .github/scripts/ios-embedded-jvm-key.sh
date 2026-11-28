#!/bin/bash
# The cache key of the embedded JVM's package, which .github/workflows/ios-jvm.yml builds and saves and the app's
# workflows restore: the runtime's commit (the submodule's), the Xcode version and a build number. Keep it the same as
# the key step of ios-jvm.yml (BUILD_VERSION there).
set -euo pipefail
BUILD_VERSION=1
runtime=$(git ls-tree HEAD ios/Vendor/oneechan-runtime | awk '{print $3}')
xcode=$(xcodebuild -version | head -1 | tr -d ' ')
echo "ios-jvm-${BUILD_VERSION}-${runtime}-${xcode}"
