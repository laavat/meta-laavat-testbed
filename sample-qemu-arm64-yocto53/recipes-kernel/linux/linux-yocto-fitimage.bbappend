# LAAVAT FIT signing on Yocto 5.3+, off unless LAAVAT_FIT_SIGN = "1".
#
# laavat-fitimage rather than laavat-fitkey, and on this recipe rather than on the kernel:
# 5.3 replaced kernel-fitimage.bbclass with kernel-fit-image.bbclass and gave the FIT its
# own recipe. The u-boot half is unchanged.
inherit ${@'laavat-fitimage' if d.getVar('LAAVAT_FIT_SIGN') == '1' else ''}
