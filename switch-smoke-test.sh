#!/bin/bash
# Exercises real switching and rollback using temporary configurations, never edits real profiles.
set -euo pipefail
umask 077
GUI_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$GUI_DIR")
HELPER="$GUI_DIR/build/ClimbOver.app/Contents/Helpers/ProxyControl"
STATE=/var/run/climbover-gui/state.json
SUMMARY=/var/run/climbover-gui/summary.json
SERVICE=${2:-Wi-Fi}
if [ "$EUID" -ne 0 ]; then echo 'Run with sudo.' >&2; exit 1; fi
if [ -e "$STATE" ] || [ -e /var/run/climbover-pf.token ]; then echo 'Stop existing proxies before testing.' >&2; exit 1; fi
FIXTURES=$(/usr/bin/mktemp -d "$PROJECT_DIR/conf/gui-switch-test.XXXXXX")
RELATIVE=${FIXTURES#"$PROJECT_DIR/conf/"}
DNS_BEFORE=$(/usr/sbin/networksetup -getdnsservers "$SERVICE")
pf_tokens() { /sbin/pfctl -s References | /usr/bin/awk '$1 ~ /^[0-9]+$/ {print $(NF-3)}' | /usr/bin/sort; }
PF_TOKENS_BEFORE=$(pf_tokens)
assert_pf_empty() {
    for kind in rules nat Tables; do
        if [ -n "$(/sbin/pfctl -a com.apple/climbovergui -s "$kind")" ]; then echo 'Application PF anchor still contains configuration.' >&2; exit 1; fi
    done
    if [ "$PF_TOKENS_BEFORE" != "$(pf_tokens)" ]; then echo 'PF enable references were not restored.' >&2; exit 1; fi
}
cleanup() { "$HELPER" stop || true; /bin/rm -rf "$FIXTURES"; }
trap cleanup EXIT
/bin/ln -s "$PROJECT_DIR/obfs-local" "$FIXTURES/real-obfs-local"
/bin/cat > "$FIXTURES/obfs-wrapper" <<'SH'
#!/bin/sh
plugin_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -e "$plugin_dir/fail-plugin" ]; then exit 1; fi
exec "$plugin_dir/real-obfs-local" "$@"
SH
/bin/chmod 700 "$FIXTURES/obfs-wrapper"
/usr/bin/python3 - "$PROJECT_DIR/conf/${1:-huacloud/us-adv-iepl-3.conf}" "$FIXTURES" <<'PY'
import json,pathlib,sys
source=json.loads(pathlib.Path(sys.argv[1]).read_text())
fixtures=pathlib.Path(sys.argv[2])
if not source.get('plugin'):
    raise SystemExit('The smoke test needs a working profile using obfs-local.')
(fixtures/'good-b.conf').write_text(json.dumps(source))
source['plugin']=str(fixtures/'obfs-wrapper')
(fixtures/'good-a.conf').write_text(json.dumps(source))
bad={'server':'127.0.0.1','server_port':9,'method':'chacha20-ietf-poly1305','password':'test-only',
     'protocol':'redir','local_address':'127.0.0.1','local_port':59097,'timeout':1,'mode':'tcp_only'}
(fixtures/'unreachable.conf').write_text(json.dumps(bad))
bad['method']='not-a-real-cipher'
(fixtures/'invalid-cipher.conf').write_text(json.dumps(bad))
(fixtures/'invalid-json.conf').write_text('{not JSON')
PY
assert_profile() {
    if [ "$(/usr/bin/plutil -extract profile raw -o - "$SUMMARY")" != "$1" ]; then echo 'Unexpected active profile.' >&2; exit 1; fi
    if [ "$(/usr/bin/plutil -extract ready raw -o - "$SUMMARY")" != true ]; then echo 'Session is not ready.' >&2; exit 1; fi
}
expect_failure() {
    if "$HELPER" start "$PROJECT_DIR" "$RELATIVE/$1" "$SERVICE" >"$FIXTURES/failure.log" 2>&1; then
        echo 'Expected switch failure.' >&2; exit 1
    fi
    if ! /usr/bin/grep -q "$2" "$FIXTURES/failure.log"; then
        /bin/cat "$FIXTURES/failure.log" >&2; exit 1
    fi
}
"$HELPER" start "$PROJECT_DIR" "$RELATIVE/good-a.conf" "$SERVICE"
"$HELPER" start "$PROJECT_DIR" "$RELATIVE/good-b.conf" "$SERVICE"
assert_profile "$RELATIVE/good-b.conf"
"$HELPER" start "$PROJECT_DIR" "$RELATIVE/good-a.conf" "$SERVICE"
assert_profile "$RELATIVE/good-a.conf"
PF_A_RULES=$(/sbin/pfctl -a com.apple/climbovergui -sr)
PF_A_NAT=$(/sbin/pfctl -a com.apple/climbovergui -sn)
PF_A_TABLE=$(/sbin/pfctl -a com.apple/climbovergui -t direct_cidr -T show)
assert_pf_a() {
    if [ "$PF_A_RULES" != "$(/sbin/pfctl -a com.apple/climbovergui -sr)" ] ||
       [ "$PF_A_NAT" != "$(/sbin/pfctl -a com.apple/climbovergui -sn)" ] ||
       [ "$PF_A_TABLE" != "$(/sbin/pfctl -a com.apple/climbovergui -t direct_cidr -T show)" ]; then
        echo 'Rollback PF rules or address table differ from the previous working node.' >&2; exit 1
    fi
}
echo 'PASS: successful sequential switches through real proxy and DNS checks'
BEFORE_ID=$(/usr/bin/plutil -extract sessionID raw -o - "$STATE")
expect_failure invalid-json.conf '已保留当前节点'
if [ "$(/usr/bin/plutil -extract sessionID raw -o - "$STATE")" != "$BEFORE_ID" ]; then echo 'Invalid config interrupted old session.' >&2; exit 1; fi
echo 'PASS: invalid configuration leaves existing session untouched'
expect_failure invalid-cipher.conf '已自动恢复旧节点'
assert_profile "$RELATIVE/good-a.conf"
assert_pf_a
echo 'PASS: process startup failure rolls back'
printf '{broken source file' > "$FIXTURES/good-a.conf"
expect_failure unreachable.conf '已自动恢复旧节点'
assert_profile "$RELATIVE/good-a.conf"
assert_pf_a
/usr/bin/curl --fail --silent --show-error --noproxy '' --socks5-hostname 127.0.0.1:59098 --connect-timeout 4 --max-time 8 https://example.com/ -o /dev/null
echo 'PASS: unreachable node restores saved runtime configuration even after source file changes'
/usr/bin/touch "$FIXTURES/fail-plugin"
expect_failure unreachable.conf '旧节点也无法恢复'
assert_pf_empty
if [ -e "$STATE" ] || [ "$DNS_BEFORE" != "$(/usr/sbin/networksetup -getdnsservers "$SERVICE")" ]; then
    echo 'Double failure did not restore stopped state and original DNS.' >&2; exit 1
fi
for port in '-iUDP:53' '-iTCP:59097' '-iTCP:59098'; do
    if /usr/sbin/lsof -nP "$port" >/dev/null 2>&1; then echo 'Listener survived double failure.' >&2; exit 1; fi
done
echo 'PASS: failure of both nodes clears all listeners and restores original DNS'
"$HELPER" start "$PROJECT_DIR" "$RELATIVE/good-b.conf" "$SERVICE"
"$HELPER" start "$PROJECT_DIR" "$RELATIVE/unreachable.conf" "$SERVICE" >"$FIXTURES/concurrent.log" 2>&1 &
SWITCH_PID=$!
SEEN=0
for ((attempt=0; attempt<200; attempt++)); do
    CURRENT=$(/usr/bin/plutil -extract profile raw -o - "$SUMMARY" 2>/dev/null || true)
    if [ "$CURRENT" = "$RELATIVE/unreachable.conf" ]; then SEEN=1; break; fi
    /bin/sleep 0.05
done
if [ "$SEEN" -ne 1 ]; then echo 'Unable to observe concurrent switch.' >&2; exit 1; fi
expect_failure good-b.conf '另一个代理操作正在执行'
wait "$SWITCH_PID" 2>/dev/null || true
assert_profile "$RELATIVE/good-b.conf"
echo 'PASS: concurrent commands are rejected while rollback preserves the latest node'
"$HELPER" stop
assert_pf_empty
if [ "$DNS_BEFORE" != "$(/usr/sbin/networksetup -getdnsservers "$SERVICE")" ]; then echo 'DNS baseline changed after switches.' >&2; exit 1; fi
echo 'PASS: original DNS baseline survives all switches'
