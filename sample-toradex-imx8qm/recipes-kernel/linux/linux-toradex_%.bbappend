# LAAVAT FIT signing, off unless LAAVAT_FIT_SIGN = "1". Toradex's own kernel recipe, and
# the class does not care.
inherit ${@'laavat-fitkey' if d.getVar('LAAVAT_FIT_SIGN') == '1' else ''}
