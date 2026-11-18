#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/native
xcrun swiftc -O -target arm64-apple-macosx13.0 -parse-as-library -emit-module \
  -module-name DockpinCore -emit-module-path .build/native/DockpinCore.swiftmodule \
  Sources/DockpinCore/Layout.swift
xcrun swiftc -O -target arm64-apple-macosx13.0 -parse-as-library -emit-object \
  -module-name DockpinCore Sources/DockpinCore/Layout.swift -o .build/native/DockpinCore.o
