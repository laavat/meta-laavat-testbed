# What it costs to integrate meta-laavat

Nine BSP tiers, five vendors, five SoC families, three boot-ROM schemes. The table is the
claim: adopting the layer is a small, declarative bbappend per recipe, and the number does
not grow when the hardware gets less familiar.

`make simplicity` measures it and fails the build on any python inside a sample layer.

| Tier | SoC / vendor | Boot ROM | Glue lines | Python |
|---|---|---|---|---|
| `sample-xilinx-zynqmp` | Zynq UltraScale+ / AMD | CSU (bootgen) | **27** | 0 |
| `sample-nxp-imx8mm` | i.MX8MM / NXP | HABv4 | **28** | 0 |
| `sample-nxp-imx93` | i.MX93 / NXP | AHAB (ELE) | **28** | 0 |
| `sample-nxp-imx8qm` | i.MX8QM / NXP | AHAB (SECO) | **28** | 0 |
| `sample-toradex-imx8qm` | i.MX8QM / **Toradex** | AHAB (SECO) | **28** | 0 |
| `sample-nxp-imx6` | i.MX6 / NXP | HABv4 | **29** | 0 |
| `sample-phytec-imx8mm` | i.MX8MM / Phytec | HABv4 | **29** | 0 |
| `sample-variscite-imx8mm` | i.MX8MM / Variscite | HABv4 | **36** | 0 |
| `sample-qemu-arm64` | qemuarm64 | TF-A chain | **42** | 0 |

Lines are non-comment, non-blank, across every `.bb`, `.bbappend`, `.inc` and `layer.conf`
in the layer - the whole cost of the layer, including its RAUC bundle recipe and its
`layer.conf`, not just the signing lines.

## What each tier is for

Adding a board that resembles one already here proves nothing. Each tier below breaks a
different assumption.

- **Variscite i.MX8MM** - the original. The only BSP surveyed that publishes a variable
  naming its boot image (`BOOT_IMAGE_SD`).
- **qemuarm64** - a machine with no vendor BSP at all, and the only tier that boots and
  verifies: `make qemu-demo` proves the device rejects a tampered kernel, a tampered TA and
  an unsigned bundle.
- **NXP i.MX8MM EVK** - the same SoC from a different vendor. Showed that NXP publishes no
  variable naming the boot binary, which is why `laavat-hab` now finds it itself.
- **Phytec i.MX8MM** - a third vendor, sharing nothing but the SoC. Builds **four** boot
  images from one recipe, which is why `laavat-hab` now warns about the ones it leaves
  unsigned.
- **NXP i.MX6** - not aarch64, no `imx-boot` recipe, no SPL. A single-stage `u-boot.imx`
  from the u-boot recipe, and the only tier where one recipe carries two laavat classes.
- **Xilinx ZynqMP** - not NXP. No HAB at all, so it tests whether the FIT and RAUC classes
  are generic or merely i.MX code without the i.MX in it. They are generic: the same one-line
  inherits as on i.MX, no layer changes, parsed first try. The boot image takes
  `laavat-bootgen`, a single inherit on `xilinx-bootbin`. OP-TEE is not exercised here:
  meta-xilinx builds it for Versal only, so the tier's `optee-os` bbappend is inert on ZynqMP
  and kept for a Versal port. 27 lines in all.
- **NXP i.MX93** - not HABv4. AHAB through SPSDK, which needed a new `laavat-ahab` class in
  the layer and left the integrator's side at the same 28 lines as its HABv4 sibling.
- **NXP i.MX8QM** - AHAB again, but reached through SECO firmware rather than i.MX93's ELE.
  The tier exists to check that the difference is the service's problem and not the layer's.
  It is: the bbappend is the i.MX93 one with a different path, and `laavat-ahab` needed no
  change at all.
- **Toradex Apalis iMX8** - the same i.MX8QM from a different vendor, so the *vendor* axis
  on a SoC already covered. Toradex replaces the kernel and the bootloader
  (`linux-toradex`, `u-boot-toradex`) and keeps meta-freescale's `imx-boot`. Same 28 lines
  as the NXP board. It is also the only i.MX tier here that builds exactly **one** boot
  image: both `IMXBOOT_TARGETS` and `UBOOT_CONFIG` are single-valued.

## Mixing vendor BSP releases needs a mask

Toradex releases against a specific NXP BSP. Its `scarthgap-7.x.y` expects a newer meta-imx
than this test-bed pins (`scarthgap-6.6.52-2.2.0`): two recipes require
`dynamic-layers/arm-toolchain/...`, a path the pinned meta-imx does not have at all. Both are
i.MX95-era firmware (System Manager, OEI) that an i.MX8QM never builds, so the tier masks
them rather than dragging in a second BSP checkout.

Worth knowing how that surfaced: a bare `bitbake -e` printed every variable happily. The
layer-dependency error and then the parse errors appeared only when a *recipe* was asked
for. Validating a new BSP with `bitbake -e` alone is not enough - ask for a recipe.

## The rule the tiers produced

Four of the i.MX BSPs build **several boot images from one recipe** - Phytec four, i.MX93
three, i.MX8QM two, the i.MX8MM EVK one only by luck. That is an i.MX-wide trait rather
than a vendor quirk, which is why `laavat-hab` refuses to guess between candidates and
warns about the ones an explicit path leaves unsigned.

Every one of these was settled with `bitbake -e` on a real checkout, never by reading the
layer sources. On Phytec, reading got **three of four recipe names wrong**. On Xilinx, the
board machine name did not exist any more and a wrong `MACHINE` fails quietly - `bitbake -e`
returns an unexpanded `TUNE_FEATURES` and no `PREFERRED_PROVIDER` rather than an error.

Related: [`phytec-port-log.md`](phytec-port-log.md), [`xilinx-port-log.md`](xilinx-port-log.md),
[`yocto-matrix.md`](yocto-matrix.md).
