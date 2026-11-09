SUMMARY = "RAUC update bundle for the Toradex Apalis iMX8 signing tier"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/COPYING.MIT;md5=3da9cfbcb788c80a0384361b4de20420"

inherit bundle

RAUC_BUNDLE_COMPATIBLE = "sample-toradex-imx8qm"
RAUC_BUNDLE_FORMAT = "verity"
RAUC_BUNDLE_VERSION = "${PV}"
RAUC_BUNDLE_SLOTS = "rootfs"
RAUC_SLOT_rootfs = "core-image-minimal"
RAUC_SLOT_rootfs[fstype] = "ext4"

RAUC_KEY_FILE ?= "${LAAVAT_DEVKEYS_DIR}/dev.key.pem"
RAUC_CERT_FILE ?= "${LAAVAT_DEVKEYS_DIR}/dev.cert.pem"

# INTEGRATION.md section 7: on the bundle recipe this is the whole integration.
inherit ${@'laavat-rauc' if d.getVar('LAAVAT_RAUC_SIGN') == '1' else ''}
