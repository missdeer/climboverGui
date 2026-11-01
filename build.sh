#!/bin/bash
set -euo pipefail
GUI_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$GUI_DIR")
OUTPUT="$GUI_DIR/build"
APP="$OUTPUT/ClimbOver.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons" "$OUTPUT/module-cache"
# install copies the targets of the source symlinks; the bundle carries real executables.
install -m 755 "$PROJECT_DIR/sslocal" "$APP/Contents/Helpers/sslocal"
install -m 755 "$PROJECT_DIR/obfs-local" "$APP/Contents/Helpers/obfs-local"
install -m 755 "$PROJECT_DIR/coredns/coredns" "$APP/Contents/Helpers/coredns"
bash "$GUI_DIR/generate-settings.sh"
xcrun swift -module-cache-path "$GUI_DIR/build/module-cache" "$GUI_DIR/Tools/EmbedTemplates.swift" "$GUI_DIR/Templates" "$GUI_DIR/build/ConfigurationTemplates.swift"
export CLANG_MODULE_CACHE_PATH="$OUTPUT/module-cache"
export SWIFT_MODULECACHE_PATH="$OUTPUT/module-cache"
ARCH=$(uname -m)
SWIFT_FLAGS=(-O -swift-version 5 -target "$ARCH-apple-macosx13.0" -module-cache-path "$OUTPUT/module-cache" -import-objc-header "$GUI_DIR/Sources/Shared/ProcessInfo.h")
xcrun swiftc "${SWIFT_FLAGS[@]}" "$OUTPUT/BuildSettings.swift" "$OUTPUT/ConfigurationTemplates.swift" "$GUI_DIR"/Sources/Shared/*.swift "$GUI_DIR"/Sources/ProxyControl/*.swift -o "$APP/Contents/Helpers/ProxyControl"
xcrun swiftc "${SWIFT_FLAGS[@]}" -parse-as-library "$OUTPUT/BuildSettings.swift" "$OUTPUT/ConfigurationTemplates.swift" "$GUI_DIR"/Sources/Shared/*.swift "$GUI_DIR"/Sources/ClimbOver/*.swift -o "$APP/Contents/MacOS/ClimbOver"
cp "$GUI_DIR/Service/com.dfordsoft.climbover.daemon.plist" "$APP/Contents/Library/LaunchDaemons/"
cp "$GUI_DIR/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c 'Clear dict' "$APP/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.dfordsoft.climbover.gui' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleName string ClimbOver' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string ClimbOver' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleShortVersionString string 0.1.0' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleVersion string 1' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSMinimumSystemVersion string 13.0' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity dict' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity:NSAllowsArbitraryLoads bool true' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :NSHighResolutionCapable bool true' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :ClimbOverRoot string $PROJECT_DIR" "$APP/Contents/Info.plist"
for tool in sslocal coredns obfs-local; do
    codesign --force --sign - --identifier "com.dfordsoft.climbover.$tool" "$APP/Contents/Helpers/$tool"
done
codesign --force --sign - --identifier com.dfordsoft.climbover.daemon "$APP/Contents/Helpers/ProxyControl"
codesign --force --sign - "$APP"
printf 'Built %s\n' "$APP"
