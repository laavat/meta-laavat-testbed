# Porting meta-laavat to AMD/Xilinx Zynq UltraScale+ MPSoC

**What this was.** The first non-NXP SoC. Every tier before it is an i.MX, so every one of
them could in principle have been passing because `meta-laavat` is quietly i.MX code with
the i.MX filed off. This tier is the control: there is no HAB here at all, so apart from the
boot image, which has a class of its own (below), what remains is only the part the layer
claims is SoC-agnostic.

## Result

**27 lines of glue** (non-comment, non-blank, as `make simplicity` counts them), no changes
to meta-laavat for the FIT, RAUC and OP-TEE halves, and the config parsed with 0 errors
(3123 recipes) on the first try. It is the smallest sample layer in the repo, smaller than
any i.MX one.

| Recipe | Class | Tasks gained |
|---|---|---|
| `xilinx-bootbin` | `laavat-bootgen` | `do_laavat_pack`, `do_laavat_sign`, `do_laavat_unpack` |
| `linux-xlnx` | `laavat-fitkey` | `do_laavat_fitkey`, `do_laavat_sign`, `do_laavat_fitimage_install` |
| `u-boot-xlnx` | `laavat-fitkey-uboot` | postfunc anchor assertion, by design |
| `sample-xilinx-zynqmp-bundle` | `laavat-rauc` | `do_laavat_pack`, `do_laavat_sign` |
| `rauc-conf` | `laavat-rauc-keyring` | `do_laavat_ca_pin` |

The FIT and RAUC classes needed **exactly the documented one-line `inherit` and nothing
else**, on a SoC from a different vendor with a different toolchain tune
(`cortexa72-cortexa53`), a different kernel (`linux-xlnx`), a different bootloader
(`u-boot-xlnx`) and a completely different secure-boot scheme. That is the strongest
evidence in the repo that the class boundary is drawn in the right place.

## Finding 1 - the machine names moved

There is no `zcu102-zynqmp` in scarthgap meta-xilinx. The board-specific machines were
replaced by System-Device-Tree generic ones, and the closest survivor,
`zynqmp-eg-generic`, says in its own description "Obsolete use zynqmp-generic instead". The
tier uses `zynqmp-generic`.

Cost of guessing: `bitbake -e` returned a `TUNE_FEATURES` that was still literally
`${TUNE_FEATURES:tune-${DEFAULTTUNE}}` and no `PREFERRED_PROVIDER` at all, because the
machine conf was never found. That is what an unset machine looks like, and it is quiet
rather than fatal.

## Finding 2 - OP-TEE is Versal-only here, and it costs nothing

`optee-os` recipes exist in meta-xilinx, but `optee-os-amd.inc` sets
`COMPATIBLE_MACHINE:versal-2ve-2vm` and nothing else, so on ZynqMP every one of them is
skipped: `bitbake optee-os` answers **"Nothing PROVIDES 'optee-os'"** while `bitbake -p`
reports 0 errors. Worth knowing: a recipe skipped for the machine is invisible at parse time.

Note the second-order effect: the layer's `optee-os_%.bbappend` did **not** dangle, because
a bbappend dangles only when no `.bb` matches it *by name* - being skipped for the machine
is a different thing. So the bbappend is kept: it is already correct for anyone moving this
layer to Versal.

This also corrected an earlier expectation that the Phytec and Xilinx tiers would be "the
first test of `LAAVAT_TA_GLOB` against a non-meta-imx optee-os". Neither is - because that
test was never missing. The QEMU tier builds
`meta-arm/recipes-security/optee/optee-os_4.1.0.bb`, and `make qemu-ta-tamper` proves TA
signing against it end to end. `laavat-optee` is covered on both packagings.

## What this did not prove

No build and no live signing: the tier parses and every task is wired. Building it means a
new tune (`cortexa72-cortexa53` shares no work dirs with the aarch64 i.MX tiers), so it
costs a full toolchain.

The boot image is wired, not proven on silicon. `xilinx-bootbin.bbappend` inherits
`laavat-bootgen` (guarded by `LAAVAT_BOOTGEN_SIGN`), which packs the BIF the recipe
generates together with the partitions it names; the service's `SignBootgenImage`
operation parses the BIF and runs bootgen with the key it holds. As with AHAB on the i.MX93
and i.MX8QM tiers (`laavat-ahab`), the check that matters - the boot ROM authenticating the
image against the device's fused key hash - happens on hardware only, and no emulator
models it.
