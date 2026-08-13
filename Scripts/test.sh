#!/bin/zsh
# Run the test suite. Prefers a full Xcode install (everything just works);
# falls back to Command Line Tools with the flags CLT needs.
set -euo pipefail
cd "$(dirname "$0")/.."

for xcode in /Applications/Xcode.app /Applications/Xcode-beta.app; do
  if [[ -d $xcode/Contents/Developer ]]; then
    export DEVELOPER_DIR=$xcode/Contents/Developer
    exec swift test "$@"
  fi
done

# Command Line Tools fallback: CLT ships Testing.framework and its macros
# plugin outside the default search paths, and its macOS 27 beta SDK needs a
# SwiftUIMacros plugin CLT doesn't have (so pin the 26.5 SDK).
CLT=/Library/Developer/CommandLineTools
export SDKROOT=$CLT/SDKs/MacOSX26.5.sdk
exec swift test \
  -Xswiftc -plugin-path -Xswiftc "$CLT/usr/lib/swift/host/plugins/testing" \
  -Xlinker -rpath -Xlinker "$CLT/Library/Developer/Frameworks" \
  -Xlinker -rpath -Xlinker "$CLT/Library/Developer/usr/lib" \
  "$@"
