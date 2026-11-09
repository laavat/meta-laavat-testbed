# poky's u-boot-tools builds fdt_add_pubkey via cross_tools but does not install it
# (u-boot-tools.inc installs mkimage, mkenvimage, dumpimage, fit_check_sign, mkeficapsule).
#
# This is here rather than in meta-laavat on purpose. The layer's own class takes the tool
# from the u-boot recipe's build tree, so it needs no bbappend on a recipe it does not own;
# a bbappend here changes u-boot-tools for every build that merely has the layer in
# bblayers, which is what yocto-check-layer's signature test exists to catch.
#
# The *harness* still needs it on PATH: qemuarm64-secureboot takes its control device tree
# from QEMU (OF_BOARD), so scripts/boot-verify.py has to add the key to that tree itself.
# That is a property of this demo, so the cost of the signature change is paid here.

do_install:append() {
    if [ -e "${B}/tools/fdt_add_pubkey" ]; then
        install -m 0755 ${B}/tools/fdt_add_pubkey ${D}${bindir}/uboot-fdt_add_pubkey
        ln -sf uboot-fdt_add_pubkey ${D}${bindir}/fdt_add_pubkey
    else
        bbwarn "u-boot-tools ${PV} built no tools/fdt_add_pubkey; the QEMU demo needs it"
    fi
}

FILES:${PN}-mkimage += "${bindir}/uboot-fdt_add_pubkey ${bindir}/fdt_add_pubkey"
