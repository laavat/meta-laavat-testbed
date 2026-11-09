# meta-laavat test-bed (Yocto Scarthgap)

The harness for [`meta-laavat`](https://github.com/laavat/meta-laavat), and the worked
example its [integration guide](https://github.com/laavat/meta-laavat/blob/main/docs/INTEGRATION.md)
points at.

**Nine BSP tiers, five vendors, five SoC families, three boot-ROM schemes**, each in its own
sample layer, is what makes "the wiring is not board-specific" a demonstrated claim rather than
an assertion. Every tier costs 27-42 lines of declarative glue and contains no python at all;
`make simplicity` measures that and fails on any python in a sample layer.
[`docs/integration-matrix.md`](docs/integration-matrix.md) is the table, with what each tier was
added to break.

Two of them carry the argument:

| Tier | What it covers | Boot image |
|---|---|---|
| `sample-variscite-imx8mm` (`imx8mm-var-dart`) | the reference BSP: HAB, FIT, module signing, RAUC, dm-verity, OP-TEE - the widest target, and the one the other i.MX tiers are diffed against | HAB (`SignHAB`) |
| `sample-qemu-arm64` (`qemuarm64-secureboot`) | the only tier checked at *runtime*: it boots, asserts what the boot proves, and requires a tampered artifact to be refused | TF-A + U-Boot, no HAB |

Everything else is build-time evidence. That ceiling is the hardware's, not the layer's: no
emulator here models an i.MX boot ROM or a ZynqMP CSU, so HAB, AHAB and `bootgen` can be proven
to produce a correctly signed image and cannot be proven to boot one. A board makes that tier
runtime-checkable without changing the layer.

`sample-qemu-arm64-yocto53` is the same machine on the post-poky layout, where the FIT moved to
its own recipe - a tenth sample layer, not a tenth board, because a dangling bbappend is a hard
error and `linux-yocto-fitimage` does not exist before Yocto 5.3.

Every signing path is switched on. The dev-key tiers use **R&D keys** throughout; the
service tiers move the same operations to LAAVAT - additively on the i.MX tier, which keeps
the dev-key signing running beside them. Which of those keys the *device* still trusts differs
per target; `DEMO.md` has the table. RAUC development keys are generated on first use by
`make dev-keys` (every build target runs it; `scripts/gen-dev-keys.sh`), so the dev-key tiers
build with no credentials - `rauc bundle` refuses to run without a key, even when the service
re-signs the result afterwards. They are never committed. `sample-variscite-imx8mm` and
`sample-qemu-arm64` get their own CA + signer pair under `**/dev-keys/rauc/`; the other seven
tiers share one signer in `testbed-fixtures/files/dev-keys/`. All of them are throwaways whose
CN reads `DO NOT USE IN PRODUCTION`. The shared `service-ca.pem` beside them is a
**placeholder** issuing CA that every tier pins, so their builds pass with it installed as the
device's update root of trust - for a live build, replace the file and the pin together
before a device sees either.

**New here?** Two shorter doors in. [`docs/presentation/getting-started.html`](docs/presentation/getting-started.html)
is the illustrated tour - what the layer does, what your host needs, what `kas-container` even is,
and diagrams of the build-time round trip, the boot chain and where your own code goes.
[`RUNBOOK.md`](RUNBOOK.md) is the linear command sequence: prerequisites, three escalating paths
(build with no account, sign with no account, the full demo), what a passing run prints, and the
traps. This file is the reference behind both, and [`DEMO.md`](DEMO.md) is what each tier proves.

## Prerequisites
Docker or Podman (everything else runs inside the kas container), `git`, `make` and `openssl`
on the host, ~35 GB free on the build filesystem (btrfs + compression is fine), and network to
GitHub, PyPI and `downloads.yoctoproject.org` - `imx-cst`'s Debian URL 404s and is served by
the Yocto source mirror. On 12 cores the first baseline build takes ~70 min, the full signed
build ~2 h.

    make fetch        # clone pinned layers into layers-50/
    make fetch-laavat # install meta-laavat at the pinned release (LAAVAT_REF)
    make build-min    # unsigned baseline (kas/base.yml)
    make build        # everything (kas/all.yml)
    make verify       # PASS/FAIL per component
    make delta        # what V2 adds to V1 (see DEMO.md)
    make disk         # disk usage

`make fetch-laavat` clones [github.com/laavat/meta-laavat](https://github.com/laavat/meta-laavat)
at `LAAVAT_REF` (a release tag, set in the Makefile). `make fetch-laavat LAAVAT_SRC=/path/to/meta-laavat`
installs a local checkout instead, for working on the layer itself.

Single feature: `make build KAS_CFG=kas/fit.yml` (any of fit/hab/modsign/rauc/verity/optee).
`kas/optee.yml` is the one fragment `kas/all.yml` does not include - see "OP-TEE" below.
Every laavat fragment anchors the device to the service; only HAB also keeps a dev-key
signature beside it. `kas/qemu-live.yml` (`make qemu-demo`) is the tier proven at runtime.

## LAAVAT wiring: one fragment and one conditional inherit per target

Each target is off unless its guard is set, so a fragment can be composed with the
dev-key ones without touching them. The guard gates a single `inherit`; the class it
names lives in `meta-laavat` and carries the whole mechanism, so the glue in this layer
is a bbappend that says *which recipe* and, where the board has one, *which file*.

| kas fragment | Guard | Glue, under `sample-variscite-imx8mm/` | What the glue adds | meta-laavat class | Operation |
|---|---|---|---|---|---|
| `kas/laavat/common.yml` | - | `recipes-devtools/laavat-sign-smoke/` | a whole recipe - it exists only to be signed | `laavat-sign` | `SignUBoot` |
| `kas/laavat/hab.yml` | `LAAVAT_HAB_ARCHIVE` | `recipes-bsp/imx-boot/imx-boot_%.bbappend` | the `inherit` + 2 variables | `laavat-hab` | `SignHAB`, `hab-archive-v1` |
| `kas/laavat/fit.yml` | `LAAVAT_FIT_SIGN` | `recipes-kernel/linux{,-yocto}/`, `recipes-bsp/u-boot/` | the `inherit`, on each of the four | `laavat-fitkey`, `-uboot` | `SignKernel` |
| `kas/laavat/rauc.yml` | `LAAVAT_RAUC_SIGN` | `recipes-core/bundles/`, `recipes-core/rauc/` | the `inherit`, + the CA digest to pin | `laavat-rauc`, `-keyring` | `RaucBundleSigningWithOneTimeKey` |
| `kas/laavat/optee.yml` | `LAAVAT_OPTEE_SIGN` | `recipes-security/optee-imx/optee-os_%.bbappend` | the `inherit`, and nothing else | `laavat-optee` | `OP-TEESigning` |

Only two rows add anything beyond the `inherit`, and both are facts no class could know.
`laavat-hab` needs which binary the BSP builds and what it calls the deployed one
(`BOOT_IMAGE_SD` and `UUU_BOOTLOADER` are meta-variscite-hab's); `laavat-rauc-keyring`
needs the SHA-256 of the CA to install as the device keyring, which is site data and is
required rather than defaulted. Those bbappends carry other lines - kernel `.cfg`
fragments, `FILESEXTRAPATHS`, a `system.conf` edit - but none of them are about signing.

FIT is one guard across two recipes on purpose. Enabled apart, either half signs against a
key the other side does not hold: the kernel would carry a signature the control device tree
cannot verify, or the tree would carry a key nothing signed with.

### The QEMU tier: anchors, not just signatures

`kas/qemu-live.yml` builds `qemuarm64-secureboot` with the service as the *only*
trust anchor for the kernel, the trusted applications and the update bundle - not
merely as an extra signature beside the dev-key one.

    make qemu-demo    # build against the live service, boot it, assert every check

The kernel half is `meta-laavat`'s `laavat-fitkey` (on the kernel recipe) plus
`laavat-fitkey-uboot` (on u-boot): the service's public key is written where poky
already looks for a FIT signing key, so poky's own machinery carries it into
U-Boot's control device tree, and the copy U-Boot verifies is the signed one.

This machine sets `OF_BOARD`, so U-Boot takes its device tree from QEMU and builds
no `u-boot.dtb`. The config says so explicitly with
`LAAVAT_FIT_REQUIRE_CONTROL_DTB = "0"`, and `scripts/boot-verify.py --fit-key-dir`
keys the tree QEMU passes instead. That workaround is a property of the emulated
machine, so it lives in the harness rather than in `meta-laavat`.

### The i.MX tier with the anchor in the build

`kas/laavat/fit.yml` is `kas/fit.yml` + `kas/laavat/common.yml` + `LAAVAT_FIT_SIGN = "1"`,
and it exercises the half QEMU structurally cannot. `qemuarm64-secureboot` sets `OF_BOARD`,
so U-Boot there refuses to build a control device tree at all (U-Boot's own
`scripts/check-of.sh`, in its source tree - not this repo's `scripts/`) and `concat_dtb`
never runs. On `imx8mm-var-dart` it does.

    ./kas-container shell kas/laavat/fit.yml:kas/laavat-live.yml -c 'bitbake u-boot-variscite'

(add `--runtime-args "<container args>"` if the container needs them to reach your service).

The task log then shows poky's own `UBOOT_FIT_CHECK_SIGN` verifying the service's signature
against the service's key - `sha256,rsa2048:laavat+ OK` - and the deployed `u-boot.dtb-signed`
carries that key's `rsa,modulus` under `key-name-hint = "laavat"` (deployed as `u-boot.dtb`,
from `${B}/u-boot.dtb-signed`). Built and verified 2026-08-30 - the verdict is in the task log,
`build/tmp/work/*/u-boot-variscite/*/temp/log.do_uboot_assemble_fitimage.*`, not in `build/logs/`;
**not booted on hardware**.

`kas/laavat-live.yml` is every laavat fragment at once on top of `kas/all.yml`'s feature set, plus
real-service wiring - the demo's V2, see `DEMO.md` and `make delta`. Every fragment needs
`make fetch-laavat` first. The `signing-tool` client comes from PyPI through the layer's own
recipe; nothing is built by hand and no `PREFERRED_VERSION` is pinned.

## Hermetic signing smoke

`laavat-sign-smoke` runs `meta-laavat`'s `do_laavat_sign` against
`scripts/laavat-stub.py` - the signing call reaches no service, needs no credentials and
never leaves the container's loopback (the build itself still fetches `u-boot-tools-native` on a
cold `downloads/`). Its payload is
a 64KiB FIT with an unsigned `signature-1` node, which is what `SignUBoot` really
takes: the service runs `mkimage -F` and fails a bare blob with "No signatures
were added". The stub listens on the container's own loopback, so it has to be
started inside it:

    ./kas-container shell kas/laavat/common.yml -c '
      printf "%s" dummy-token > /tmp/laavat-token && chmod 600 /tmp/laavat-token
      export LAAVAT_TOKEN_FILE=/tmp/laavat-token
      export BB_ENV_PASSTHROUGH_ADDITIONS="$BB_ENV_PASSTHROUGH_ADDITIONS LAAVAT_TOKEN_FILE"
      python3 /work/scripts/laavat-stub.py --port 8943 & sleep 1
      bitbake laavat-sign-smoke -c laavat_sign'

Signed output: `build/tmp/work/*/laavat-sign-smoke/*/*/payload.fit.signed`, and
`log.do_laavat_sign` ends with the digest the class verified. Add
`--corrupt-digest` to the stub to check the other direction: the task must fail
and leave no output. Re-runs need `-f` (the task is stamped).

### HAB boot image, archive mode

`kas/laavat/hab.yml` is `kas/laavat/common.yml` + `kas/hab.yml` + `LAAVAT_HAB_ARCHIVE = "1"`.
`do_laavat_pack` (meta-laavat's `laavat-hab`) builds `request.json` from the block
addresses `signing-tool imagesigning hab-request` reads back out of the flash.bin that was
just built, and `do_laavat_sign` signs it as `hab-archive-v1` and installs the verified
`signed/flash.bin`. No template is involved: this layer names the binary and the deployed
file, and nothing else.

This image has **three** HAB IVTs, not two. imx-mkimage emits two overlapping descriptors
for the u-boot FIT - offset `0x57C00` for `0x1020`, and again for `0x3020` - and only one
can be signed, because the longer region contains the shorter one's CSF area. The default
`LAAVAT_HAB_STAGES = "SPL UBOOT"` signs IVTs 0 and 1, and the build warns about the third
by offset.

    ./kas-container shell kas/laavat/hab.yml -c '
      printf "%s" dummy-token > /tmp/laavat-token && chmod 600 /tmp/laavat-token
      export LAAVAT_TOKEN_FILE=/tmp/laavat-token
      export BB_ENV_PASSTHROUGH_ADDITIONS="$BB_ENV_PASSTHROUGH_ADDITIONS LAAVAT_TOKEN_FILE"
      python3 /work/scripts/laavat-stub.py --port 8943 & sleep 2
      bitbake imx-boot -c laavat_sign'

`build/tmp/work/*/imx-boot/*/laavat/` then holds `request.json`, the `flash.bin` that was
submitted and `flash.bin.laavat-signed`; `do_deploy` copies the last one to
`deploy/images/*/imx-boot.laavat-signed`. `cst_signer` still signs the same image in the same
build, so `scripts/ivt-csf.py` on either output shows what each signer did to it. The example
request signs each stage's IVT header block, which is what the IVTs carry; a production
request adds the FIT sub-image blocks (u-boot, dtb, ATF) from `make print_fit_hab`.

`--corrupt-digest` works here too (add `-f`, and clear `build/tmp/laavat-sign` first so the
run submits afresh): the task must fail and leave no `flash.bin.laavat-signed`.

Without the guard - a plain `kas/hab.yml` build - the bbappend expands to nothing:
`bitbake -e imx-boot` has no `LAAVAT_*` variable and no `do_laavat_*` task, and the CST path
is byte-for-byte what it was.

### FIT image

`kas/laavat/fit.yml` is `kas/laavat/common.yml` + `kas/fit.yml` + `LAAVAT_FIT_SIGN = "1"`. `mkimage` has
already signed the FIT with the dev key by the time `do_assemble_fitimage` finishes;
`do_laavat_sign` then submits the finished `fitImage` as a plain file (`SignKernel`, `raw`
encoding) and installs the verified result:

    ./kas-container shell kas/laavat/fit.yml -c '
      printf "%s" dummy-token > /tmp/laavat-token && chmod 600 /tmp/laavat-token
      export LAAVAT_TOKEN_FILE=/tmp/laavat-token
      export BB_ENV_PASSTHROUGH_ADDITIONS="$BB_ENV_PASSTHROUGH_ADDITIONS LAAVAT_TOKEN_FILE"
      python3 /work/scripts/laavat-stub.py --port 8943 & sleep 2
      bitbake linux-variscite -c laavat_sign'

`laavat-fitkey` signs `fitImage-none` in place - the copy poky installs into the sysroot and
U-Boot verifies - rather than depositing a second artifact nothing consumes, and
`laavat-fitkey-uboot` puts the service's key into the control device tree during
`do_uboot_assemble_fitimage`. So the FIT the image boots is the service-signed one and the
key that verifies it is the service's.

### RAUC bundle

`kas/laavat/rauc.yml` is `kas/laavat/common.yml` + `kas/rauc.yml` + `LAAVAT_RAUC_SIGN = "1"`. This is
RAUC's own recommended shape: `rauc bundle` signs with the cheap dev key, then a separate
step re-signs the finished bundle with the real one - here `RaucBundleSigningWithOneTimeKey`
on `${B}/bundle.raucb`, rather than pushing a PKCS#11 URI through `do_bundle`. The RAUC
operations take a `.tar.gz` of `request.json` + the bundle, not a bare `.raucb`, so
`do_laavat_pack` builds `{"format": "verity", "resign": true, "inputFile": "bundle.raucb"}`
around it and `do_laavat_sign` signs that:

    ./kas-container shell kas/laavat/rauc.yml -c '
      printf "%s" dummy-token > /tmp/laavat-token && chmod 600 /tmp/laavat-token
      export LAAVAT_TOKEN_FILE=/tmp/laavat-token
      export BB_ENV_PASSTHROUGH_ADDITIONS="$BB_ENV_PASSTHROUGH_ADDITIONS LAAVAT_TOKEN_FILE"
      python3 /work/scripts/laavat-stub.py --port 8943 & sleep 2
      bitbake sample-variscite-imx8mm-bundle -c laavat_sign'

Output: `build/tmp/work/*/sample-variscite-imx8mm-bundle/*/laavat/bundle.raucb.laavat-signed`, copied to
`deploy/images/*/sample-variscite-imx8mm-bundle-imx8mm-var-dart.raucb.laavat-signed` by `do_deploy`.
`bundle.bbclass` sets `SSTATE_SKIP_CREATION:task-deploy`, so unlike the imx-boot and kernel
wirings there is no `do_deploy_setscene` that could cover the signing.

Both fragments are inert with the guard off, the same way the HAB one is: under plain
`kas/fit.yml` / `kas/rauc.yml` a full `bitbake -e` of the recipe has zero `LAAVAT_*`
variables, no `do_laavat_*` task and an unchanged `BBINCLUDED`.

### Kernel modules: not signed through the service

Module signing is the one path with no service call in it. The kernel signs each `.ko`
itself during its own build with the key `CONFIG_MODULE_SIG_KEY` names, so there is no
per-artifact step between build and package for `do_laavat_sign` to sit in - and no service
operation for one either. `kas/modsign.yml` therefore stays on the kernel's own ephemeral
key: there is no service operation for module signing to wire in.

## Signing against a real service

`kas/laavat-live.yml` is all five laavat fragments in one config plus the service wiring:
API URL, token paths, CA bundle, and a product/operation pair per recipe. Copy it and
replace those values - the ones in the file are placeholders (`signing.example.com`,
`<product-uuid>`, `<operation-uuid>`, `<sha256-of-the-public-key-DER>`). (kas emits
`local_conf_header` sections in key order, which is why the section is called `live` - it
has to land after `kas/laavat/common.yml`'s stub defaults.)

Two things a real service needs that the stub did not:

**Reaching it from inside the kas container.** The build container needs HTTPS access to the
API URL and to the storage host named in the presigned upload and download URLs the service
returns. On an ordinary network that needs nothing extra. If the container needs extra
arguments to get there (a docker network, a proxy), pass them through:

    ./kas-container --runtime-args "<container args>" \
        shell kas/laavat-live.yml -c 'bitbake laavat-sign-smoke -c laavat_sign'

or `KAS_RUNTIME_ARGS="<container args>"` for the Makefile targets. Prove it before spending a
build: same arguments, `curl --cacert ... <api-url>/products`.

**Trust and tokens.** `build/laavat/` (gitignored) holds `token-writer.jwt`,
`token-approver.jwt` (mode 0600) and, if your service uses a private CA, `combined_ca.crt`;
the config names their in-container paths under `/build/laavat/` and exports
`REQUESTS_CA_BUNDLE`, which the client honours. Never `--skipssl`. The approver token makes
the build approve its own request, same as `kas/laavat-live.yml` below; leave
`LAAVAT_APPROVER_TOKEN_FILE` unset to keep approval separate - see section 3 of the
[integration guide](https://github.com/laavat/meta-laavat/blob/main/docs/INTEGRATION.md#3-point-the-build-at-the-service).

Then one target at a time. Always name the task: on a warm cache a full build can cover
`do_laavat_sign` with a `do_deploy` setscene hit.

    bitbake laavat-sign-smoke -c laavat_sign   # SignUBoot on the smoke FIT
    bitbake imx-boot          -c laavat_sign   # SignHAB, hab-archive-v1
    bitbake linux-variscite   -c laavat_sign   # SignKernel on the assembled fitImage
    bitbake sample-variscite-imx8mm-bundle -c laavat_sign  # RaucBundleSigningWithOneTimeKey

    bitbake optee-os          -c laavat_unpack  # OP-TEESigning on the TAs, with kas/laavat/optee.yml

All five have been proven against a live service. `optee-os` is the odd one out: the
ids are in this config but nothing happens without `kas/laavat/optee.yml` in the config too, and
it needs `LAAVAT_PUBKEY_SHA256` - see "Trusted applications, signed by the service" below.
(`kas/laavat-live.yml` already includes `kas/laavat/optee.yml`, so it does not need composing in
separately.)
What the outputs show:

| Target | Check | What it proves |
|---|---|---|
| smoke | `dumpimage -l payload.fit.signed` | the `signature-1` node went from `unavailable` to a 2048-bit value |
| imx-boot | `scripts/ivt-csf.py flash.bin.laavat-signed` | CSF headers at the SPL and U-Boot IVTs, where `cst_signer` puts its own. `cst_signer` covers all three IVTs and the worked example two, so `ivt-csf.py` still exits 1 - that third stage is the example request's ceiling, not a signing failure |
| fitImage | `dumpimage -l fitImage.laavat-signed` | every configuration signature replaced by the service's (24 of them, `FIT_SIGN_INDIVIDUAL = "0"`) |
| bundle | `rauc info --keyring <product CA>` | verifies; signer is a one-time cert minted at signing time; format still `verity`. Give rauc `[keyring] check-purpose=codesign` in a config file - a bare `--keyring` defaults to the S/MIME purpose and rejects *any* code-signing cert |
| optee-os | `scripts/optee-verify.py <ta-pub.pem> <workdir>/build/ta/*/*.ta` | all four TAs carry an RSASSA-PSS signature made by the operation key the core now embeds |

None of these prove the key is the one you meant - that is the product's PKI, not the
build's. Every one of them rides on the class's digest chain, which is what actually ties
the installed bytes to the request.

## OP-TEE

`kas/optee.yml` flips `MACHINE_FEATURES:append = " optee"` - and that is the whole fragment.
`imx8mm-var-dart.conf` already sets `TEE_LOAD_ADDR` / `TEE_CFG_DDR_SIZE` and Variscite's
`optee-os_%.imx.bbappend` already feeds them to the build, so nothing else has to be said. The
feature gates the rest by itself: ATF is rebuilt as its `-optee` BL31 variant
(`ATF_MACHINE_NAME=bl31-imx8mm.bin-optee`), `optee-os` deploys `tee.bin`, and imx-mkimage folds
it into flash.bin as BL32 (`make ... TEE=tee.bin`) at `TEE_LOAD_ADDR`.

Nothing about signing changes: `cst_signer` signs the *composed* `imx-boot`, so with
`kas/hab.yml` the HAB signature already covers `tee.bin` inside flash.bin - there is no separate
OP-TEE signing step and no second key. Compose the two (`make build KAS_CFG=kas/optee.yml` plus
the hab fragment, or a config that includes both) to get a HAB-signed boot image with OP-TEE in
it. `make verify` gains an `optee` check that fires only when `optee` is in `MACHINE_FEATURES`.
As with every single-feature config, building it rewrites the shared `build/tmp` deploy dir - a
plain `kas/optee.yml` build replaces the HAB-signed `imx-boot` and drops the signed `u-boot.dtb`,
so `make verify` against `kas/all.yml` afterwards reports those as FAIL until you rebuild it.
The displacement runs both ways: a later non-optee build erases `tee.bin` and
`deploy/images/*/optee/` just as thoroughly, so rebuild this config before checking them.

The recipe is meta-imx-bsp's `optee-os_4.4.0.imx.bb` (branch `lf-6.6.52_2.2.0`, the same NXP
release the BSP is pinned to), not meta-freescale's `4.2.0.imx`: `meta-imx-bsp`'s
`imx-base-extend.inc` re-pins `PREFERRED_VERSION_optee-os:mx8-nxp-bsp` after
`imx-base.inc` sets it, and the later weak default wins. Trusted Applications are a separate
matter from the TEE core: this fragment leaves them signed by optee-os's own in-tree key, and
`kas/laavat/optee.yml` is what moves them to the service.

### Trusted applications, signed by the service

`kas/laavat/optee.yml` is `kas/laavat/common.yml` + `kas/optee.yml` + `LAAVAT_OPTEE_SIGN = "1"`. Both
halves of TA trust move to the service at once: the TEE core embeds the operation's public key
as its verification anchor, and each `<uuid>.ta` is signed by the operation that holds the
private half. `TA_SIGN_KEY` stays at optee-os's throwaway default - whatever it signs during
`do_compile` is overwritten before `do_install` packages it.

Pin the key first. Fetch it once *without* `--fingerprint` - the command prints the SHA-256 of
the DER SubjectPublicKeyInfo - and put that in the config next to the ids (`kas/laavat-live.yml`
has all three). Without `LAAVAT_PUBKEY_SHA256` the build stops rather than embed an unpinned
key, and with the wrong one `getpubkey` fails, so a rotated key breaks the build instead of
silently becoming the anchor of everything the product will ever load:

    signing-tool -c -a <api> -t @<token> product getpubkey \
        -P <product uuid> --operid <operation uuid> -O ta-pub.pem

    LAAVAT_PUBKEY_SHA256:pn-optee-os = "<sha256 of the DER SubjectPublicKeyInfo>"
    LAAVAT_PRODUCT_ID:pn-optee-os = "<product uuid>"
    LAAVAT_OPER_ID:pn-optee-os = "<operation uuid>"

The operation key must be RSA: optee-os's `pem_to_pub_c.py` emits an RSA modulus/exponent pair
and nothing else.

Four tasks, all in meta-laavat's `laavat-optee.bbclass` - this layer contributes only
the one-line `inherit`: `do_laavat_fetch_pubkey`
(before `do_configure`, writes `laavat/ta-pub.pem`, which `EXTRA_OEMAKE` hands to make as
`TA_PUBLIC_KEY`), `do_laavat_pack` (`${B}/ta/*/*.ta` into a deterministic `tas.tar.gz`),
`do_laavat_sign` (the class, file mode), `do_laavat_unpack` (each signed `.ta` back over its
build-tree original, before the unmodified `do_install` packages them). A member that was never
packed, or a packed TA the service did not return, fails the task.

Against your service, with your ids and pin in `kas/laavat-live.yml`:

    ./kas-container shell kas/laavat/optee.yml:kas/laavat-live.yml -c 'bitbake optee-os -c laavat_unpack'
    ./kas-container shell kas/laavat-live.yml -c 'python3 /work/scripts/optee-verify.py \
        <workdir>/laavat/ta-pub.pem <workdir>/build/ta/*/*.ta'

All four TAs verify (RSASSA-PSS/MGF1/SHA-256), the modulus in the generated `core/ta_pub_key.c`
is the fetched key's, and the `.ta` files in `packages-split/optee-os/usr/lib/optee_armtz/` are
byte-identical to what came back. Flip one byte and `optee-verify.py` exits 1 - that is the
negative control. One request signs all four TAs, and the service returns each member renamed
`<name>.signed`, which is why `do_laavat_unpack` strips that suffix before matching. The
`.ta` copies under `build/export-ta_arm64/ta/` are *not* re-signed - they are the TA dev-kit's
build-time set and this recipe packages none of them.

None of this has been booted on i.MX8MM hardware. That the TEE core *accepts* these TAs is
no longer inferred, though: on the QEMU tier (`make qemu-demo`) the same wiring is booted, and
the boot log shows a service-signed TA loading, a foreign-key TA refused and a corrupted
service-signed TA refused. What remains untested here is this BSP's own TEE, not the mechanism.

This one is live-only: `scripts/laavat-stub.py` does not serve `OP-TEESigning` or `getpubkey`,
so there is no hermetic smoke for it - run it against a real service. The four tasks are one
chain, not four errands: `bitbake optee-os -c laavat_sign` pulls the pubkey fetch, the build and
the pack in behind it, and `-c laavat_unpack` adds the sign. What is checkable without a
service is that the wiring is inert with the guard off (under plain `kas/optee.yml`,
`bitbake -e optee-os` has zero `LAAVAT_*` variables and no `do_laavat_*` task) and that
`do_laavat_pack` is byte-reproducible. The
fragment also adds `optee-os` to `RM_WORK_EXCLUDE`: the TAs are packed from, signed back into
and installed out of the optee-os workdir, which `rm_work` would otherwise delete while the
stamps still say those tasks are done.

## What gets signed, with what, and where `meta-laavat` plugs in

| Component | Mechanism (upstream) | Dev key | Hook for another signer / PKCS#11 |
|---|---|---|---|
| imx-boot (SPL/ATF/U-Boot) | `meta-variscite-hab` `cst_signer` + `imx-cst` (Debian source), `kas/hab.yml` | public `var-hab-certs` PKI (SRK1-4, CSF, IMG) | `CST_CERTS_URI` (own PKI git repo, layout `iMX8M/{crts,keys}`), `CST_SERIAL`, `CST_KEYPASS`; CST OpenSSL-engine backend for HSM |
| fitImage (kernel + dtbs + verity initramfs) | poky `uboot-sign` + `kernel-fitimage`, `kas/fit.yml` | `build/keys/fit/dev.{key,crt}` (auto-generated) | `UBOOT_SIGN_KEYDIR/KEYNAME`, `FIT_SIGN_ALG`; HSM needs detached-sign + `fdt_add_pubkey` (mkimage -K can't use HSM keys) |
| kernel modules | `CONFIG_MODULE_SIG_ALL`, `modsign.cfg`, `kas/modsign.yml` | ephemeral, generated by the kernel build | `CONFIG_MODULE_SIG_KEY` (+ `meta-integrity` `kernel-modsign.bbclass` for a fixed key); no in-build service call exists - see "Kernel modules: not signed through the service" |
| RAUC bundle | `meta-rauc` `bundle.bbclass`, `sample-variscite-imx8mm-bundle.bb`, `kas/rauc.yml` | `dev-keys/rauc/development-1.*` (CA in image via `rauc-conf`) | `RAUC_KEY_FILE`/`RAUC_CERT_FILE` = `pkcs11:token=...;object=...` + `RAUC_PKCS11_PIN` |
| dm-verity rootfs | `meta-security` `dm-verity-img`, `kas/verity.yml` | - (root hash inside the signed FIT) | optional `CONFIG_DM_VERITY_VERIFY_ROOTHASH_SIG` |
| OP-TEE `tee.bin` (ATF BL32) | imx-mkimage folds it into flash.bin, `kas/optee.yml` | - (covered by the imx-boot HAB signature) | none needed for the core |
| OP-TEE trusted applications | optee-os's own build-time signing, `kas/optee.yml` | in-tree `keys/default_ta.pem` (throwaway) | `TA_PUBLIC_KEY` (the anchor the core embeds) + `TA_SIGN_KEY`, or `kas/laavat/optee.yml` for `OP-TEESigning` |

`make verify` checks: HAB CSF header at every IVT in `imx-boot`, plus `hab-verify.py --selfcheck`
(real CMS verification of the dev-key image, with a built-in negative control); `fit_check_sign` of `fitImage`
against the pubkey DTB; `~Module signature appended~` on a packaged `.ko`; `rauc info --keyring`;
`veritysetup verify` with the generated root hash. With `KAS_CFG=kas/all.yml` (the default) every
component except `optee` is required (`kas/all.yml` does not enable it), so any other SKIP is
a failure and `make verify` exits 1.

## Not covered by this test-bed
On-target A/B eMMC layout (`wks`), U-Boot boot script for `fitImage` + verity root, SRK fusing;
own HAB PKI generator; PKCS#11 wiring; `meta-nxp-connectivity`.
Booting either anchored tier on i.MX8MM hardware: the i.MX FIT anchor is verified at build
time only, and `make qemu-demo` runs on the emulated machine.
The demo images' U-Boot still accepts legacy (non-FIT) images (`CONFIG_LEGACY_IMAGE_FORMAT=y`)
and an unsigned `boot.scr`; a product build closes both in its own boot-script work.
The generated dev keys under `**/dev-keys/` are R&D only.

## Toolchain note
`./kas-container` is pinned to kas **4.7** on purpose: kas >= 5 ships Debian 13 / Python 3.13
images, which cannot host this scarthgap pin (`ninja-native` fails on the `pipes` module removed
in 3.13). Do not bump it without also moving off scarthgap. `make fetch` with the default config
needs `kas/all.yml` (it exists now); `make fetch KAS_CFG=kas/base.yml` fetches the same layers.
