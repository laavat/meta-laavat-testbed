# AHAB signing, off unless LAAVAT_AHAB_SIGN = "1".
#
# i.MX93's boot ROM is AHAB, not HABv4, so this is laavat-ahab rather than laavat-hab. The
# class is thin - the service's SignSPSDK is a plain file-upload operation - and everything
# board-specific is the one path below.
inherit ${@'laavat-ahab' if d.getVar('LAAVAT_AHAB_SIGN') == '1' else ''}

# Which of the three. IMXBOOT_TARGETS here is
# "flash_singleboot flash_singleboot_gdet flash_singleboot_gdet_auto", so imx-boot writes
# three images and only the integrator knows which ships; gdet is the glitch-detector
# variant. laavat-ahab does not guess, unlike laavat-hab, which can recognise a HABv4 IVT.
LAAVAT_AHAB_IMAGE = "${S}/imx-boot-${MACHINE}-sd.bin-flash_singleboot"
