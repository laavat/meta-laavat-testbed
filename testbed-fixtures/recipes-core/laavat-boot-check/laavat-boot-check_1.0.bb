SUMMARY = "Runtime verification checks for the signing test-bed"
DESCRIPTION = "Prints one LAAVAT-CHECK line per assertion so scripts/boot-verify.py can \
parse a verdict out of the serial log, and so the same checks run by hand on a board."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/COPYING.MIT;md5=3da9cfbcb788c80a0384361b4de20420"

SRC_URI = "file://laavat-boot-check.sh file://laavat-boot-check.service"

# Not S = "${WORKDIR}": walnascar rejects that outright ("Using S = ${WORKDIR} is no longer
# supported"), which is how the walnascar tier earned its keep on its first parse. Scarthgap
# has no UNPACKDIR at all and unpacks into WORKDIR, so setting both here works on either:
# on walnascar the files land in ${S}, on scarthgap UNPACKDIR is inert and ${S} is where
# do_install looks.
S = "${WORKDIR}/sources"
UNPACKDIR = "${S}"

inherit systemd
SYSTEMD_SERVICE:${PN} = "laavat-boot-check.service"
# xtest is what exercises the TEE's signature check; without it ta-load cannot run.
RDEPENDS:${PN} = "optee-test optee-client"

# The two releases put unpacked files in different places and there is no single
# expression for both: walnascar honours UNPACKDIR (set to ${S} above), scarthgap has no
# such variable and unpacks into ${WORKDIR}. Resolving it in the task is ugly but honest,
# and it is checked rather than assumed - `bitbake laavat-boot-check -c install` was run on
# both before this was committed.
do_install() {
    src="${UNPACKDIR}"
    [ -f "$src/laavat-boot-check.sh" ] || src="${WORKDIR}"
    install -D -m 0755 "$src/laavat-boot-check.sh" ${D}${bindir}/laavat-boot-check.sh
    install -D -m 0644 "$src/laavat-boot-check.service" \
        ${D}${systemd_system_unitdir}/laavat-boot-check.service
}
