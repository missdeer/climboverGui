#!/bin/bash
set -euo pipefail
GUI_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SOURCE="$GUI_DIR/build/ClimbOver.app"
TARGET=/Applications/ClimbOver.app
if [ "$EUID" -ne 0 ]; then echo 'Run: sudo bash install.sh' >&2; exit 1; fi
codesign --verify --deep --strict "$SOURCE"
codesign --verify --strict -R '=anchor apple generic and identifier "com.dfordsoft.climbover.gui" and certificate leaf[subject.OU] = "Y73SBCN2CG"' "$SOURCE"
if [ -d "$TARGET" ]; then
    if launchctl print system/com.dfordsoft.climbover.daemon >/dev/null 2>&1; then
        echo 'Use More → Disable Background Service in the installed app before updating.' >&2; exit 1
    fi
    if [ -e /var/run/climbover-gui/state.json ]; then echo 'Stop the existing proxy before updating.' >&2; exit 1; fi
fi
STAGING=/Applications/ClimbOver.installing.app
BACKUP="/Applications/ClimbOver.previous.$(/bin/date +%Y%m%d-%H%M%S).app"
if [ -e "$STAGING" ]; then echo 'Staging app already exists; inspect it before retrying.' >&2; exit 1; fi
if [ -e "$BACKUP" ]; then echo 'App backup already exists; retry after a second.' >&2; exit 1; fi
ditto "$SOURCE" "$STAGING"
chown -R root:wheel "$STAGING"
chmod -R go-w "$STAGING"
codesign --verify --deep --strict "$STAGING"
if [ -d "$TARGET" ]; then
    mv "$TARGET" "$BACKUP"
fi
mv "$STAGING" "$TARGET"
printf 'Installed %s\n' "$TARGET"
