# LAAVAT HAB signing, off unless LAAVAT_HAB_ARCHIVE = "1".
inherit ${@'laavat-hab' if d.getVar('LAAVAT_HAB_ARCHIVE') == '1' else ''}

# The one board fact: what the BSP calls the image it deploys. laavat-hab finds the built
# binary itself - meta-freescale composes that name inside do_compile and publishes no
# variable for it, so there is nothing here to reference even if we wanted to.
LAAVAT_HAB_DEPLOY_NAME = "${UUU_BOOTLOADER}"
