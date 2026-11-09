# Kernel .cfg fragments for the signing test-bed. linux-variscite inherits kernel-yocto
# (via meta-freescale linux-imx.inc), so .cfg files in SRC_URI are merged automatically.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Module signing (ephemeral key) — enabled by kas/modsign.yml via DISTRO_FEATURES.
SRC_URI += "${@bb.utils.contains('DISTRO_FEATURES', 'modsign', 'file://modsign.cfg', '', d)}"

# dm-verity — enabled by kas/verity.yml via IMAGE_CLASSES (meta-security convention).
SRC_URI += "${@bb.utils.contains('IMAGE_CLASSES', 'dm-verity-img', 'file://dm-verity.cfg', '', d)}"

# LAAVAT FIT signing, off unless LAAVAT_FIT_SIGN = "1" (kas/laavat/fit.yml). laavat-fitkey
# signs the copy u-boot verifies and puts the service's key in the control DTB; the u-boot
# recipe needs laavat-fitkey-uboot for the other half, on the same guard.
inherit ${@'laavat-fitkey' if d.getVar('LAAVAT_FIT_SIGN') == '1' else ''}
