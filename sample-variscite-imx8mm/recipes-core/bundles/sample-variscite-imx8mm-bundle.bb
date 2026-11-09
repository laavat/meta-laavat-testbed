SUMMARY = "RAUC update bundle for the signing test-bed (rootfs slot)"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/COPYING.MIT;md5=3da9cfbcb788c80a0384361b4de20420"

inherit bundle

RAUC_BUNDLE_FORMAT = "verity"
RAUC_BUNDLE_COMPATIBLE = "${MACHINE}"
RAUC_BUNDLE_VERSION = "${PV}"
RAUC_BUNDLE_DESCRIPTION = "core-image-minimal for ${MACHINE} (signing test-bed)"

RAUC_BUNDLE_SLOTS = "rootfs"
RAUC_SLOT_rootfs = "core-image-minimal"
# fstype follows RAUC_IMAGE_FSTYPE (kas/rauc.yml: ext4; kas/verity.yml: ext4.verity)
# The slot payload may be the dm-verity image (ext4 + appended hash tree, kas/verity.yml).
# RAUC maps image types by file extension and cannot map ".ext4.verity", so name the
# bundle member rootfs.ext4: it is still written byte-for-byte into an ext4-typed slot.
RAUC_SLOT_rootfs[rename] = "rootfs.ext4"

# Dev signing key/cert; override from local.conf (e.g. RAUC_KEY_FILE = "pkcs11:token=…;object=…").
RAUC_KEY_FILE ?= "${THISDIR}/files/dev-keys/rauc/development-1.key.pem"
RAUC_CERT_FILE ?= "${THISDIR}/files/dev-keys/rauc/development-1.cert.pem"

# LAAVAT re-signing of the built bundle, off unless LAAVAT_RAUC_SIGN = "1"
# (kas/laavat/rauc.yml). One conditional inherit, so with it off nothing is set at all.
# laavat-rauc packs the resign request, signs it and deploys the result; this recipe
# says nothing about how, because none of it is board- or bundle-specific.
inherit ${@'laavat-rauc' if d.getVar('LAAVAT_RAUC_SIGN') == '1' else ''}
