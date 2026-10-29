#!/bin/bash
set -euo pipefail
GUI_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$GUI_DIR/build"
/usr/bin/python3 - "$GUI_DIR/build/BuildSettings.swift" "$(dirname "$GUI_DIR")" "$(id -u)" "${CLIMBOVER_TEAM_ID:-Y73SBCN2CG}" <<'PY'
import json,pathlib,re,sys
output,root,uid,team=sys.argv[1:]
if not re.fullmatch('[A-Z0-9]{10}',team): raise SystemExit('Invalid signing team ID')
pathlib.Path(output).write_text('import Foundation\nenum BuildSettings {\n'
    + '    static let projectRoot = '+json.dumps(root,ensure_ascii=False)+'\n'
    + '    static let ownerUID: UInt32 = '+str(int(uid))+'\n'
    + '    static let teamID = '+json.dumps(team)+'\n}\n')
PY
