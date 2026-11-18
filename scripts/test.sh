#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/compile-core.sh
xcrun swiftc -parse-as-library -I .build/native Tests/DockpinCoreTests/LayoutTests.swift \
  .build/native/DockpinCore.o -o .build/native/DockpinChecks
.build/native/DockpinChecks
