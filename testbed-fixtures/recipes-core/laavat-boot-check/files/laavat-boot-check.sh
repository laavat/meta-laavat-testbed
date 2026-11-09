#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Laavat Oy
# Assertions that can only be made on a running system, in a form the host can parse.
#
# These live in the image rather than in a host-side expect script on purpose: the same
# checks then run by hand on a board, unchanged, and no send/expect conversation sits
# between the evidence and the verdict.
#
# Each check prints exactly one line:  LAAVAT-CHECK: <name> PASS|FAIL <detail>
# Keep every check BOUNDED - the host boots with a timeout, and a check that can run for
# minutes (the full xtest suite) silently truncates everything after it.

# BusyBox head has no `head -1`; it needs `-n 1`.
first() { head -n 1; }

check() {
    name=$1; shift
    if out=$("$@" 2>&1); then
        echo "LAAVAT-CHECK: $name PASS $(echo "$out" | first)"
    else
        echo "LAAVAT-CHECK: $name FAIL $(echo "$out" | first)"
    fi
}

# Same, reporting the LAST line - xtest's verdict is its summary line, not its first.
check_last() {
    name=$1; shift
    if out=$("$@" 2>&1); then
        echo "LAAVAT-CHECK: $name PASS $(echo "$out" | tail -n 1)"
    else
        echo "LAAVAT-CHECK: $name FAIL $(echo "$out" | tail -n 1)"
    fi
}

check_refused_last() {
    name=$1; shift
    if out=$("$@" 2>&1); then
        echo "LAAVAT-CHECK: $name FAIL accepted when it should have been refused"
    else
        echo "LAAVAT-CHECK: $name PASS refused: $(echo "$out" | tail -n 1)"
    fi
}

# Inverted check: the command MUST fail. Used for the negative controls, where a success
# means the thing being guarded is not actually being guarded.
check_refused() {
    name=$1; shift
    if out=$("$@" 2>&1); then
        echo "LAAVAT-CHECK: $name FAIL accepted when it should have been refused"
    else
        echo "LAAVAT-CHECK: $name PASS refused: $(echo "$out" | first)"
    fi
}

ta_tamper_check() {
    TA=/lib/optee_armtz/fd02c9da-306c-48c7-a49c-bbd827ae86ee.ta
    if ! pidof tee-supplicant >/dev/null 2>&1; then
        (tee-supplicant -d >/dev/null 2>&1 &) ; sleep 3
    fi
    # Runs in its own boot, as the only TA check, so it corrupts the file before anything
    # has loaded it and an oops in the refusal path costs nothing else.
    #
    # This is a different claim from ta-reject-foreign: that one shows the anchor rejects the
    # wrong signer, this one shows the signature actually covers the TA's body.
    cp "$TA" /tmp/ta-good.ta
    # / may be mounted read-only; without this the corruption silently does not happen and the
    # check reports "accepted when it should have been refused" - blaming the TEE for a write
    # that never took place.
    # Rebuilt from three pieces with nothing but bs/count/skip - the only dd options every
    # BusyBox build has. `head -c` needs CONFIG_FEATURE_FANCY_HEAD and `conv=notrunc` needs
    # CONFIG_FEATURE_DD_IBS_OBS; when either is missing BusyBox prints its usage and leaves the
    # file untouched, which made the TEE look at fault for accepting something nothing changed.
    #
    # One 2048-byte block of the signed payload is replaced, and the total length is unchanged,
    # so this is a corrupted TA rather than a malformed one.
    #
    # Zeros, not /dev/urandom: with random bytes the outcome varied per boot - usually a clean
    # refusal, but sometimes a kernel oops in tee-supplicant, which left the remaining checks
    # unrun. A deterministic corruption makes this a gate rather than a coin flip.
    # Aim at the middle of the file. Offset 2048 was header padding that already held zeros,
    # so blanking it changed nothing at all and the check reported the TEE at fault for
    # accepting a file identical to the one it had just verified.
    TA_BLK=$(( $(wc -c < "$TA") / 2 / 2048 ))
    dd if="$TA" bs=2048 count=$TA_BLK > /tmp/ta-bad.ta 2>/tmp/ta-dd.err
    dd if=/dev/zero bs=2048 count=1 >> /tmp/ta-bad.ta 2>>/tmp/ta-dd.err
    dd if="$TA" bs=2048 skip=$(( TA_BLK + 1 )) >> /tmp/ta-bad.ta 2>>/tmp/ta-dd.err
    cat /tmp/ta-bad.ta > "$TA" 2>>/tmp/ta-dd.err
    # Confirm the file really changed before drawing any conclusion from the TEE's answer.
    if cmp -s "$TA" /tmp/ta-good.ta; then
        echo "LAAVAT-CHECK: ta-reject-tampered FAIL could not corrupt $TA: $(tail -n 2 /tmp/ta-dd.err | tr '\n' ' ')"
    else
        check_refused_last ta-reject-tampered xtest -t pkcs11 pkcs11_1001
    fi
    # sync, or the restore never leaves the page cache: the host kills the VM as soon as it sees
    # the completion marker, so an unflushed write is lost and the DEPLOYED image keeps the
    # corrupted TA. Every later boot then oopses tee-supplicant while loading it, which looks
    # like a TEE fault in a boot that tampered with nothing. runqemu now boots with `snapshot`
    # so writes are discarded anyway; this keeps the restore honest if that ever changes.
    cp /tmp/ta-good.ta "$TA"
    sync
}

# The TEE has to exist before any claim about TA signatures means anything.
# The bundle disk is mounted up front because it also carries the marker that selects the
# mode. Corrupting a TA has to happen before anything loads it - the core keeps a loaded TA
# resident, and with a resident copy the corrupted file is *accepted* (measured: moving this
# check after ta-load-signed turns it into a FAIL). But refusing a corrupted TA sometimes
# oopses tee-supplicant, which wedges every later TA check. Those two facts cannot both be
# satisfied in one boot, so the tamper gets a boot of its own.
BUNDLE=
if [ -b /dev/vdb ]; then
    mkdir -p /mnt/bundle
    mount -t vfat /dev/vdb /mnt/bundle 2>/dev/null && BUNDLE=/mnt/bundle
fi

if [ -n "$BUNDLE" ] && [ -f "$BUNDLE/laavat-ta-tamper" ]; then
    ta_tamper_check
    echo "LAAVAT-CHECK-COMPLETE"
    exit 0
fi

check optee-present test -c /dev/tee0

# TAs are loaded from the filesystem by tee-supplicant; without it every TA load fails for
# reasons that have nothing to do with signatures. Start it if the image did not.
if ! pidof tee-supplicant >/dev/null 2>&1; then
    (tee-supplicant -d >/dev/null 2>&1 &) ; sleep 3
fi
check supplicant pidof tee-supplicant

echo "LAAVAT-INFO: installed TAs:"; ls /lib/optee_armtz/ 2>&1 | head -n 20

# The service-signed TA this build embeds an anchor for (optee-os's built-in pkcs11 TA).
TA=/lib/optee_armtz/fd02c9da-306c-48c7-a49c-bbd827ae86ee.ta
check ta-present-signed test -f "$TA"

# Loading a TA makes the core verify it against the key compiled into ta_pub_key.c.
# Restored from the copy above, so a pass here also proves the refusal above was caused by
# the tampering and not by something that would have broken any load.
# NEVER pipe the command being checked: a pipeline reports the LAST command's exit code, so
# `xtest | tail` reported PASS on a run where all 30 cases failed.
check_last ta-load-signed xtest -t pkcs11 pkcs11_1001

# Negative control: optee-test ships its own TAs signed with optee-os's throwaway key, not
# the service's. The core's anchor is the service key, so it must refuse them. A pass here
# would mean the anchor is not actually being enforced.
check_refused_last ta-reject-foreign xtest -t regression 1004

# --- update bundle -------------------------------------------------------------------
# The bundle cannot live in the rootfs (it contains that rootfs), so it arrives as a second
# disk, already mounted above. The device keyring is the service's issuing CA, with
# check-purpose=codesign, because one-time-signing mints an ephemeral certificate per bundle.
if [ -n "$BUNDLE" ]; then
    check_last bundle-verify rauc info --keyring=/etc/rauc/ca.cert.pem "$BUNDLE/bundle.raucb"
    # Negative control: the same bundle signed with the local dev certificate instead of by
    # the service. It must be refused, or the keyring is not constraining anything.
    check_refused_last bundle-reject-devkey \
        rauc info --keyring=/etc/rauc/ca.cert.pem "$BUNDLE/devkey.raucb"
    # Second negative control, and a different claim: correctly signed by the service, but
    # with a byte of its CMS flipped. Refusing it shows the signature is actually verified.
    check_refused_last bundle-reject-tampered \
        rauc info --keyring=/etc/rauc/ca.cert.pem "$BUNDLE/tampered.raucb"
else
    echo "LAAVAT-CHECK: bundle-verify FAIL no bundle disk mounted at /dev/vdb"
fi

echo "LAAVAT-CHECK-COMPLETE"
