#!/bin/bash
# Build locally; never install, replace, or launch an application automatically.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
REVISION=$(cat "$ROOT/native/upstream-revision")
SOURCE="$ROOT/.build/SwiftBar"
[[ $(uname -s) == Darwin ]] || { echo 'macOS and full Xcode are required' >&2; exit 1; }
mkdir -p "$ROOT/.build"
if [[ ! -e $SOURCE ]]; then
  git init "$SOURCE"
  git -C "$SOURCE" remote add origin https://github.com/swiftbar/SwiftBar.git
  git -C "$SOURCE" fetch --depth 1 origin "$REVISION"
  git -C "$SOURCE" checkout --detach FETCH_HEAD
fi
[[ $(git -C "$SOURCE" rev-parse HEAD) == "$REVISION" ]] || {
  echo 'Existing build checkout is at a different revision; use a fresh project checkout.' >&2; exit 1;
}
if ! git -C "$SOURCE" apply --reverse --check "$ROOT/native/swiftbar.patch" 2>/dev/null; then
  git -C "$SOURCE" apply --check "$ROOT/native/swiftbar.patch"
  git -C "$SOURCE" apply "$ROOT/native/swiftbar.patch"
fi
xcodebuild -project "$SOURCE/SwiftBar.xcodeproj" -scheme SwiftBar \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath "$ROOT/.build/DerivedData" -packageAuthorizationProvider netrc \
  CODE_SIGNING_ALLOWED=NO test
APP="$ROOT/.build/DerivedData/Build/Products/Debug/SwiftBar.app"
rm -rf "$APP/Contents/PlugIns/SwiftBarTests.xctest"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf '\nBuilt and tested: %s\nAd-hoc signed for local use, not notarized for redistribution.\n' "$APP"
