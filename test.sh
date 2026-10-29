#!/bin/bash
set -euo pipefail
GUI_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$GUI_DIR/build/module-cache"
bash "$GUI_DIR/generate-settings.sh"
xcrun swiftc -swift-version 5 -module-cache-path "$GUI_DIR/build/module-cache" -import-objc-header "$GUI_DIR/Sources/Shared/ProcessInfo.h" "$GUI_DIR/build/BuildSettings.swift" "$GUI_DIR"/Sources/Shared/*.swift "$GUI_DIR"/Tests/*.swift -o "$GUI_DIR/build/ControlTests"
"$GUI_DIR/build/ControlTests"
