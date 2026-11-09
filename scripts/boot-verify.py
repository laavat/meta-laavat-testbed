#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Laavat Oy
"""Boot a built image under runqemu and check what the serial log says.

The assertions live in the image (laavat-boot-check), which prints one
`LAAVAT-CHECK: <name> PASS|FAIL <detail>` line per check. This script only
boots, captures and parses - no interactive expect driver. That is deliberate:
the same checks then run by hand on a board, unchanged, and a fragile
send/expect conversation is not standing between the evidence and the verdict.

Boot-level facts come from the log itself, before any userspace runs: U-Boot's
FIT verification and OP-TEE's core initialisation are printed by the firmware.

Exit 0 only if every required check appeared and passed, every required boot
marker was seen, and the image reached its completion marker.
"""
import argparse
import os
import re
import signal
import subprocess
import sys
import time

CHECK = re.compile(r"LAAVAT-CHECK: (\S+) (PASS|FAIL) ?(.*)")
DONE = "LAAVAT-CHECK-COMPLETE"

# Firmware-level evidence, matched case-insensitively against the serial log.
# Absence is a failure when the marker is required: a boot that never mentions
# verifying the FIT did not verify it.
# "uboot-fit-verified" is filled in from --fit-key-name at startup, because the only line that
# proves anything names the key: U-Boot prints "Verifying Hash Integrity ... sha256+ OK" for the
# plain hash node of every subimage, signed or not, so a pattern that accepts it passes on an
# image with no signature at all.
MARKERS = {
    "uboot-fit-verified": None,   # set by set_fit_markers()
    "optee-initialised": r"OP-TEE version|optee: initialized driver",
    # The kernel body is covered by the hash node; the CONFIGURATION signature covers the hash
    # values. They fail differently and are different claims, so keep them apart: a tampered
    # body with a stale hash trips the first, a tampered body whose hash was recomputed trips
    # the second, and only the second says the signature is doing any work.
    "uboot-fit-hash-refused": r"Bad Data Hash|Bad hash value"
                              r"|Verifying Hash Integrity.*(FAILED|error)|Bad Data|bad hash",
    "uboot-fit-sig-refused": r"signature check failed|Failed to verify required signature"
                             r"|Verifying Hash Integrity \.\.\. [\w,]+:\w+- ",
}
# Kept so existing callers and docs that say "uboot-fit-refused" still mean "refused somehow".
MARKERS["uboot-fit-refused"] = (MARKERS["uboot-fit-hash-refused"] + "|"
                                + MARKERS["uboot-fit-sig-refused"])


def set_fit_markers(key_name):
    """Require the signature line that names the key, not the hash line that names nothing."""
    MARKERS["uboot-fit-verified"] = (
        r"Verifying Hash Integrity \.\.\. [\w,]+:%s\+ OK" % re.escape(key_name))


def run(cmd, what):
    """Run a helper, failing loudly. Never through a pipe - see boot()."""
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("%s failed (exit %d):\n%s%s" % (what, r.returncode, r.stdout, r.stderr))
    return r.stdout


def prepare_control_dtb(machine, keydir, keyname, hash_alg, sign_alg, out_dir):
    """Build the control device tree QEMU passes, carrying the service's FIT key.

    qemuarm64-secureboot sets OF_BOARD, so U-Boot takes its control device tree from
    QEMU and never reads the one the build signed into u-boot.dtb. That is a property
    of this emulated machine, not of signing, so the workaround lives here rather than
    in meta-laavat.

    The tree is dumped through runqemu itself, with the same arguments that will boot
    it. Composing a qemu command line by hand here would let the tree describe a
    different machine - different memory, different cpu count - than the one it is
    later handed to, and the mismatch would surface as an unbootable image rather than
    as an error.
    """
    os.makedirs(out_dir, exist_ok=True)
    raw = os.path.join(out_dir, "control-raw.dtb")
    dtb = os.path.join(out_dir, "control.dtb")

    # QEMU writes the tree and exits, so this boots nothing.
    run(["runqemu", machine, "nographic", "slirp",
         "qemuparams=-machine dumpdtb=%s" % raw], "dumping the machine device tree")
    if not os.path.exists(raw):
        sys.exit("runqemu did not write %s; the machine may not support dumpdtb" % raw)

    # QEMU declares a 1 MB totalsize that TF-A rejects with "Invalid Device Tree".
    # Round-tripping through dtc rewrites the header to the real size.
    run(["oe-run-native", "dtc-native", "dtc", "-I", "dtb", "-O", "dtb", "-p", "8192",
         raw, "-o", dtb], "normalising the device tree")
    run(["oe-run-native", "u-boot-tools-native", "fdt_add_pubkey",
         "-a", "%s,%s" % (hash_alg, sign_alg), "-k", keydir, "-n", keyname,
         "-r", "conf", dtb], "adding the FIT verification key")
    print("control device tree: %s carries %s from %s" % (dtb, keyname, keydir))
    return dtb


def prepare_bundle_disk(deploy_dir, out_dir, ta_tamper=False):
    """Assemble the vfat disk the in-image bundle checks read.

    The bundle cannot live in the rootfs - it contains that rootfs - so it arrives as a
    second virtio disk. Both halves of the pair go on it: the service-signed bundle the
    device must accept, and the dev-key-signed one it must refuse. Deploying the signed
    bundle as a sidecar rather than in place is what makes that pair available; for RAUC,
    unlike the kernel, the sidecar is the point.
    """
    import glob

    os.makedirs(out_dir, exist_ok=True)
    signed = glob.glob(os.path.join(deploy_dir, "*.raucb.laavat-signed"))
    # The deploy directory holds both a versioned bundle and a symlink to it; either
    # reads the same, so take the first stable name rather than guessing.
    devkey = sorted(b for b in glob.glob(os.path.join(deploy_dir, "*.raucb"))
                    if os.path.isfile(b))
    if not signed:
        sys.exit("no *.raucb.laavat-signed in %s: the bundle was never service-signed, so "
                 "the positive control cannot be built" % deploy_dir)
    if not devkey:
        sys.exit("no *.raucb in %s: without the dev-key bundle there is no negative control, "
                 "and bundle-verify alone cannot show the keyring discriminates" % deploy_dir)

    # A third copy, service-signed but with its signature corrupted. Refusing the dev-key
    # bundle shows the keyring is right; refusing this one shows the signature is actually
    # *verified* rather than merely present and well-formed.
    #
    # Corrupting the payload would not do it. A RAUC verity bundle's CMS covers the manifest,
    # which carries the dm-verity root hash; payload corruption is caught by verity when the
    # data is read at install time, not by `rauc info`. So aim at the signature itself, whose
    # position the format states exactly: the bundle ends with the CMS followed by an 8-byte
    # big-endian length of that CMS.
    tampered = os.path.join(out_dir, "tampered.raucb")
    with open(signed[0], "rb") as f:
        blob = bytearray(f.read())
    sig_len = int.from_bytes(blob[-8:], "big")
    if not 0 < sig_len < len(blob) - 8:
        sys.exit("%s ends with an implausible signature length (%d); refusing to corrupt a "
                 "byte at a guessed offset, which would make this check meaningless"
                 % (signed[0], sig_len))
    pos = len(blob) - 8 - sig_len // 2
    blob[pos] ^= 0xFF
    with open(tampered, "wb") as f:
        f.write(blob)
    print("tampered bundle: flipped one byte inside the %d-byte CMS signature" % sig_len)

    img = os.path.join(out_dir, "bundle-disk.img")
    # mkfs.vfat -C refuses to write over an existing file, so a second run would fail on the
    # previous run's disk rather than rebuild it.
    if os.path.exists(img):
        os.unlink(img)
    # vfat needs headroom beyond the payload, and mkfs sizes in KiB.
    kb = (os.path.getsize(signed[0]) * 2 + os.path.getsize(devkey[0])) // 1024 + 16384
    run(["oe-run-native", "dosfstools-native", "mkfs.vfat", "-C", img, str(kb)],
        "creating the bundle disk")
    files = [(signed[0], "bundle.raucb"), (devkey[0], "devkey.raucb"),
             (tampered, "tampered.raucb")]
    if ta_tamper:
        # The image reads this marker and then runs ONLY the TA tamper check. That check has
        # to corrupt the TA before anything loads it - a resident copy is served instead,
        # and the corrupted file is accepted - while refusing it sometimes oopses
        # tee-supplicant and wedges every later TA check. One boot cannot do both.
        marker = os.path.join(out_dir, "laavat-ta-tamper")
        open(marker, "w").close()
        files.append((marker, "laavat-ta-tamper"))
    for src, name in files:
        run(["oe-run-native", "mtools-native", "mcopy", "-i", img, src, "::" + name],
            "copying %s onto the bundle disk" % name)
    print("bundle disk: %s carries %s, %s and a tampered copy"
          % (img, os.path.basename(signed[0]), os.path.basename(devkey[0])))
    return img


def _gpt_part(wic, index):
    """Return (byte offset, byte length) of a GPT partition, 1-based."""
    with open(wic, "rb") as f:
        f.seek(512)
        hdr = f.read(92)
        if hdr[:8] != b"EFI PART":
            sys.exit("%s has no GPT header; cannot find the boot partition" % wic)
        entries_lba = int.from_bytes(hdr[72:80], "little")
        entry_size = int.from_bytes(hdr[84:88], "little")
        f.seek(entries_lba * 512 + (index - 1) * entry_size)
        e = f.read(entry_size)
    first = int.from_bytes(e[32:40], "little")
    last = int.from_bytes(e[40:48], "little")
    if not first:
        sys.exit("%s has no partition %d" % (wic, index))
    return first * 512, (last - first + 1) * 512


def tamper_fit(deploy_dir, out_dir):
    """Corrupt the kernel FIT on a copy of the boot disk, and return that copy.

    The point is a claim the positive tests cannot make: that U-Boot's verification covers
    the kernel's *contents*, not merely that a signature is present and the key matches. So
    this flips one byte well inside the image and expects the boot to stop.

    The byte is flipped in place, at the offset ext4 says the file occupies, rather than by
    rewriting the file - that keeps every other byte of the disk identical, so a boot that
    now fails can only have failed because of this byte.
    """
    import glob
    import shutil

    os.makedirs(out_dir, exist_ok=True)
    # Exclude a previous run's tampered disk, which now lives in this same directory: using
    # it as the source would corrupt an already-corrupted image and prove nothing.
    wics = [w for w in glob.glob(os.path.join(deploy_dir, "*.wic"))
            if os.path.isfile(w) and "laavat-tampered" not in os.path.basename(w)]
    if not wics:
        sys.exit("no *.wic in %s: nothing to tamper with" % deploy_dir)
    src_wic = sorted(wics)[0]
    # The tampered disk goes in the deploy directory, not out_dir. runqemu derives
    # DEPLOY_DIR_IMAGE from wherever the rootfs sits and then looks for the kernel beside
    # it, so a disk anywhere else fails with "KERNEL not found" before the machine starts.
    # The basename must also contain "-image-" or ".rootfs." or runqemu rejects the path
    # outright (scripts/runqemu, check_arg_path).
    wic = os.path.join(deploy_dir, "laavat-tampered-image.rootfs.wic")
    shutil.copyfile(src_wic, wic)
    # runqemu resolves a rootfs path by looking for a sibling <name>.qemuboot.conf, and
    # rejects the file outright without one ("Unknown path arg"). Copying the real image's
    # conf beside the tampered disk is what makes runqemu boot this disk rather than refuse
    # to start - and a machine that never starts would make the "did not boot" assertion
    # below true for entirely the wrong reason.
    src_conf = re.sub(r"\.wic$", ".qemuboot.conf", src_wic)
    if not os.path.exists(src_conf):
        sys.exit("%s has no matching .qemuboot.conf; runqemu cannot boot the tampered disk"
                 % src_wic)
    shutil.copyfile(src_conf,
                    os.path.join(deploy_dir, "laavat-tampered-image.rootfs.qemuboot.conf"))

    off, length = _gpt_part(wic, 1)
    part = os.path.join(out_dir, "boot-part.img")
    with open(wic, "rb") as src, open(part, "wb") as dst:
        src.seek(off)
        dst.write(src.read(length))

    # Block size from the ext4 superblock: s_log_block_size at 0x18, block size = 1024 << it.
    with open(part, "rb") as f:
        f.seek(1024 + 0x18)
        bs = 1024 << int.from_bytes(f.read(4), "little")

    out = run(["oe-run-native", "e2fsprogs-native", "debugfs", "-R", "blocks /fitImage", part],
              "listing the FIT's blocks")
    # debugfs prints the block list, sometimes preceded by a header or a warning, so take
    # only the numeric tokens rather than assuming the whole output is numbers.
    blocks = [int(b) for b in out.split() if b.isdigit()]
    if len(blocks) < 32:
        sys.exit("/fitImage occupies %d blocks; that is not the kernel image"
                 % len(blocks))
    # Well past the FIT header and into the kernel payload, so the failure is a failed hash
    # rather than a malformed image that U-Boot rejects before checking anything.
    target = off + blocks[len(blocks) // 2] * bs

    with open(wic, "r+b") as f:
        f.seek(target)
        byte = f.read(1)
        f.seek(target)
        f.write(bytes([byte[0] ^ 0xFF]))
    print("tampered %s: flipped one byte at 0x%x, inside /fitImage's payload" % (wic, target))
    return wic


def boot(cmd, timeout, path, until=None):
    """Run runqemu, streaming to `path`; return what it wrote.

    Two things this has to get right, both learned by getting them wrong:

    Output goes straight to a file, never through a pipe. runqemu spawns
    qemu-system as a grandchild that inherits the pipe, so a pipe-based read
    blocks on the survivor long after runqemu itself is gone.

    And the timeout kills the whole process group, not just runqemu. Killing
    runqemu alone leaves qemu-system running: the boot never ends and nothing
    reports that it did not.

    `until` ends the boot as soon as the image says it is finished. Nothing powers the
    machine off after its checks, so without this every boot sat idle until the timeout -
    a quarter of an hour of nothing, on every run.
    """
    def stop(proc):
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            proc.kill()
        proc.wait(timeout=30)

    with open(path, "w") as f:
        proc = subprocess.Popen(cmd, stdout=f, stderr=subprocess.STDOUT,
                                start_new_session=True)
        deadline = time.time() + timeout
        while True:
            try:
                proc.wait(timeout=5)
                break
            except subprocess.TimeoutExpired:
                pass
            if until:
                with open(path, errors="replace") as seen:
                    if until in seen.read():
                        stop(proc)
                        break
            if time.time() >= deadline:
                stop(proc)
                f.write("\n*** runqemu process group killed after %ds ***\n" % timeout)
                break
    with open(path, errors="replace") as f:
        return f.read()


def report(log, require_checks, require_markers, expect_no_boot=False):
    """Print every verdict; return the number of failures, missing included."""
    failed, seen = 0, {}

    for name, verdict, detail in CHECK.findall(log):
        seen[name] = verdict
        print("  %-22s %s  %s" % (name, verdict, detail.strip()[:60]))
        if verdict == "FAIL":
            failed += 1

    for name in require_checks:
        if name not in seen:
            print("  %-22s MISSING  (required, never printed)" % name)
            failed += 1

    for name in require_markers:
        pattern = MARKERS.get(name)
        if pattern is None:
            print("  %-22s UNKNOWN MARKER" % name)
            failed += 1
        elif re.search(pattern, log, re.I):
            print("  %-22s PASS     (firmware log)" % name)
        else:
            print("  %-22s MISSING  (firmware never said it)" % name)
            failed += 1

    if expect_no_boot:
        # Inverted: the image must NOT have run. Reaching userspace at all would mean the
        # bootloader accepted a kernel whose contents had been altered.
        #
        # But "did not reach userspace" is also true when the machine never started, so
        # require evidence that it did. Without this the check passed on a run where runqemu
        # had refused the disk and no CPU ever executed.
        if not re.search(r"U-Boot|NOTICE:\s+BL", log):
            print("  %-22s FAIL     (the machine never started, so nothing was proved)"
                  % "fit-tamper-refused")
            failed += 1
        elif DONE in log:
            print("  %-22s FAIL     (tampered kernel booted all the way to userspace)"
                  % "fit-tamper-refused")
            failed += 1
        else:
            print("  %-22s PASS     (tampered kernel never reached userspace)"
                  % "fit-tamper-refused")
    elif DONE not in log:
        print("  %-22s MISSING  (image never finished its checks)" % DONE)
        failed += 1
    return failed


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--machine", default="qemuarm64-secureboot")
    p.add_argument("--timeout", type=int, default=900)
    p.add_argument("--require", default="",
                   help="comma-separated LAAVAT-CHECK names that MUST pass")
    p.add_argument("--require-markers", default="",
                   help="comma-separated firmware markers: %s" % ",".join(MARKERS))
    p.add_argument("--log", default="build/logs/boot.log")
    p.add_argument("--qemuparams", default="",
                   help="extra QEMU arguments, e.g. an update-bundle disk to verify")
    p.add_argument("--fit-key-dir",
                   help="build a control device tree carrying the FIT verification key "
                        "from this directory and boot with it (see prepare_control_dtb)")
    p.add_argument("--tamper-fit", metavar="DEPLOY_DIR",
                   help="corrupt the kernel FIT on a copy of the boot disk, boot that, and "
                        "require the boot to stop before userspace")
    p.add_argument("--ta-tamper", action="store_true",
                   help="mark the bundle disk so the image runs only the TA tamper check, "
                        "in a boot of its own")
    p.add_argument("--bundle-disk", metavar="DEPLOY_DIR",
                   help="assemble the update-bundle disk from this deploy directory and "
                        "attach it, so the RAUC checks have something to verify")
    p.add_argument("--fit-key-name", default="laavat",
                   help="key name in --fit-key-dir (default: laavat)")
    p.add_argument("--fit-hash-alg", default="sha256")
    p.add_argument("--fit-sign-alg", default="rsa2048")
    a = p.parse_args()

    # nographic + slirp: no display, no tun/tap, and the machine forces KVM off,
    # so this needs no privileges and runs in any CI container.
    set_fit_markers(a.fit_key_name)
    qemuparams = a.qemuparams
    if a.fit_key_dir:
        dtb = prepare_control_dtb(a.machine, a.fit_key_dir, a.fit_key_name,
                                  a.fit_hash_alg, a.fit_sign_alg,
                                  os.path.join(os.path.dirname(a.log) or ".", "dtb"))
        qemuparams = ("%s -dtb %s" % (qemuparams, dtb)).strip()
    if a.bundle_disk:
        img = prepare_bundle_disk(a.bundle_disk,
                                  os.path.join(os.path.dirname(a.log) or ".", "disk"),
                                  ta_tamper=a.ta_tamper)
        qemuparams = ("%s -drive file=%s,if=virtio,format=raw"
                      % (qemuparams, img)).strip()

    disk = None
    if a.tamper_fit:
        disk = tamper_fit(a.tamper_fit, os.path.join(os.path.dirname(a.log) or ".", "tamper"))

    # snapshot: runqemu otherwise boots the DEPLOYED qcow2 read-write, so every boot mutates the
    # image the next one starts from - the TA-tamper boot's corruption, the TEE's REE-FS state and
    # the journal all persist. That makes results order-dependent: re-running this boot after the
    # tamper boot loaded mutated TA state and oopsed tee-supplicant, taking every userspace check
    # with it. Writes still work inside a boot (the tamper needs them); they go to an overlay that
    # is discarded at power-off, so each boot starts from the image that was built.
    cmd = ["runqemu", a.machine, "nographic", "slirp", "snapshot"]
    if disk:
        cmd.append(disk)
    if qemuparams:
        cmd.append("qemuparams=%s" % qemuparams)
    print("booting: %s" % " ".join(cmd))
    # The tampered boot has no completion marker to wait for - it must not reach one.
    log = boot(cmd, a.timeout, a.log, until=None if a.tamper_fit else DONE)
    print("serial log: %s (%d bytes)\n" % (a.log, len(log)))

    failed = report(log,
                    [c for c in a.require.split(",") if c],
                    [m for m in a.require_markers.split(",") if m],
                    expect_no_boot=bool(a.tamper_fit))
    print("\n%s" % ("FAILED %d check(s)" % failed if failed else "all checks passed"))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
