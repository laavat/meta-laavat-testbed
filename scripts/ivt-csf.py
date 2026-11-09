#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Laavat Oy
"""Scan FILE for HABv4 IVTs and check that every one with a CSF pointer really is signed.

Exit 0: >=2 IVTs found, at least one has a CSF pointer, and every such IVT has a CSF header
        at its CSF address (image is HAB-signed).
Exit 1: some IVT with a CSF pointer has no CSF header there (unsigned build product).
Exit 2: no IVT at file offset 0 (not an i.MX boot image at all).

IVT = tag 0xD1, length 0x0020 big-endian, version 0x40/0x41, then 7 LE words:
entry, reserved1, dcd, boot_data, self, csf, reserved2.  Each IVT describes one image loaded
at its own address, so a pointer maps to file offset `ivt_offset + (pointer - self)`
(imx-boot for i.MX8M holds three: SPL in OCRAM plus two U-Boot-proper IVTs in DRAM).
The CSF *pointer* is no evidence: imx-mkimage fills it even when unsigned because it reserves
the CSF area.  Only a CSF header at that address is: tag 0xD4, big-endian length that fits in
the file, version 0x4x (0x43 in practice).

Twin of laavat.imx_ivt.hab_blocks, which parses the same header to decide what to sign; kept
separate because make verify runs for kas/hab.yml, where layers-50/meta-laavat does not exist."""
import struct
import sys

blob = open(sys.argv[1], "rb").read()


def ivt_at(off):
    """(self, csf) if a plausible IVT starts at off, else None."""
    if blob[off] != 0xD1 or blob[off + 1:off + 3] != b"\x00\x20" or blob[off + 3] not in (0x40, 0x41):
        return None
    _, entry, res1, dcd, boot, slf, csf, res2 = struct.unpack_from("<8I", blob, off)
    if res1 or res2 or not entry or not slf:
        return None
    # every non-zero pointer must land inside the file — kills random 0xD1 matches
    if any(not 0 <= off + p - slf <= len(blob) - 4 for p in (dcd, boot, csf) if p):
        return None
    return slf, csf


def csf_hdr(off):
    """4-byte CSF header at file offset off, or b'' if there is no valid one."""
    hdr = blob[off:off + 4]
    ok = (len(hdr) == 4 and hdr[0] == 0xD4 and hdr[3] & 0xF0 == 0x40
          and 0 < int.from_bytes(hdr[1:3], "big") <= len(blob) - off)
    return hdr if ok else b""


if len(blob) < 32 or not ivt_at(0):
    print("no IVT at offset 0")
    sys.exit(2)

found = signed = unsigned = 0
for off in range(0, len(blob) - 31, 4):
    ivt = ivt_at(off)
    if not ivt:
        continue
    found += 1
    slf, csf = ivt
    hdr = csf_hdr(off + csf - slf) if csf else b""
    print("ivt@0x%x csf=0x%x csf_hdr=%s" % (off, csf, hdr.hex() or "-"))
    if csf:
        signed += bool(hdr)
        unsigned += not hdr

sys.exit(0 if found >= 2 and signed and not unsigned else 1)
