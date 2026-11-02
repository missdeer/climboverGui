#!/bin/bash
set -euo pipefail
GUI_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SOURCE_DIR=${COREDNS_SOURCE_DIR:-$(dirname "$GUI_DIR")/coredns-dev}
GO=${GO_BINARY:-go}
OUTPUT="$GUI_DIR/build/coredns-local"
mkdir -p "$OUTPUT"
# Build copies preserve the supplied checkouts, including local changes.
if [ ! -d "$OUTPUT/coredns" ]; then
    mkdir -p "$OUTPUT/coredns"
    tar -C "$SOURCE_DIR/coredns" --exclude=.git -cf - . | tar -C "$OUTPUT/coredns" -xf -
    git -C "$OUTPUT/coredns" apply "$SOURCE_DIR/coredns_custom_build/forward.go.patch"
    git -C "$OUTPUT/coredns" apply "$SOURCE_DIR/coredns_custom_build/forward-setup.go.patch"
    python3 - "$OUTPUT/coredns/plugin.cfg" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
text = text.replace('forward:forward', 'fallback:github.com/missdeer/fallback\ndnsredir:github.com/leiless/dnsredir\nforward:forward\nproxy:github.com/missdeer/proxy')
text = text.replace('hosts:hosts', 'ads:github.com/missdeer/ads\nblocklist:github.com/relekang/coredns-blocklist\nhosts:hosts')
text = text.replace('rewrite:rewrite', 'rewrite:rewrite\nbogus:github.com/missdeer/bogus\nipset:github.com/missdeer/ipset')
text = text.replace('cache:cache', 'cache:cache\nredisc:github.com/missdeer/redis')
excluded = {'azure', 'route53', 'trace', 'etcd', 'clouddns', 'k8s_external', 'kubernetes', 'https', 'https3'}
path.write_text('\n'.join(line for line in text.splitlines() if line.split(':')[0] not in excluded) + '\n')
PY
fi
if [ ! -d "$OUTPUT/dnsredir" ]; then
    git clone --depth=1 https://github.com/leiless/dnsredir.git "$OUTPUT/dnsredir"
fi
if [ ! -d "$OUTPUT/bogus" ]; then
    git clone --depth=1 https://github.com/missdeer/bogus.git "$OUTPUT/bogus"
fi
# bogus has no go.mod; use its source as a local module, as prepare.sh does for legacy plugins.
if [ ! -f "$OUTPUT/bogus/go.mod" ]; then
    printf 'module github.com/missdeer/bogus\n\ngo 1.13\n' > "$OUTPUT/bogus/go.mod"
fi
mkdir -p "$OUTPUT/include/net" "$OUTPUT/include/libkern"
for header in bsd/net/pfvar.h bsd/net/radix.h libkern/libkern/tree.h; do
    target="$OUTPUT/include/${header#*/}"
    if [ ! -s "$target" ]; then
        curl -fL "https://raw.githubusercontent.com/apple/darwin-xnu/master/$header" -o "$target"
    fi
done
export CGO_ENABLED=1 GOOS=darwin
export GOARCH
case "$(uname -m)" in arm64) GOARCH=arm64 ;; x86_64) GOARCH=amd64 ;; esac
export CGO_CFLAGS="${CGO_CFLAGS:-} -I$OUTPUT/include"
export GOTOOLCHAIN=auto
export GOFLAGS="${GOFLAGS:-} -mod=mod"
cd "$OUTPUT/coredns"
"$GO" mod edit -replace=github.com/leiless/dnsredir=../dnsredir
"$GO" mod edit -replace=github.com/missdeer/ipset="$SOURCE_DIR/ipset"
"$GO" mod edit -replace=github.com/missdeer/bogus=../bogus
"$GO" generate coredns.go
"$GO" get
revision=$(git -C "$SOURCE_DIR/coredns" rev-parse --short HEAD)
"$GO" build -tags=grpcnotrace -ldflags="-s -w -X github.com/coredns/coredns/coremain.GitCommit=$revision-custom" -o "$OUTPUT/coredns-native"
"$OUTPUT/coredns-native" -plugins
printf 'Built %s\n' "$OUTPUT/coredns-native"
