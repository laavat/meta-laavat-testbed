# LAAVAT hab-archive-v1 signing, off unless LAAVAT_HAB_ARCHIVE = "1" (kas/laavat/hab.yml).
# One conditional inherit - the shape meta-variscite-hab's own imx-boot bbappend uses.
inherit ${@'laavat-hab' if d.getVar('LAAVAT_HAB_ARCHIVE') == '1' else ''}

# The two board facts, and the whole per-recipe cost of the feature. Both come from
# meta-variscite-hab's imx-boot-signature.inc, so kas/laavat/hab.yml has to keep
# including kas/hab.yml. laavat-hab generates the request itself; a template is only
# needed for a CSF the generic HABv4 shape cannot express.
LAAVAT_HAB_IMAGE = "${S}/${BOOT_IMAGE_SD}"
LAAVAT_HAB_DEPLOY_NAME = "${UUU_BOOTLOADER}"
