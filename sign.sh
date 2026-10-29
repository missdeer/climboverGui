#!/bin/bash
set -euo pipefail
GUI_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP="$GUI_DIR/build/ClimbOver.app"
SIGNING_IDENTITY=${1:-'Developer ID Application: Fan Yang (Y73SBCN2CG)'}
for tool in sslocal coredns obfs-local; do
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none --options runtime \
        --identifier "com.dfordsoft.climbover.$tool" "$APP/Contents/Helpers/$tool"
done
codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none --options runtime \
    --identifier com.dfordsoft.climbover.daemon "$APP/Contents/Helpers/ProxyControl"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none --options runtime \
    --identifier com.dfordsoft.climbover.gui "$APP"
codesign --verify --deep --strict "$APP"
codesign --verify --strict -R '=anchor apple generic and identifier "com.dfordsoft.climbover.gui" and certificate leaf[subject.OU] = "Y73SBCN2CG"' "$APP"
codesign --verify --strict -R '=anchor apple generic and identifier "com.dfordsoft.climbover.daemon" and certificate leaf[subject.OU] = "Y73SBCN2CG"' "$APP/Contents/Helpers/ProxyControl"
printf 'Signed and verified %s\n' "$APP"
