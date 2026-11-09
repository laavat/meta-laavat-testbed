# LAAVAT FIT signing, off unless LAAVAT_FIT_SIGN = "1". Identical to the i.MX tiers: the
# class knows about FIT images, not about who made the SoC.
inherit ${@'laavat-fitkey' if d.getVar('LAAVAT_FIT_SIGN') == '1' else ''}
