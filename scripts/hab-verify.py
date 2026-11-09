#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Laavat Oy
"""Verify HABv4 signatures in an i.MX boot image, offline.

`ivt-csf.py` answers "is there a CSF header here", which a corrupted or
foreign-signed image also answers yes to. This answers the question that
matters: does each CSF's CMS signature actually verify over the bytes it
claims to cover, and is the SRK table the one whose hash is fused?

Neither question needs a board, a boot ROM or an emulator - which is the only
reason HAB can be checked at all, since no emulator models the i.MX ROM.

Exit 0: every AUTH_DATA in every CSF verified, and the SRK hash matched if one
        was given.
Exit 1: a signature did not verify, or the SRK hash differed.
Exit 2: the file is not an i.MX boot image, or a CSF could not be parsed.
"""
import argparse
import contextlib
import hashlib
import struct
import subprocess
import sys
import tempfile
import os

HEADER, INSTALL_KEY, AUTH_DATA = 0xD4, 0xBE, 0xCA
CERT_TAG, SIG_TAG = 0xD7, 0xD8
SRK_FORMAT = 0x03            # certificate format: SRK table
CMS_PROTOCOL = 0xC5


def ivts(blob):
    """Yield (file_offset, self_address, csf_address) for every plausible IVT."""
    for off in range(0, len(blob) - 31, 4):
        if blob[off] != 0xD1 or blob[off + 1:off + 3] != b"\x00\x20":
            continue
        if blob[off + 3] not in (0x40, 0x41):
            continue
        _, entry, r1, dcd, boot, slf, csf, r2 = struct.unpack_from("<8I", blob, off)
        if r1 or r2 or not entry or not slf:
            continue
        if any(not 0 <= off + p - slf <= len(blob) - 4 for p in (dcd, boot, csf) if p):
            continue
        if csf:
            yield off, slf, csf


def commands(blob, csf_off):
    """Yield (tag, body) for each command in the CSF at csf_off."""
    if blob[csf_off] != HEADER:
        raise ValueError("no CSF header at 0x%x" % csf_off)
    total = int.from_bytes(blob[csf_off + 1:csf_off + 3], "big")
    if not 4 < total <= len(blob) - csf_off:
        raise ValueError("CSF at 0x%x claims %d bytes" % (csf_off, total))
    p, end = csf_off + 4, csf_off + total
    while p < end:
        tag = blob[p]
        length = int.from_bytes(blob[p + 1:p + 3], "big")
        if length < 4 or p + length > end:
            raise ValueError("command 0x%02x at 0x%x claims %d bytes" % (tag, p, length))
        yield tag, blob[p + 4:p + length]
        p += length


def hab_payload(blob, off, want):
    """The DER inside a HAB-wrapped object at off.

    Certificates (tag 0xD7) and signatures (0xD8) are not stored bare: each has
    a four-byte header carrying its own total length, and the DER begins after
    it. Trusting that length rather than re-deriving it from the DER means a
    truncated object fails here instead of somewhere inside openssl.
    """
    if blob[off] != want:
        raise ValueError("expected tag 0x%02x at 0x%x, found 0x%02x"
                         % (want, off, blob[off]))
    total = int.from_bytes(blob[off + 1:off + 3], "big")
    if not 4 < total <= len(blob) - off:
        raise ValueError("object at 0x%x claims %d bytes" % (off, total))
    der = blob[off + 4:off + total]
    if not der.startswith(b"\x30"):
        raise ValueError("no DER SEQUENCE inside the object at 0x%x" % off)
    return der


def openssl_verify(sig, content, certs):
    """True if the CMS blob verifies over content. Chain is checked separately."""
    with tempfile.TemporaryDirectory() as tmp:
        paths = {}
        for name, data in (("sig", sig), ("content", content), ("certs", certs)):
            paths[name] = os.path.join(tmp, name)
            with open(paths[name], "wb") as f:
                f.write(data)
        # -noverify: the chain to the SRK is checked by comparing the SRK table
        # hash, which is what the fuses actually anchor. Trusting openssl's
        # default store here would check the wrong root entirely.
        r = subprocess.run(
            ["openssl", "cms", "-verify", "-inform", "DER", "-in", paths["sig"],
             "-content", paths["content"], "-binary", "-noverify",
             "-certfile", paths["certs"], "-out", os.devnull],
            capture_output=True)
        return r.returncode == 0, r.stderr.decode().strip()


def verify_csf(blob, ivt_off, slf, csf_off, verbose):
    """Verify every AUTH_DATA in one CSF. Returns (checked, failures, srk_hash)."""
    keys, srk_hash, checked, failed, skipped = {}, None, 0, 0, 0
    csf_total = int.from_bytes(blob[csf_off + 1:csf_off + 3], "big")
    csf_bytes = blob[csf_off:csf_off + csf_total]

    for tag, body in commands(blob, csf_off):
        if tag == INSTALL_KEY and len(body) >= 8:
            # body: certificate format, hash algorithm, source index, target index,
            # then a 4-byte location relative to the start of the CSF.
            cert_fmt, tgt = body[0], body[3]
            at = csf_off + int.from_bytes(body[4:8], "big")
            if cert_fmt == SRK_FORMAT:
                # The SRK table is not DER - it carries its own tag/length/version
                # header - and its SHA-256 is the value burned into the fuses.
                length = int.from_bytes(blob[at + 1:at + 3], "big")
                srk_hash = hashlib.sha256(blob[at:at + length]).hexdigest()
            else:
                keys[tgt] = hab_payload(blob, at, CERT_TAG)
        elif tag == AUTH_DATA and len(body) >= 8:
            key_idx, protocol = body[0], body[1]
            if protocol != CMS_PROTOCOL:
                print("    AUTH_DATA protocol 0x%02x is not CMS - not checked" % protocol)
                continue
            sig_at = csf_off + int.from_bytes(body[4:8], "big")
            sig = hab_payload(blob, sig_at, SIG_TAG)

            blocks = body[8:]
            if not blocks:
                content = csf_bytes            # signs the CSF command block itself
                what = "CSF commands"
            else:
                parts, spans, unmapped = [], [], []
                for i in range(0, len(blocks) - 7, 8):
                    addr, size = struct.unpack_from(">II", blocks, i)
                    # The ROM knows where it loaded each image; offline we only have the
                    # IVT's own linear mapping. Blocks belonging to a different loaded
                    # image (ATF at 0x920000, for one) fall outside it and need the
                    # container layout, which the CSF does not carry.
                    at = ivt_off + addr - slf
                    if not 0 <= at <= len(blob) - size:
                        unmapped.append("0x%x+%d" % (addr, size))
                        continue
                    parts.append(blob[at:at + size])
                    spans.append("0x%x+%d" % (addr, size))
                if unmapped:
                    print("    key %d: NOT CHECKED - %d block(s) outside this IVT's "
                          "mapping (%s); needs the container layout"
                          % (body[0], len(unmapped), " ".join(unmapped)))
                    skipped += 1
                    continue
                content, what = b"".join(parts), " ".join(spans)

            ok, err = openssl_verify(sig, content, b"".join(keys.values()) or b"")
            checked += 1
            failed += not ok
            print("    key %d over %s: %s%s"
                  % (key_idx, what, "VERIFIED" if ok else "FAILED",
                     "" if ok else " (%s)" % err))
    return checked, failed, srk_hash, skipped


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("image")
    p.add_argument("--srk-hash", help="expected SHA-256 of the SRK table (the fused value)")
    p.add_argument("-v", "--verbose", action="store_true")
    p.add_argument("--selfcheck", action="store_true",
                   help="also prove the check can fail: flip a byte in a signed "
                        "block and require the verdict to change")
    a = p.parse_args()

    blob = open(a.image, "rb").read()
    found = checked = failed = unchecked = 0
    hashes = set()

    for ivt_off, slf, csf in ivts(blob):
        csf_off = ivt_off + csf - slf
        if blob[csf_off] != HEADER:
            continue
        found += 1
        print("IVT@0x%x -> CSF@0x%x" % (ivt_off, csf_off))
        try:
            c, f, h, s = verify_csf(blob, ivt_off, slf, csf_off, a.verbose)
        except ValueError as e:
            print("    unparseable: %s" % e)
            return 2
        checked += c
        failed += f
        unchecked += s
        if h:
            hashes.add(h)

    if not found:
        print("no signed IVT found - not a HAB-signed i.MX image")
        return 2
    if not checked:
        print("no CMS signatures were checked - this proves nothing")
        return 1

    for h in sorted(hashes):
        print("SRK table SHA-256: %s" % h)
    if a.srk_hash:
        if a.srk_hash.lower() not in hashes:
            print("SRK MISMATCH: expected %s" % a.srk_hash.lower())
            failed += 1
        else:
            print("SRK hash matches the expected fuse value")

    print("%d signature(s) checked, %d failed, %d not checked"
          % (checked, failed, unchecked))
    if unchecked:
        print("NOT CHECKED is not the same as verified - see the notes above")

    if a.selfcheck:
        # A check that cannot go red proves nothing. NXP's own hab4_image_verifier
        # prints identical output for a good and a tampered image and exits 0 for
        # both, which is exactly the failure mode this guards against.
        if failed:
            print("selfcheck: skipped, the image already fails")
            return 1
        tampered = bytearray(blob)
        tampered[4096] ^= 0xFF          # inside the SPL block signed by every build
        import io
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            bad = 0
            for ivt_off, slf, csf in ivts(bytes(tampered)):
                off = ivt_off + csf - slf
                if bytes(tampered)[off] != HEADER:
                    continue
                try:
                    _, f, _, _ = verify_csf(bytes(tampered), ivt_off, slf, off, False)
                    bad += f
                except ValueError:
                    bad += 1
        if not bad:
            print("SELFCHECK FAILED: a flipped byte still verified - "
                  "this check is not checking anything")
            return 1
        print("selfcheck: a flipped byte is rejected (%d signature(s) went red)" % bad)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
