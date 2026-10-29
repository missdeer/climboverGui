#!/bin/bash
set -euo pipefail
GUI_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTPUT="$GUI_DIR/build/artwork"
mkdir -p "$OUTPUT" "$GUI_DIR/build/module-cache"
xcrun swiftc -module-cache-path "$GUI_DIR/build/module-cache" \
    "$GUI_DIR/Sources/ClimbOver/BrandArtwork.swift" "$GUI_DIR/Tools/RenderIcons.swift" -o "$GUI_DIR/build/RenderIcons"
"$GUI_DIR/build/RenderIcons" "$OUTPUT"
/usr/bin/iconutil --convert icns "$OUTPUT/AppIcon.iconset" --output "$OUTPUT/AppIcon.icns"
mkdir -p "$GUI_DIR/Assets"
cp "$OUTPUT/AppIcon.icns" "$GUI_DIR/Assets/AppIcon.icns"
cp "$OUTPUT/AppIcon.iconset/icon_512x512@2x.png" "$GUI_DIR/Assets/AppIcon.png"
cp "$OUTPUT/icon-preview.png" "$GUI_DIR/Assets/icon-preview.png"
