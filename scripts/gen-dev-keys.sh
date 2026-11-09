#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Laavat Oy
#
# Generate the test-bed's throwaway RAUC development keys, once.
#
# `rauc bundle` refuses to run without a signing key, even in the tiers where the
# service re-signs the finished bundle, so every tier needs one. They are generated
# here rather than committed: a private key in a public repository is a key anyone
# can sign with. Existing keys are kept, so a rebuild does not change what an
# already-built image trusts; delete them to rotate.
#
#   testbed-fixtures/files/dev-keys/dev.{key,cert}.pem
#       self-signed signer, shared by the seven tiers that use LAAVAT_DEVKEYS_DIR
#   sample-{qemu-arm64,variscite-imx8mm}/recipes-core/bundles/files/dev-keys/rauc/
#       ca.{key,cert}.pem            dev CA, installed as the image's keyring
#       development-1.{key,cert}.pem bundle signer issued by that CA
#
# Needs openssl on the host.
set -eu

top=$(cd "$(dirname "$0")/.." && pwd)
command -v openssl >/dev/null || { echo "gen-dev-keys: openssl not found on the host"; exit 1; }

note="DO NOT USE IN PRODUCTION"
umask 077

shared="$top/testbed-fixtures/files/dev-keys"
if [ ! -f "$shared/dev.key.pem" ] || [ ! -f "$shared/dev.cert.pem" ]; then
    mkdir -p "$shared"
    openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
        -subj "/CN=meta-laavat-testbed development key $note" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -keyout "$shared/dev.key.pem" -out "$shared/dev.cert.pem" 2>/dev/null
    echo "gen-dev-keys: wrote $shared/dev.{key,cert}.pem"
fi

# The two sample layers that keep their own CA + signer pair share one generated pair,
# as their committed copies used to.
first=""
for layer in sample-qemu-arm64 sample-variscite-imx8mm; do
    d="$top/$layer/recipes-core/bundles/files/dev-keys/rauc"
    if [ -f "$d/ca.key.pem" ] && [ -f "$d/ca.cert.pem" ] \
       && [ -f "$d/development-1.key.pem" ] && [ -f "$d/development-1.cert.pem" ]; then
        first=${first:-$d}
        continue
    fi
    mkdir -p "$d"
    if [ -n "$first" ]; then
        cp "$first"/ca.key.pem "$first"/ca.cert.pem \
           "$first"/development-1.key.pem "$first"/development-1.cert.pem "$d"/
        echo "gen-dev-keys: copied the dev CA and signer into $d"
        continue
    fi
    work=$(mktemp -d)
    openssl req -x509 -newkey rsa:4096 -nodes -sha256 -days 7300 \
        -subj "/O=meta-laavat-testbed/CN=testbed RAUC dev CA - $note" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -keyout "$d/ca.key.pem" -out "$d/ca.cert.pem" 2>/dev/null
    openssl req -new -newkey rsa:4096 -nodes -sha256 \
        -subj "/O=meta-laavat-testbed/CN=testbed RAUC dev signer 1 - $note" \
        -keyout "$d/development-1.key.pem" -out "$work/signer.csr" 2>/dev/null
    printf '%s\n' "basicConstraints=CA:FALSE" "keyUsage=critical,digitalSignature" \
        > "$work/ext.cnf"
    openssl x509 -req -in "$work/signer.csr" -CA "$d/ca.cert.pem" -CAkey "$d/ca.key.pem" \
        -CAcreateserial -CAserial "$work/ca.srl" -sha256 -days 7300 \
        -extfile "$work/ext.cnf" -out "$d/development-1.cert.pem" 2>/dev/null
    rm -f "$work/signer.csr" "$work/ext.cnf" "$work/ca.srl"
    rmdir "$work"
    echo "gen-dev-keys: wrote the dev CA and signer into $d"
    first=$d
done
