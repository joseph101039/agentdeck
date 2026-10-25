#!/bin/sh
# Runs the test suite.
#
# With Command Line Tools only (no Xcode), Testing.framework lives outside
# SwiftPM's default search path and its _Testing_Foundation cross-import
# overlay ships without a Swift module — hence the explicit flags. With a
# full Xcode toolchain (e.g. CI runners), plain `swift test` works.
set -e
FRAMEWORKS=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
if [ -d "$FRAMEWORKS/Testing.framework" ] && ! xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
    # Newer Command Line Tools split lib_TestingInterop.dylib out of the
    # framework; without its directory on the rpath every test binary dies
    # at load time before a single test runs.
    INTEROP=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
    if [ -f "$INTEROP/lib_TestingInterop.dylib" ]; then
        set -- -Xlinker -rpath -Xlinker "$INTEROP" "$@"
    fi
    exec swift test \
      -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
      -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
      -Xlinker -F -Xlinker "$FRAMEWORKS" \
      -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
      "$@"
fi
exec swift test "$@"
