#!/bin/sh
# swift test on a Mac with only the Command Line Tools: they ship the Testing macro plugin, but the
# default build system does not pass its folder to the compiler. Extra arguments go to swift test.
cd "$(dirname "$0")" || exit 1
plugins="$(dirname "$(xcrun -f swift-frontend)")/../lib/swift/host/plugins/testing"
exec swift test -Xswiftc -plugin-path -Xswiftc "$plugins" "$@"
