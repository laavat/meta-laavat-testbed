# LAAVAT HAB signing, off unless LAAVAT_HAB_ARCHIVE = "1".
inherit ${@'laavat-hab' if d.getVar('LAAVAT_HAB_ARCHIVE') == '1' else ''}

# This machine leaves BOTH selectors multi-valued - UBOOT_CONFIG "fspi sd" and
# IMXBOOT_TARGETS "flash_evk flash_evk_flexspi" - and do_compile is a nested loop over
# them, so it builds FOUR boot images. laavat-hab therefore cannot auto-detect and we must
# name one; it warns about the three it leaves unsigned.
#
# This is the one the BSP itself points at: do_deploy links ${BOOT_NAME} to the last
# UBOOT_CONFIG with the first IMXBOOT_TARGETS, i.e. sd + flash_evk.
LAAVAT_HAB_IMAGE = "${S}/${BOOT_NAME}-${MACHINE}-sd.bin-flash_evk"

# UUU_BOOTLOADER is unset here - it is not the meta-freescale guarantee the EVK made it
# look like - so the deployed name comes from the recipe's own BOOT_NAME.
LAAVAT_HAB_DEPLOY_NAME = "${BOOT_NAME}"
