# FIT verified boot on qemuarm64-secureboot. Only applies where the fragment is wanted;
# LAAVAT_FIT_BOOT gates it so the i.MX tier's U-Boot is untouched.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "${@' file://laavat-fit.cfg' if d.getVar('LAAVAT_FIT_BOOT') == '1' else ''}"

# The other half of laavat-fitkey: inject the service's key into the control DTB instead of
# re-signing the FIT with a key the service does not hold. Gated with the kernel's own guard
# so the two halves can never be enabled apart.
inherit ${@'laavat-fitkey-uboot' if d.getVar('LAAVAT_FIT_SIGN') == '1' else ''}

