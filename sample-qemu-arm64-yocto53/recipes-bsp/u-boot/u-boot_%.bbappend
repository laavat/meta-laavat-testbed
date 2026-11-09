# u-boot 2025.10 builds this machine with CONFIG_OF_BOARD=y and emits no u-boot.dtb -
# only dts/dt.dtb, which uboot-sign.bbclass does not look for. poky's concat_dtb then
# skips its whole signing block and downgrades the miss to "Verified boot won't be
# available", so the build stays green with no key in any control device tree.
#
# laavat-fitkey-uboot refuses that by default, which is the right default for a board.
# It is not right here: this machine genuinely takes its device tree from the platform,
# QEMU supplies it at boot, and the FIT verification key reaches U-Boot through the
# control DTB scripts/boot-verify.py builds and passes with -dtb. Saying so is the
# point of the variable.
#
# u-boot 2024.01 on Yocto 5.0 still produced u-boot.dtb for this machine, which is why
# the 5.0 tier keeps the check.
LAAVAT_FIT_REQUIRE_CONTROL_DTB = "0"
