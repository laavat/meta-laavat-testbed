FILESEXTRAPATHS:prepend := "${LAAVAT_DEVKEYS_DIR}:"

# The device must trust the service's issuing CA: RaucBundleSigningWithOneTimeKey mints a
# per-bundle certificate, so there is no single signer key to pin. laavat-rauc-keyring
# installs it and, unlike meta-rauc's own RAUC_KEYRING_URI, fails the build if the file is
# not the one whose digest is pinned here.
inherit ${@'laavat-rauc-keyring' if d.getVar('LAAVAT_RAUC_SIGN') == '1' else ''}
# PLACEHOLDER pin: the demo CA in testbed-fixtures, not a real one. Replace both with your
# service's issuing CA and its digest - the guard proves the file did not change, not that
# it is the right CA.
LAAVAT_RAUC_CA_SHA256 ?= "177899cdd047c4e8268e590d92f9b6857dbd5115aaf0a39f95b0e7d35e40cc3a"
