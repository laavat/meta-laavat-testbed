SUMMARY = "Exercises laavat-bootgen's pack half without a Xilinx baremetal toolchain"
DESCRIPTION = "xilinx-bootbin cannot be built from a stock meta-xilinx layer set: its \
BIF_FSBL_ATTR pulls in fsbl and pmufw, which are baremetal builds needing \
meta-xilinx-standalone, multiconfig and a MicroBlaze toolchain. That leaves laavat-bootgen \
verifiable only by inspection on the real recipe. This recipe carries a BIF and stand-in \
partitions so do_laavat_pack runs for real, and the archive it produces can be \
checked: the task ordering, the BIF parse, the request document and the tar all execute."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/COPYING.MIT;md5=3da9cfbcb788c80a0384361b4de20420"

SRC_URI = "file://smoke.bif"
S = "${WORKDIR}/sources"
UNPACKDIR = "${S}"

INHIBIT_DEFAULT_DEPS = "1"
EXCLUDE_FROM_WORLD = "1"
inherit deploy

# Stand-ins for the real partitions. laavat-bootgen only has to find a file of each name
# the BIF references; what is inside them is bootgen's problem, and bootgen runs service-side.
do_configure() {
    src="${UNPACKDIR}"
    [ -f "$src/smoke.bif" ] || src="${WORKDIR}"
    install -d ${B}
    install -m 0644 "$src/smoke.bif" ${B}/smoke.bif
    for p in fsbl.elf pmufw.elf u-boot.elf; do
        printf 'not-a-real-elf-%s' "$p" > ${B}/$p
    done
}

LAAVAT_BOOTGEN_ARCH = "zynqmp"
LAAVAT_BOOTGEN_BIFS = "smoke.bif"
LAAVAT_BOOTGEN_OUTPUTS = "BOOT.bin"

inherit ${@'laavat-bootgen' if d.getVar('LAAVAT_BOOTGEN_SIGN') == '1' else ''}
