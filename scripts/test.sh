#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/env.sh

if [[ -d "$testing_plugins" ]]; then
  swift test -Xswiftc -plugin-path -Xswiftc "$testing_plugins" "$@"
else
  swift test "$@"
fi
