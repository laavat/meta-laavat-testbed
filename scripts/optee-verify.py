#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Laavat Oy
"""Verify each signed OP-TEE TA against the public key the TEE core embeds.

    optee-verify.py <ta-pub.pem> <file.ta> [file.ta ...]
    optee-verify.py --selfcheck          # round-trip this parser, no build tree needed

Exit 0: every TA's signature verifies under that key.  Exit 1: any of them does not
(that is the negative control too - flip a byte and this must exit 1).

The signed header is little-endian: magic 0x4F545348 at 0, img_type at 4, size at 8,
algo at 12 (0x70414930 = RSASSA-PSS/MGF1/SHA-256, 0x70004830 = PKCS#1 v1.5/SHA-256),
digest size at 16, signature size at 18.  Digest then signature follow, then the rest of
the file.  The signed data is header(20) || everything after the signature - which for a
bootstrap TA (img_type 1) sweeps in its UUID/version sub-header exactly as the service's
HASH(shdr || bootstrap_shdr || img) does, because the two are contiguous on disk."""
import hashlib
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

MAGIC = 0x4F545348
ALGO_PSS = 0x70414930


def verify(pub_pem, path):
    """(ok, detail) for one signed TA."""
    blob = Path(path).read_bytes()
    if len(blob) < 20 or struct.unpack_from("<I", blob, 0)[0] != MAGIC:
        return False, "not an OP-TEE signed image (bad magic)"
    algo, dig_size, sig_size = (struct.unpack_from("<I", blob, 12)[0],
                                struct.unpack_from("<H", blob, 16)[0],
                                struct.unpack_from("<H", blob, 18)[0])
    sig = blob[20 + dig_size:20 + dig_size + sig_size]
    img = blob[20 + dig_size + sig_size:]
    if len(sig) != sig_size or not img:
        return False, "truncated: header declares more than the file holds"
    digest = hashlib.sha256(blob[:20] + img).digest()
    pad = (["rsa_padding_mode:pss", "rsa_pss_saltlen:-1"] if algo == ALGO_PSS
           else ["rsa_padding_mode:pkcs1"])
    with tempfile.TemporaryDirectory() as d:
        h, s = Path(d, "h.bin"), Path(d, "s.bin")
        h.write_bytes(digest)
        s.write_bytes(sig)
        argv = ["openssl", "pkeyutl", "-verify", "-pubin", "-inkey", str(pub_pem),
                "-sigfile", str(s), "-in", str(h), "-pkeyopt", "digest:sha256"]
        for opt in pad:
            argv += ["-pkeyopt", opt]
        r = subprocess.run(argv, capture_output=True, text=True)
    what = "PSS" if algo == ALGO_PSS else "PKCS#1"
    if r.returncode != 0:
        return False, "%s: %s" % (what, (r.stderr or r.stdout).strip().splitlines()[-1])
    return True, "%s, %d-byte signature over sha256(hdr+img)" % (what, sig_size)


def selfcheck():
    """--selfcheck: round-trip a synthetic TA of each algorithm, plus a tamper.

    Only openssl, so it runs anywhere this script does.  Catches the byte
    offsets and the padding options going wrong without a build tree."""
    def sh(*a):
        subprocess.run(a, check=True, capture_output=True)
    with tempfile.TemporaryDirectory() as d:
        p = Path(d)
        sh("openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt",
           "rsa_keygen_bits:2048", "-out", str(p / "k.pem"))
        sh("openssl", "pkey", "-in", str(p / "k.pem"), "-pubout",
           "-out", str(p / "pub.pem"))
        img = b"bootstrap-hdr-20byte" + b"A" * 500
        for algo, opts in ((ALGO_PSS, ["rsa_padding_mode:pss", "rsa_pss_saltlen:-1"]),
                           (0x70004830, ["rsa_padding_mode:pkcs1"])):
            hdr = struct.pack("<IIIIHH", MAGIC, 1, len(img), algo, 32, 256)
            (p / "h.bin").write_bytes(hashlib.sha256(hdr + img).digest())
            argv = ["openssl", "pkeyutl", "-sign", "-inkey", str(p / "k.pem"),
                    "-in", str(p / "h.bin"), "-out", str(p / "s.bin"),
                    "-pkeyopt", "digest:sha256"]
            for o in opts:
                argv += ["-pkeyopt", o]
            sh(*argv)
            ta = hdr + (p / "h.bin").read_bytes() + (p / "s.bin").read_bytes() + img
            (p / "t.ta").write_bytes(ta)
            assert verify(p / "pub.pem", p / "t.ta")[0], "0x%08X must verify" % algo
            (p / "t.ta").write_bytes(ta[:-1] + bytes([ta[-1] ^ 1]))
            assert not verify(p / "pub.pem", p / "t.ta")[0], "tamper must fail"
    print("selfcheck OK: PSS and PKCS#1 round-trip, tamper rejected")


def main(argv):
    if argv[1:2] == ["--selfcheck"]:
        return selfcheck()
    if len(argv) < 3:
        sys.exit(__doc__.splitlines()[2].strip())
    pub, bad = argv[1], 0
    for path in argv[2:]:
        ok, detail = verify(pub, path)
        bad += not ok
        print("%-5s %s  (%s)" % ("PASS" if ok else "FAIL", path, detail))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
