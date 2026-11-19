#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/compile-core.sh
xcrun swiftc -parse-as-library -I .build/native Sources/Dockpin/Platform.swift Sources/Dockpin/PointerBoundary.swift \
  Tests/Integration/PointerBoundaryChecks.swift .build/native/DockpinCore.o -o .build/native/PointerBoundaryChecks
.build/native/PointerBoundaryChecks "$@"
