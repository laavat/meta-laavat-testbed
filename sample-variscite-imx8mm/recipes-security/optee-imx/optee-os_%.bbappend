# LAAVAT TA signing, off unless LAAVAT_OPTEE_SIGN = "1" (kas/laavat/optee.yml).
# One conditional inherit, so with it off the recipe gains no laavat variable, task or
# dependency whatsoever. Everything else - the pubkey anchor, the pack/sign/unpack
# tasks - is meta-laavat's laavat-optee.bbclass; nothing here is board-specific.
inherit ${@'laavat-optee' if d.getVar('LAAVAT_OPTEE_SIGN') == '1' else ''}
