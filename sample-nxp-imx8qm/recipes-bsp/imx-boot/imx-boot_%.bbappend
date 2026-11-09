# AHAB signing, off unless LAAVAT_AHAB_SIGN = "1".
#
# i.MX8QM is AHAB like i.MX93, but by a different route: its containers are handled by the
# SECO firmware rather than i.MX93's ELE. That difference is the service's problem, not the
# layer's - SignSPSDK takes the image either way - so this bbappend is the i.MX93 one with
# a different path, which is the point of the tier.
inherit ${@'laavat-ahab' if d.getVar('LAAVAT_AHAB_SIGN') == '1' else ''}

# IMXBOOT_TARGETS here is "flash_linux_m4 flash_spl", so imx-boot writes two. This names
# the first, which is what the recipe's own do_deploy links ${BOOT_NAME} to.
LAAVAT_AHAB_IMAGE = "${S}/imx-boot-${MACHINE}-sd.bin-flash_linux_m4"
