# LAAVAT FIT signing, off unless LAAVAT_FIT_SIGN = "1". The u-boot half is in
# recipes-bsp/u-boot/, on the same recipe that carries HAB.
inherit ${@'laavat-fitkey' if d.getVar('LAAVAT_FIT_SIGN') == '1' else ''}
