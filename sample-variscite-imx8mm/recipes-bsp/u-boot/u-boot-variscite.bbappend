# The u-boot half of laavat-fitkey, on the same guard as the kernel half - enabled apart,
# either would sign against a key the other side does not hold. This board's U-Boot appends
# its own control device tree, so unlike qemuarm64-secureboot (which sets OF_BOARD and
# refuses to build one - U-Boot's own check-of.sh enforces that) poky's concat_dtb really
# runs here, and with it the key injection.
inherit ${@'laavat-fitkey-uboot' if d.getVar('LAAVAT_FIT_SIGN') == '1' else ''}
