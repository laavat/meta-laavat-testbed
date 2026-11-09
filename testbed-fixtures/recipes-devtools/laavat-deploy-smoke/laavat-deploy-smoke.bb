# Proves LAAVAT_SIGN_SKIP reaches the deploy step.
#
# Without an account the signing tasks do nothing and say so, which is what lets someone
# evaluate the layer before signing up. The step that installs what those tasks would have
# written has to stand down too - it did not, and every archive-mode target failed at
# do_deploy on a file do_laavat_sign had deliberately not written. Nothing caught it
# because `bitbake -p` never runs a task and `make qemu-demo` always has credentials.
SUMMARY = "LAAVAT_SIGN_SKIP deploy path"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit deploy
# meta-laavat is only in the layer set for kas/laavat*.yml; parse (task-less) without it.
inherit ${@'laavat-hab' if bb.utils.which(d.getVar('BBPATH'), 'classes/laavat-hab.bbclass') else ''}

EXCLUDE_FROM_WORLD = "1"
INHIBIT_DEFAULT_DEPS = "1"

# The point of the fixture: no API URL, no product, no token, no network.
LAAVAT_SIGN_SKIP = "1"
LAAVAT_HAB_IMAGE = "${B}/flash.bin"

do_compile() {
    head -c 4096 /dev/urandom > ${B}/flash.bin
}

# As a BSP recipe does: deploy the built image, and let laavat-hab's :append add the
# signed one beside it. deploy.bbclass schedules nothing, so the addtask is the recipe's.
do_deploy() {
    install -m 0644 ${B}/flash.bin ${DEPLOYDIR}/flash.bin
}
addtask deploy after do_compile before do_build
