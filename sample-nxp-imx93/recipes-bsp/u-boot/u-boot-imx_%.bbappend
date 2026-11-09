# The u-boot half of the FIT anchor - see the kernel bbappend.
inherit ${@'laavat-fitkey-uboot' if d.getVar('LAAVAT_FIT_SIGN') == '1' else ''}
