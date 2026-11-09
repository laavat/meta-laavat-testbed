# Porting meta-laavat to the Phytec phyBOARD-Polis i.MX8MM

**What this was.** A third i.MX8MM glue layer (`sample-phytec-imx8mm/`), for an unrelated
vendor's BSP. The EVK tier tested whether the docs were sufficient; this one tests whether
the *class boundary* survives a BSP that shares nothing with the others but the SoC.

## Result

`kas/phytec-live.yml` parses with **0 errors** (3300 recipes), after one build-configuration
fix that had nothing to do with meta-laavat (Finding 3). Every class wired on the first
attempt; one class, `laavat-hab`, gained a warning as a result of this tier (Finding 2).

## Finding 1 - reading the layer got three names out of four wrong

The scouting notes for this tier were written by reading meta-phytec's sources.
`bitbake -e` on a real checkout disagreed with most of them:

| Predicted from reading | Actually, measured |
|---|---|
| kernel `linux-phytec` | **`linux-phytec-imx`** |
| bootloader `u-boot-imx` | **`u-boot-phytec-imx`** |
| optee-os from **meta-arm** | meta-imx's `4.4.0.imx`, same as the other two tiers |
| `UUU_BOOTLOADER` ports unchanged | **unset here** |

The optee prediction was wrong twice over. Not only does this machine take meta-imx's
optee-os, but meta-arm's was never an untested case to begin with: the QEMU tier builds
`meta-arm/recipes-security/optee/optee-os_4.1.0.bb`, and `make qemu-ta-tamper` proves TA
signing against it. `laavat-optee` is covered on both packagings.

The cause is that `phyboard-polis-imx8mm-5` resolves to `use-nxp-bsp` (`IMX_DEFAULT_BSP` is
`"nxp"`), and meta-phytec's mainline-BSP recipes - including meta-arm's optee-os - are the
other branch of that override. Reading a layer that carries both variants tells you what
*might* be selected, never what is.

**The rule this produces:** on any new BSP, run `bitbake -e` before writing a single
bbappend. A bbappend named for a recipe that does not exist is a hard error, so a wrong
guess does not fail quietly, but it does waste the first build.

## Finding 2 - this machine builds FOUR boot images, and three of them went unsigned without a word

`phyboard-polis-imx8mm-5` leaves both selectors multi-valued:

    UBOOT_CONFIG    ??= "fspi sd"
    IMXBOOT_TARGETS  = "flash_evk flash_evk_flexspi"

and `imx-boot-phytec_1.0.bb`'s `do_compile` is a nested loop over their product:

    for target in ${IMXBOOT_TARGETS}; do
        for config in ${UBOOT_CONFIG}; do
            ...
            cp ${BOOT_STAGING}/flash.bin ${S}/${BOOT_NAME}-${MACHINE}-${config}.bin-${target}

so four boot images are built, and `do_deploy` installs all four.

Two consequences, one already handled and one not:

- **Auto-detection correctly refuses.** `laavat-hab` finds the boot image itself only when
  exactly one candidate exists. Here it sees four and fails with all four names, which is
  the designed behaviour and forces the integrator to choose.
- **But then it said nothing about the other three.** `select_image` returns no note on the
  explicit path, by design and by test, so naming one image left three signed-looking
  artifacts shipping unsigned with nothing in the log. Fixed: `laavat-hab` now warns,
  naming them.

This also retires the workaround the EVK tier documented. Reconstructing the name as

    LAAVAT_HAB_IMAGE = "${S}/imx-boot-${MACHINE}-${UBOOT_CONFIG}.bin-${IMXBOOT_TARGETS}"

is correct on the EVK, where both variables are single-valued. On this machine it expands to
a filename containing spaces that matches nothing - wrong *silently*, which is why the class
now finds the image instead of the integrator computing it.

## Finding 3 - meta-phytec assumes its own setup script

`imx-boot-phytec_1.0.bb:10` reaches into meta-imx for a patch:

    FILESEXTRAPATHS:prepend := "${OEROOT}/../meta-imx/meta-imx-bsp/recipes-bsp/imx-mkimage/files:"

`OEROOT` is defined by Phytec's `bblayers.conf.sample` and by their own kas files, and by
nothing else. Under plain kas it expands to nothing, so the recipe cannot find a patch that
is sitting right there in the tree, and parsing halts.

Fixed in `kas/imx-phytec.yml` with one line, `OEROOT = "${COREBASE}"` - COREBASE is poky,
which is what OEROOT means in Phytec's own layout. Worth knowing generally: a third-party
BSP layer may depend on variables its vendor's build harness sets, and those are invisible
until you build it somewhere else.

## Not a gap, worth recording

- **`MACHINE_FEATURES:append = " optee"` is a no-op here.** This machine already carries
  `optee`, so the one line in step a of
  [INTEGRATION.md section 8](https://github.com/laavat/meta-laavat/blob/main/docs/INTEGRATION.md)
  costs nothing but is not needed.
- **No meta-rauc usage in meta-phytec**, so the bundle recipe is ours, as on the EVK.
- **The boot-image name is composed in shell here too**, from `$config` and `$target` loop
  variables. Three BSPs, three arrangements, and two of the three publish no variable naming
  the binary. The reconstruct-it-yourself approach was never going to hold.

## What this did not prove

No live signing ran on this tier: the config parses and every task is wired, but the service
half is the same code the Variscite and QEMU tiers exercise. A full build was not run - the
kernel and boot-image builds are the expensive part, and the findings above all came from
parsing and from reading the recipe that parse selected.
