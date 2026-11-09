# Xilinx boot-image signing, off unless LAAVAT_BOOTGEN_SIGN = "1".
#
# This completes the chain on this SoC. The FIT and RAUC halves protect the kernel and the
# update bundle; this one covers the first-stage boot image, which on ZynqMP is bootgen's
# job rather than a boot ROM's IVT.
#
# One line and nothing else: xilinx-bootbin generates its BIF during do_configure and
# stages every partition that BIF names into ${B}, which is exactly what laavat-bootgen
# reads. The stock recipe needs no LAAVAT_BOOTGEN_* overrides at all.
inherit ${@'laavat-bootgen' if d.getVar('LAAVAT_BOOTGEN_SIGN') == '1' else ''}
