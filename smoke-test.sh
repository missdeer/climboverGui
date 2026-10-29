#!/bin/bash
# Optional integration check: briefly starts the proxy and always restores it.
set -euo pipefail
GUI_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$GUI_DIR")
HELPER="$GUI_DIR/build/ClimbOver.app/Contents/Helpers/ProxyControl"
if [ "$EUID" -ne 0 ]; then
    echo 'Run with sudo; this test temporarily changes PF and DNS.' >&2
    exit 1
fi
if [ -e /var/run/climbover-gui/state.json ] || [ -e /var/run/climbover-pf.token ]; then
    echo 'An existing proxy session must be stopped before this test.' >&2
    exit 1
fi
NETWORK_DEVICE=$(/sbin/route -n get default | /usr/bin/awk '/interface:/ {print $2; exit}')
NETWORK_SERVICE=$(/usr/sbin/networksetup -listnetworkserviceorder | /usr/bin/awk -v device="$NETWORK_DEVICE" '
    /^\([0-9]+\) / {sub(/^\([0-9]+\) /, ""); service=$0}
    index($0, "Device: " device ")") {print service; exit}
')
if [ -z "$NETWORK_SERVICE" ]; then
    echo 'Unable to identify the default network service.' >&2
    exit 1
fi
DNS_BEFORE=$(/usr/sbin/networksetup -getdnsservers "$NETWORK_SERVICE")
cleanup() { "$HELPER" stop; }
trap cleanup EXIT
"$HELPER" start "$PROJECT_DIR" "${1:-huacloud/us-adv-iepl-2.conf}" "$NETWORK_SERVICE"
echo 'PASS: proxy processes and listeners started'
DNS_RESULT=$(/usr/bin/dig @127.0.0.1 example.com A +short +time=5 +tries=1)
if [ -z "$DNS_RESULT" ]; then
    echo 'Local DNS did not resolve example.com.' >&2
    exit 1
fi
echo 'PASS: local DNS lookup'
/usr/bin/curl --fail --silent --show-error --max-time 20 https://example.com/ -o /dev/null
echo 'PASS: HTTPS through transparent proxy'
"$HELPER" stop
DNS_AFTER=$(/usr/sbin/networksetup -getdnsservers "$NETWORK_SERVICE")
if [ "$DNS_BEFORE" != "$DNS_AFTER" ]; then
    echo 'DNS restoration mismatch.' >&2
    exit 1
fi
echo 'PASS: original DNS restored'
trap - EXIT
