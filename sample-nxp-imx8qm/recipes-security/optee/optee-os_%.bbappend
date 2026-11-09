# LAAVAT TA signing, off unless LAAVAT_OPTEE_SIGN = "1".
inherit ${@'laavat-optee' if d.getVar('LAAVAT_OPTEE_SIGN') == '1' else ''}
