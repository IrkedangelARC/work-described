#!/bin/zsh
# Run the ScopeKit golden tests. No app launch, no interface, no microphone.
set -e
cd "${0:A:h}/../ScopeKit"
swift test "$@"
