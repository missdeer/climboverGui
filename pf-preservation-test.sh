#!/bin/bash
# Hold an independent PF reference/ruleset while the app starts, rolls back and stops.
set -euo pipefail
umask 077
GUI_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$GUI_DIR")
HELPER="$GUI_DIR/build/ClimbOver.app/Contents/Helpers/ProxyControl"
if [ "$EUID" -ne 0 ]; then echo 'Run with sudo.' >&2; exit 1; fi
if [ -e /var/run/climbover-gui/state.json ] || [ -e /var/run/climbover-pf.token ]; then echo 'Stop existing proxies first.' >&2; exit 1; fi
TEST_DIR=$(/usr/bin/mktemp -d "$GUI_DIR/build/pf-preservation.XXXXXX")
FOREIGN_ANCHOR="com.apple/$(/usr/bin/basename "$TEST_DIR")"
FOREIGN_TOKEN=''
status() { /sbin/pfctl -s info | /usr/bin/awk '/^Status:/ {print $2; exit}'; }
tokens() { /sbin/pfctl -s References | /usr/bin/awk '$1 ~ /^[0-9]+$/ {print $(NF-3)}' | /usr/bin/sort; }
BEFORE_STATUS=$(status)
BEFORE_TOKENS=$(tokens)
/sbin/pfctl -sr > "$TEST_DIR/main.rules"
/sbin/pfctl -sn > "$TEST_DIR/main.nat"
cleanup() {
    "$HELPER" stop || true
    for kind in nat rules Tables; do /sbin/pfctl -a "$FOREIGN_ANCHOR" -F "$kind" >/dev/null 2>&1 || true; done
    if [ -n "$FOREIGN_TOKEN" ]; then /sbin/pfctl -X "$FOREIGN_TOKEN" || true; fi
    /bin/rm -rf "$TEST_DIR"
}
trap cleanup EXIT
/bin/cat > "$TEST_DIR/foreign.conf" <<'PF'
table <keep_table> persist { 192.0.2.123 }
pass out on lo0 inet proto tcp from 192.0.2.123 to 198.51.100.234 port 9 no state label "climbover-preservation-test"
PF
/sbin/pfctl -a "$FOREIGN_ANCHOR" -f "$TEST_DIR/foreign.conf" >/dev/null 2>&1
ENABLE_OUTPUT=$(/sbin/pfctl -E 2>&1)
FOREIGN_TOKEN=$(printf '%s\n' "$ENABLE_OUTPUT" | /usr/bin/awk '/Token/ {print $3}')
if [ -z "$FOREIGN_TOKEN" ]; then echo 'No test PF reference token.' >&2; exit 1; fi
/sbin/pfctl -a "$FOREIGN_ANCHOR" -sr > "$TEST_DIR/foreign.rules"
/sbin/pfctl -a "$FOREIGN_ANCHOR" -t keep_table -T show > "$TEST_DIR/foreign.table"
FOREIGN_TOKENS=$(tokens)
assert_preserved() {
    if [ "$(status)" != Enabled ] || [ "$FOREIGN_TOKENS" != "$(tokens)" ]; then echo 'Independent PF reference/state changed.' >&2; exit 1; fi
    /sbin/pfctl -sr > "$TEST_DIR/after.rules"
    /sbin/pfctl -sn > "$TEST_DIR/after.nat"
    /sbin/pfctl -a "$FOREIGN_ANCHOR" -sr > "$TEST_DIR/after.foreign.rules"
    /sbin/pfctl -a "$FOREIGN_ANCHOR" -t keep_table -T show > "$TEST_DIR/after.foreign.table"
    for pair in 'main.rules after.rules' 'main.nat after.nat' 'foreign.rules after.foreign.rules' 'foreign.table after.foreign.table'; do
        read -r before after <<< "$pair"
        /usr/bin/cmp "$TEST_DIR/$before" "$TEST_DIR/$after"
    done
}
# Also exercise Stop after its journal is absent but its reserved anchor has stale contents.
/sbin/pfctl -a com.apple/climbovergui -f "$TEST_DIR/foreign.conf" >/dev/null 2>&1
"$HELPER" stop
assert_preserved
echo 'PASS: idempotent Stop removes stale own rules without affecting independent PF configuration'
/bin/bash "$GUI_DIR/switch-smoke-test.sh" "${1:-huacloud/us-adv-iepl-3.conf}" "${2:-Wi-Fi}"
assert_preserved
echo 'PASS: switching/rollback/Stop preserve main rules, independent rules/table and PF enable reference'
for kind in nat rules Tables; do /sbin/pfctl -a "$FOREIGN_ANCHOR" -F "$kind" >/dev/null; done
/sbin/pfctl -X "$FOREIGN_TOKEN"
FOREIGN_TOKEN=''
"$HELPER" start "$PROJECT_DIR" "${1:-huacloud/us-adv-iepl-3.conf}" "${2:-Wi-Fi}"
"$HELPER" stop
if [ "$BEFORE_STATUS" != "$(status)" ] || [ "$BEFORE_TOKENS" != "$(tokens)" ]; then echo 'Original PF enable state/references not restored.' >&2; exit 1; fi
echo 'PASS: own-only reference release and original PF enable state/reference set restoration'
