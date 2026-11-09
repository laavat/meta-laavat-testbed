# LAAVAT FIT signing on the QEMU tier, off unless LAAVAT_FIT_SIGN = "1".
#
# The second condition is what makes this layer work on either side of Yocto 5.3. Up to
# 5.2 the FIT is built here, by kernel-fitimage.bbclass, and laavat-fitkey hooks its tasks.
# From 5.3 that class is gone and the FIT has its own recipe, so the glue moves to
# linux-yocto-fitimage.bbappend (laavat-fitimage) and this append must go quiet rather than
# fail. Testing KERNEL_CLASSES asks the only question that matters: is the FIT built here?
#
# An integrator targeting one release just writes one file or the other and needs neither
# condition; this test-bed spans releases, so it carries both.
inherit ${@'laavat-fitkey' if d.getVar('LAAVAT_FIT_SIGN') == '1' \
          and 'kernel-fitimage' in (d.getVar('KERNEL_CLASSES') or '').split() else ''}
