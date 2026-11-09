#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Laavat Oy
# Exercise the signing-tool verbs meta-laavat depends on, against the stub.
#
# No credentials, no network, no Yocto. This is the gate that used to be
# missing: the tasks that fetch a public key and wrap it in a certificate
# could only be run against the live service, which meant they were only ever
# exercised by `make qemu-demo` - and so not at all in CI.
#
# What it proves, in order: the four verbs are reachable and do what the build
# layer needs; the key pin is enforced in both directions; and the openssl
# certificate wrap produces a certificate carrying the service's key.
set -e

# The client under test: a signing-tool source tree if CLIENT is set, otherwise the one
# installed on the host (pip install signing-tool).
CLIENT=${CLIENT:-}
PORT=${PORT:-8799}
STUB="$(dirname "$0")/laavat-stub.py"
# The fingerprint of the fixed key the stub serves; see laavat-stub.py.
PIN=6ee04e1973b43e0eede638c61d24f5d4e3b176d38b57a27a97f0fa0d9522e68f

if [ -n "$CLIENT" ]; then
    [ -d "$CLIENT" ] || { echo "stub-smoke: CLIENT=$CLIENT is not a directory"; exit 1; }
else
    python3 -c 'import signingtool' 2>/dev/null         || { echo "stub-smoke: pip install signing-tool, or set CLIENT to a source tree"; exit 1; }
fi

WORK=$(mktemp -d)
cleanup() { [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

python3 "$STUB" --port "$PORT" >"$WORK/stub.log" 2>&1 &
STUB_PID=$!
i=0
while [ $i -lt 40 ]; do
    python3 -c "
import socket,sys
s=socket.socket(); s.settimeout(0.2)
sys.exit(0 if s.connect_ex(('127.0.0.1',$PORT))==0 else 1)" && break
    i=$((i+1)); sleep 0.25
done

printf 'stub-token' >"$WORK/tok"; chmod 600 "$WORK/tok"
TOOL="python3 -m signingtool.cli -c -a http://127.0.0.1:$PORT -t @$WORK/tok"
[ -z "$CLIENT" ] || cd "$CLIENT"

say() { printf '  %-46s %s\n' "$1" "$2"; }

echo "stub-smoke: hermetic signing-tool checks"

# 1. The key a device must trust, and the pin that stops it changing unnoticed.
$TOOL product getpubkey -P prod-uuid --operid oper-uuid \
      -O "$WORK/pub.pem" --fingerprint "$PIN" >/dev/null
say "product getpubkey (pinned)" ok

if $TOOL product getpubkey -P prod-uuid --operid oper-uuid \
        -O "$WORK/bad.pem" --fingerprint "${PIN%??}00" >/dev/null 2>&1; then
    echo "FAIL: a wrong pin was accepted"; exit 1
fi
[ -f "$WORK/bad.pem" ] && { echo "FAIL: a rejected pin still wrote a key"; exit 1; }
say "a wrong pin is refused, writing nothing" ok

# 2. The certificate wrap: the fetched key, inside a certificate U-Boot's tooling accepts.
(umask 077; openssl genrsa -out "$WORK/fit.key" 2048 2>/dev/null)
openssl asn1parse -in "$WORK/pub.pem" | grep -q rsaEncryption
openssl req -new -key "$WORK/fit.key" -subj "/CN=laavat" -out "$WORK/d.csr" 2>/dev/null
openssl x509 -req -in "$WORK/d.csr" -signkey "$WORK/fit.key" \
        -force_pubkey "$WORK/pub.pem" -days 36500 -out "$WORK/laavat.crt" 2>/dev/null
IN_CERT=$(openssl x509 -in "$WORK/laavat.crt" -noout -pubkey \
          | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)
[ "$IN_CERT" = "$PIN" ] || { echo "FAIL: the certificate does not carry the service key"; exit 1; }
say "certificate carries the service key" ok

# The same wrap with LAAVAT_SIGN_SKIP set: laavat-fitkey-base drops -force_pubkey by
# leaving "$@" empty, so the certificate carries the placeholder's own key and poky signs
# and verifies the FIT against one throwaway key. Proving the empty-"$@" form still
# produces a usable certificate is the point - `make skip-smoke` covers laavat-hab, not
# this, and a FIT build needs a kernel.
set --
openssl req -new -key "$WORK/fit.key" -subj "/CN=laavat" -out "$WORK/s.csr" 2>/dev/null
openssl x509 -req -in "$WORK/s.csr" -signkey "$WORK/fit.key" \
        "$@" -days 36500 -out "$WORK/skip.crt" 2>/dev/null
SKIP_KEY=$(openssl x509 -in "$WORK/skip.crt" -noout -pubkey \
           | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)
PLACEHOLDER=$(openssl pkey -in "$WORK/fit.key" -pubout -outform DER 2>/dev/null \
              | sha256sum | cut -d' ' -f1)
[ "$SKIP_KEY" = "$PLACEHOLDER" ] || { echo "FAIL: the skip certificate carries neither key"; exit 1; }
[ "$SKIP_KEY" != "$PIN" ] || { echo "FAIL: the skip certificate carries the service key"; exit 1; }
say "under SKIP the certificate carries the throwaway key" ok

# 3. The network-free verbs, which need no credentials at all.
mkdir -p "$WORK/ta"; printf 'TA' >"$WORK/ta/a.ta"
python3 -m signingtool.cli imagesigning pack -O "$WORK/tas.tar.gz" "$WORK/ta/a.ta"
say "imagesigning pack (no credentials)" ok

python3 - "$WORK" <<'PY'
import gzip, io, os, sys, tarfile
work = sys.argv[1]
with open(os.path.join(work, "signed.tar.gz"), "wb") as raw:
    with gzip.GzipFile(fileobj=raw, mode="wb", mtime=0, filename="") as gz:
        with tarfile.open(fileobj=gz, mode="w") as tf:
            info = tarfile.TarInfo("a.ta.signed"); info.size = 6
            tf.addfile(info, io.BytesIO(b"SIGNED"))
PY
python3 -m signingtool.cli imagesigning unpack -A "$WORK/signed.tar.gz" \
        -C "$WORK/ta" --member a.ta --strip-suffix .signed >/dev/null
[ "$(cat "$WORK/ta/a.ta")" = "SIGNED" ] || { echo "FAIL: unpack did not install"; exit 1; }
say "imagesigning unpack installs the signed member" ok

# 3b. hab-request, the verb every HAB build renders its request.json with. Offline like
# pack and unpack, and the only one of the four the layer calls that nothing here ran.
python3 - "$WORK" <<'PY'
import struct, sys, os
# A 32-byte HABv4 IVT: tag 0xD1, BE length 0x0020, then 7 LE words. Two stages at the
# real offsets, so hab-request has to select IVTs rather than count them.
def ivt(entry, ivt_self, csf, boot=0, version=0x41):
    return (struct.pack(">BHB", 0xD1, 0x20, version)
            + struct.pack("<7I", entry, 0, 0, boot, ivt_self, csf, 0))
blob = bytearray(0x13AB70)
for off, data in ((0, ivt(0x7E1000, 0x7E0FC0, 0x81DBC0, boot=0x7E0FE0)),
                  (0x58C00, ivt(0x401FADC0, 0x401FBDC0, 0x401FBDE0, version=0x40))):
    blob[off:off + len(data)] = data
open(os.path.join(sys.argv[1], "hab-flash.bin"), "wb").write(bytes(blob))
PY
python3 -m signingtool.cli imagesigning hab-request --image "$WORK/hab-flash.bin" \
        --stages SPL UBOOT --member flash.bin -O "$WORK/request.json" >/dev/null
python3 - "$WORK" <<'PY'
import json, sys, os
req = json.load(open(os.path.join(sys.argv[1], "request.json")))
csfs = req.get("csfs") or req.get("CSFs") or []
assert len(csfs) == 2, "expected one CSF per stage, got %d: %s" % (len(csfs), req)
PY
say "imagesigning hab-request renders both stages" ok

# 4. The whole round trip, including resume and the digest checks.
printf 'BOOT-IMAGE-BYTES' >"$WORK/flash.bin"
$TOOL imagesigning sign --operation SignSPSDK -P prod-uuid --operid oper-uuid \
      -N smoke -D "stub smoke" -F "$WORK/flash.bin" -O "$WORK/flash.signed" \
      --state-dir "$WORK/state" --wait-timeout 30 >/dev/null
[ -s "$WORK/flash.signed" ] || { echo "FAIL: sign installed nothing"; exit 1; }
say "imagesigning sign, verified and installed" ok

# The slot must be released once the artifact is in place, or the next build
# resumes onto a request that is already finished.
if ls "$WORK/state"/signing-tool-*.json >/dev/null 2>&1; then
    echo "FAIL: resume state survived a completed sign"; exit 1
fi
say "resume state cleared after a completed sign" ok

echo "stub-smoke: all checks passed"
