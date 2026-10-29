#!/bin/bash
# Explicit fault injection against this app's own sessions. Requires administrator privileges.
set -euo pipefail
umask 077
GUI_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$GUI_DIR")
HELPER="$GUI_DIR/build/ClimbOver.app/Contents/Helpers/ProxyControl"
STATE=/var/run/climbover-gui/state.json
SUMMARY=/var/run/climbover-gui/summary.json
EVENT=/var/run/climbover-gui/recovery.json
if [ "$EUID" -ne 0 ]; then echo 'Run with sudo.' >&2; exit 1; fi
PROFILE=${1:-huacloud/us-adv-iepl-2.conf}
SERVICE=${2:-Wi-Fi}
RESTORE=0
OWNER=''
if [ -e "$STATE" ]; then
    if [ "${3:-}" != --replace-active ]; then echo 'Stop the existing GUI session first.' >&2; exit 1; fi
    PROFILE=$(/usr/bin/plutil -extract profile raw -o - "$SUMMARY")
    SERVICE=$(/usr/bin/plutil -extract service raw -o - "$SUMMARY")
    OWNER=$(/usr/bin/pgrep -x ClimbOver | /usr/bin/head -n 1 || true)
    RESTORE=1
    "$HELPER" stop
fi
DNS_BEFORE=$(/usr/sbin/networksetup -getdnsservers "$SERVICE")
SNAPSHOT=$(/usr/bin/mktemp "$GUI_DIR/build/recovery-state.XXXXXX")
FAKE_OWNER=''
cleanup() {
    "$HELPER" stop || true
    if [ -n "$FAKE_OWNER" ]; then kill "$FAKE_OWNER" 2>/dev/null || true; wait "$FAKE_OWNER" 2>/dev/null || true; fi
    /bin/rm -f "$SNAPSHOT"
    if [ "$RESTORE" -eq 1 ]; then
        if [ -n "$OWNER" ]; then "$HELPER" start "$PROJECT_DIR" "$PROFILE" "$SERVICE" "$OWNER"
        else "$HELPER" start "$PROJECT_DIR" "$PROFILE" "$SERVICE"; fi
    fi
}
trap cleanup EXIT
assert_recovered() {
    local completed=''
    for ((attempt=0; attempt<30; attempt++)); do
        if [ ! -e "$STATE" ] && [ -e "$EVENT" ]; then
            completed=$(/usr/bin/plutil -extract completed raw -o - "$EVENT")
            if [ "$completed" = true ]; then break; fi
        fi
        /bin/sleep 1
    done
    if [ -e "$STATE" ] || [ "$completed" != true ]; then echo 'Automatic recovery timed out.' >&2; exit 1; fi
    if [ "$DNS_BEFORE" != "$(/usr/sbin/networksetup -getdnsservers "$SERVICE")" ]; then
        echo 'Original DNS was not restored.' >&2; exit 1
    fi
    if /usr/sbin/lsof -nP -iUDP:53 >/dev/null 2>&1 || /usr/sbin/lsof -nP -iTCP:59097 -sTCP:LISTEN >/dev/null 2>&1; then
        echo 'A proxy/DNS listener survived recovery.' >&2; exit 1
    fi
    if [ -n "$(/sbin/pfctl -a com.apple/climbovergui -sr 2>/dev/null)" ] ||
       [ -n "$(/sbin/pfctl -a com.apple/climbovergui -sn 2>/dev/null)" ]; then
        echo 'GUI PF rules remain after recovery.' >&2; exit 1
    fi
    for kind in processes companions; do
        local index=0 pid stat
        while pid=$(/usr/bin/plutil -extract "$kind.$index.pid" raw -o - "$SNAPSHOT" 2>/dev/null); do
            stat=$(/bin/ps -p "$pid" -o stat= 2>/dev/null || true)
            if [ -n "$stat" ] && [[ "$stat" != *Z* ]]; then echo "Managed process $pid remains after recovery." >&2; exit 1; fi
            index=$((index + 1))
        done
    done
}
for index in 0 1; do
    "$HELPER" start "$PROJECT_DIR" "$PROFILE" "$SERVICE"
    /bin/cp "$STATE" "$SNAPSHOT"
    PID=$(/usr/bin/plutil -extract "processes.$index.pid" raw -o - "$SUMMARY")
    kill -KILL "$PID"
    assert_recovered
    echo "PASS: process $index SIGKILL -> DNS restored, PF cleared, proxy/plugin processes cleaned"
done
/bin/sleep 300 &
FAKE_OWNER=$!
"$HELPER" start "$PROJECT_DIR" "$PROFILE" "$SERVICE" "$FAKE_OWNER"
/bin/cp "$STATE" "$SNAPSHOT"
kill -KILL "$FAKE_OWNER"
wait "$FAKE_OWNER" 2>/dev/null || true
FAKE_OWNER=''
assert_recovered
echo 'PASS: GUI owner SIGKILL -> automatic network restoration'

"$HELPER" start "$PROJECT_DIR" "$PROFILE" "$SERVICE" &
STARTER=$!
INTERRUPTED=0
for ((attempt=0; attempt<100; attempt++)); do
    if [ -e "$STATE" ] && /usr/bin/plutil -extract processes.0.pid raw -o - "$STATE" >/dev/null 2>&1; then
        PHASE=$(/usr/bin/plutil -extract phase raw -o - "$STATE")
        if [ "$PHASE" = starting ]; then
            /bin/cp "$STATE" "$SNAPSHOT"
            kill -KILL "$STARTER"
            INTERRUPTED=1
            break
        fi
    fi
    /bin/sleep 0.05
done
wait "$STARTER" 2>/dev/null || true
if [ "$INTERRUPTED" -ne 1 ]; then echo 'Unable to interrupt startup for recovery test.' >&2; exit 1; fi
assert_recovered
echo 'PASS: startup helper SIGKILL -> incomplete session automatically cleaned'
