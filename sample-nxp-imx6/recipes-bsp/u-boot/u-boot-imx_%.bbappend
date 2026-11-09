# On i.MX6 this one recipe is BOTH the HAB target and the FIT anchor. Every tier before
# this had them on different recipes (imx-boot signs, u-boot-imx anchors), because i.MX8M
# builds a two-stage flash.bin. i.MX6 with u-boot-imx has no SPL and no imx-boot at all:
#
#     SPL_BINARY:pn-u-boot-imx        = ""
#     UBOOT_MAKE_TARGET:pn-u-boot-imx = "u-boot.imx"
#
# The two classes do not collide - laavat-fitkey-uboot only asserts on a file the kernel
# recipe produced and needs no product of its own - so the recipe carries one product id,
# for HAB.

# LAAVAT HAB signing, off unless LAAVAT_HAB_ARCHIVE = "1".
inherit ${@'laavat-hab' if d.getVar('LAAVAT_HAB_ARCHIVE') == '1' else ''}

# The u-boot half of the FIT anchor - see the kernel bbappend.
inherit ${@'laavat-fitkey-uboot' if d.getVar('LAAVAT_FIT_SIGN') == '1' else ''}

# Three board facts, all consequences of the single-stage layout.
#
# oe-core's u-boot.inc builds each UBOOT_CONFIG into its own directory
# (`oe_runmake -C ${S} O=${B}/${config}`), so the artifact is ${B}/sd/u-boot.imx.
# Naming it explicitly rather than searching: if MACHINE_FEATURES gains optee this
# machine's UBOOT_CONFIG becomes "sd sd-optee" and builds two of them, one per directory.
LAAVAT_HAB_IMAGE = "${B}/sd/${UBOOT_BINARY}"

# One IVT, not two. The default "SPL UBOOT" is the i.MX8M shape and fails here with
# "the image has 1 HAB IVTs but 2 stages were named", which is the right way to fail.
LAAVAT_HAB_STAGES = "UBOOT"

# The archive member, and therefore the deployed name, is u-boot.imx rather than flash.bin.
LAAVAT_ARCHIVE_MEMBER = "${UBOOT_BINARY}"
