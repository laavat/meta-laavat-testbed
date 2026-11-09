# system.conf for the image comes from files/, the dev CA (keyring for the dev-key tiers)
# from the bundle recipe's generated dev-keys, and the service CA from the shared
# placeholder in testbed-fixtures (LAAVAT_DEVKEYS_DIR).
FILESEXTRAPATHS:prepend := "${THISDIR}/files:${THISDIR}/../bundles/files/dev-keys/rauc:${LAAVAT_DEVKEYS_DIR}:"

do_install:prepend() {
    sed -i "s/@@MACHINE@@/${MACHINE}/g" ${WORKDIR}/system.conf
}

# With LAAVAT_RAUC_SIGN the device must trust the service's issuing CA rather than the dev
# certificate: the one-time-signing operation mints a per-bundle certificate, so there is
# no single signer key to pin. laavat-rauc-keyring fetches, pins and installs it; the
# digest is the one site-specific fact, and it is required.
inherit ${@'laavat-rauc-keyring' if d.getVar('LAAVAT_RAUC_SIGN') == '1' else ''}
# PLACEHOLDER pin: the demo CA in testbed-fixtures, not a real one. For a live build, point
# LAAVAT_RAUC_CA at your service's issuing CA and set this to its digest in your config.
LAAVAT_RAUC_CA_SHA256 ?= "177899cdd047c4e8268e590d92f9b6857dbd5115aaf0a39f95b0e7d35e40cc3a"
