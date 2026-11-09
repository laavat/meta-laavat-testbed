# AHAB signing, off unless LAAVAT_AHAB_SIGN = "1". The boot recipe is meta-freescale's
# imx-boot even here; what Toradex replaces is the kernel and the bootloader.
inherit ${@'laavat-ahab' if d.getVar('LAAVAT_AHAB_SIGN') == '1' else ''}

# Unlike every NXP and Phytec tier, this machine is single-valued on both selectors:
# IMXBOOT_TARGETS is just "flash_b0" and UBOOT_CONFIG just "sd", so imx-boot writes exactly
# one image. Named anyway, because laavat-ahab does not detect AHAB containers.
LAAVAT_AHAB_IMAGE = "${S}/imx-boot-${MACHINE}-sd.bin-flash_b0"
