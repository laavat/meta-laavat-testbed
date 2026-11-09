# LAAVAT TA signing, off unless LAAVAT_OPTEE_SIGN = "1".
#
# Inert on zynqmp-generic and kept anyway. meta-xilinx scarthgap enables OP-TEE for the
# Versal 2VE/2VM family only - optee-os-amd.inc sets COMPATIBLE_MACHINE for that and
# nothing else - so on ZynqMP the recipe is skipped and this bbappend matches a recipe that
# is never built. That is not an error (a bbappend dangles only when no .bb file matches by
# name), and it means the line is already correct for anyone moving this layer to Versal.
inherit ${@'laavat-optee' if d.getVar('LAAVAT_OPTEE_SIGN') == '1' else ''}
