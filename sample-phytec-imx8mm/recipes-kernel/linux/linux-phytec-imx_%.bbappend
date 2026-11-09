# LAAVAT FIT signing, off unless LAAVAT_FIT_SIGN = "1". INTEGRATION.md section 6: both
# halves are required, so the u-boot bbappend carries the same guard.
inherit ${@'laavat-fitkey' if d.getVar('LAAVAT_FIT_SIGN') == '1' else ''}
