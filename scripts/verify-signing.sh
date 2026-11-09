#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Laavat Oy
# Host-side signature checks for the i.MX8MM signing test-bed.
# Run inside the kas shell:  make verify   (== kas-container shell <cfg> -c /work/scripts/verify-signing.sh)
# Prints one "PASS|FAIL|SKIP <component>" line per component; exit 1 if any FAIL.
set -u

ENVFILE=$(mktemp)
trap 'rm -f "$ENVFILE"' EXIT
bitbake -e core-image-minimal > "$ENVFILE" 2>/dev/null || { echo "FAIL env: bitbake -e failed"; exit 1; }
var() { sed -n "s/^$1=\"\(.*\)\"\$/\1/p" "$ENVFILE" | head -n 1; }

DEPLOY=$(var DEPLOY_DIR_IMAGE)
DEPLOY_DIR=$(var DEPLOY_DIR)
TMPDIR=$(var TMPDIR)
MACHINE=$(var MACHINE)
IMGBASE="core-image-minimal-${MACHINE}.rootfs"

rc=0
# components that must not SKIP (set by "make verify" for kas/all.yml)
REQUIRE="${REQUIRE:-}"
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; rc=1; }
skip() { echo "SKIP $1 ($2)"; case " $REQUIRE " in *" $1 "*) rc=1;; esac; }
native() { # native <recipe> <cmd...>  — run a tool from a native recipe sysroot
    r=$1; shift
    # rm_work deletes native workdirs, so restore the recipe sysroot from sstate and retry.
    oe-run-native "$r" "$@" 2>/dev/null && return
    bitbake -f -c addto_recipe_sysroot "$r" >/dev/null 2>&1
    oe-run-native "$r" "$@"
}

check_baseline() {
    [ -e "$DEPLOY/imx-boot" ] || { fail baseline "no $DEPLOY/imx-boot"; return; }
    [ -e "$DEPLOY/$IMGBASE.ext4" ] || { fail baseline "no $DEPLOY/$IMGBASE.ext4"; return; }
    [ -e "$DEPLOY/$IMGBASE.wic" ] || { fail baseline "no $DEPLOY/$IMGBASE.wic"; return; }
    pass baseline
}

check_fit() {
    [ "$(var UBOOT_SIGN_ENABLE)" = "1" ] || { skip fit "UBOOT_SIGN_ENABLE != 1"; return; }
    [ -e "$DEPLOY/fitImage" ] || { fail fit "no $DEPLOY/fitImage"; return; }
    [ -e "$DEPLOY/u-boot.dtb" ] || { fail fit "no $DEPLOY/u-boot.dtb (signed control DTB)"; return; }
    tools=$(var PREFERRED_PROVIDER_u-boot-tools-native); tools=${tools:-u-boot-tools-native}
    # Whatever key the config asked for, not a literal: kas/fit.yml signs as "dev" and
    # kas/laavat/fit.yml as "laavat", and asserting the configured name is what catches a
    # FIT signed by something other than the key this tier is supposed to use.
    keyname=$(var UBOOT_SIGN_KEYNAME); keyname=${keyname:-dev}
    native "$tools" mkimage -l "$DEPLOY/fitImage" | grep -q "Sign algo:.*sha256,rsa2048:$keyname" \
        || { fail fit "fitImage has no sha256,rsa2048:$keyname configuration signature"; return; }
    native "$tools" fit_check_sign -f "$DEPLOY/fitImage" -k "$DEPLOY/u-boot.dtb" >/dev/null 2>&1 \
        || { fail fit "fit_check_sign against u-boot.dtb failed"; return; }
    # the pubkey DTB U-Boot actually boots with is the one baked into imx-boot
    python3 -c 'import sys;d=open(sys.argv[1],"rb").read();sys.exit(0 if d in open(sys.argv[2],"rb").read() else 1)' \
        "$DEPLOY/u-boot.dtb" "$DEPLOY/imx-boot" \
        || { fail fit "u-boot.dtb is not embedded in imx-boot"; return; }
    pass fit
}

check_hab() {
    case ":$(var OVERRIDES):" in *:hab:*) ;; *) skip hab "hab not in OVERRIDES"; return;; esac
    ivtcsf="$(dirname "$0")/ivt-csf.py"
    set - $(var IMXBOOT_TARGETS); unsigned="$DEPLOY/imx-boot-${MACHINE}-sd.bin-$1"
    python3 "$ivtcsf" "$DEPLOY/imx-boot" >/dev/null 2>&1 \
        || { fail hab "deploy/imx-boot has no CSF header (not HAB-signed)"; return; }
    if [ -e "$unsigned" ]; then
        python3 "$ivtcsf" "$unsigned" >/dev/null 2>&1 \
            && { fail hab "unsigned build product also has a CSF header — check is meaningless"; return; }
    fi
    # A CSF header only says something is there. This verifies the CMS signatures over the
    # bytes they claim to cover. CST ships no HAB4 verifier to use instead: its
    # hab4_image_verifier calls no verify primitive at all and prints identical output for a
    # tampered image (its own banner disclaims it), and hab_csf_parser only extracts.
    # --selfcheck flips a byte and requires the verdict to go red, so a pass here also
    # says the check is capable of failing - which NXP's hab4_image_verifier is not.
    python3 "$(dirname "$0")/hab-verify.py" --selfcheck "$DEPLOY/imx-boot" \
        || { fail hab "a HAB CMS signature did not verify, or the check could not fail"; return; }
    pass hab
}

check_modsign() {
    case " $(var DISTRO_FEATURES) " in *" modsign "*) ;; *) skip modsign "modsign not in DISTRO_FEATURES"; return;; esac
    ipk=$(ls "$DEPLOY_DIR"/ipk/*/kernel-module-*.ipk 2>/dev/null | head -n 1)
    [ -n "$ipk" ] || { fail modsign "no kernel-module-*.ipk under $DEPLOY_DIR/ipk"; return; }
    d=$(mktemp -d)
    ( cd "$d" && ar x "$ipk" ) || { fail modsign "ar x $ipk failed"; rm -rf "$d"; return; }
    data=$(ls "$d"/data.tar.* | head -n 1)
    case "$data" in
        *.zst) tail=$(zstd -dc "$data" | tar -xO --wildcards '*.ko' | tail -c 28) ;;
        *.xz)  tail=$(xz -dc "$data"   | tar -xO --wildcards '*.ko' | tail -c 28) ;;
        *.gz)  tail=$(gzip -dc "$data" | tar -xO --wildcards '*.ko' | tail -c 28) ;;
        *)     tail="" ;;
    esac
    rm -rf "$d"
    # marker is 27 chars + newline = 28 bytes; $(...) strips the trailing newline
    [ "$tail" = "~Module signature appended~" ] \
        || { fail modsign "$(basename "$ipk"): .ko does not end with the module-signature marker"; return; }
    pass modsign
}

check_rauc() {
    case " $(var DISTRO_FEATURES) " in *" rauc "*) ;; *) skip rauc "rauc not in DISTRO_FEATURES"; return;; esac
    # Each tier names its bundle after its own sample layer, so find it rather than
    # spelling one tier's name here.
    bundle=$(ls "$DEPLOY"/*.raucb 2>/dev/null | head -n 1)
    [ -n "$bundle" ] || { fail rauc "no .raucb in $DEPLOY"; return; }
    keyring=$(ls "$(dirname "$0")"/../sample-*/recipes-core/bundles/files/dev-keys/rauc/ca.cert.pem 2>/dev/null | head -n 1)
    [ -n "$keyring" ] || { fail rauc "no dev-key rauc CA found in any sample-* layer"; return; }
    out=$(native rauc-native rauc info --keyring "$keyring" "$bundle" 2>&1) \
        || { fail rauc "rauc info --keyring failed: $(echo "$out" | tail -n 1)"; return; }
    echo "$out" | grep -q 'Format:.*verity' || { fail rauc "bundle format is not verity"; return; }
    # the same dev CA has to be in the rootfs, or the target could not verify the bundle
    native e2fsprogs-native debugfs -R "cat /etc/rauc/ca.cert.pem" "$DEPLOY/$IMGBASE.ext4" 2>/dev/null \
        | grep -q 'BEGIN CERTIFICATE' || { fail rauc "dev CA not in rootfs /etc/rauc/ca.cert.pem"; return; }
    pass rauc
}

check_verity() {
    case " $(var IMAGE_CLASSES) " in *" dm-verity-img "*) ;; *) skip verity "dm-verity-img not in IMAGE_CLASSES"; return;; esac
    img="$DEPLOY/$IMGBASE.ext4.verity"
    envf="$TMPDIR/work-shared/$MACHINE/dm-verity/core-image-minimal.ext4.verity.env"
    [ -e "$img" ] || { fail verity "no $img"; return; }
    [ -e "$envf" ] || { fail verity "no $envf"; return; }
    # shellcheck disable=SC1090
    . "$envf"
    native cryptsetup-native veritysetup verify \
        --data-block-size="$DATA_BLOCK_SIZE" --hash-block-size="$HASH_BLOCK_SIZE" --hash-offset="$DATA_SIZE" \
        "$img" "$img" "$ROOT_HASH" >/dev/null 2>&1 \
        || { fail verity "veritysetup verify failed for root hash $ROOT_HASH"; return; }
    # the root hash must travel inside the kernel image (bundled initramfs)
    [ "$(var INITRAMFS_IMAGE_BUNDLE)" = "1" ] || { fail verity "INITRAMFS_IMAGE_BUNDLE != 1"; return; }
    zcat "$DEPLOY"/dm-verity-image-initramfs-*.cpio.gz | grep -q "$ROOT_HASH" \
        || { fail verity "root hash not found in the bundled initramfs cpio"; return; }
    pass verity
}

check_optee() {
    case " $(var MACHINE_FEATURES) " in *" optee "*) ;; *) skip optee "optee not in MACHINE_FEATURES"; return;; esac
    # -s follows the symlink meta-imx-bsp deploys, so a dangling tee.bin fails here
    [ -s "$DEPLOY/tee.bin" ] || { fail optee "no non-empty $DEPLOY/tee.bin"; return; }
    [ -e "$DEPLOY/imx-boot" ] || { fail optee "no $DEPLOY/imx-boot for tee.bin to be folded into"; return; }
    pass optee
}

checks="baseline fit hab modsign rauc verity optee"

for c in $checks; do "check_$c"; done
exit $rc
