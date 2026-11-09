# Demo: four tiers of the same build

*What each tier proves. For the commands in order - prerequisites, credentials, the one-command
demo and its traps - see [`RUNBOOK.md`](RUNBOOK.md).*

One tree, one build directory, one set of pinned layers. The tier is a **kas config
selection**, not a branch and not a copy of the tree - so the same sources, the same layer
commits and the same sstate cache produce all of them, and any two can be compared directly.
The first three tiers are the i.MX board; the fourth is an unrelated emulated machine sharing
the same glue.

| Tier | Config | Command | Signed by |
|---|---|---|---|
| **V0** baseline | `kas/base.yml` | `make build-min` | nothing |
| **V1** stock signing | `kas/all.yml` | `make build` | local R&D keys |
| **V2** service signing | `kas/laavat-live.yml` | `./kas-container --runtime-args "--network=container:<svc>" shell kas/laavat-live.yml -c 'bitbake <target> -c laavat_sign'` | the service (HSM keys); the boot image also keeps its dev-key signature |
| **QEMU** anchored | `kas/qemu-live.yml` | `make qemu-demo` | the service, and **only** the service |

`make verify KAS_CFG=<config>` checks each tier; for V1 and V2 every component is *required*,
so a skipped check is a failure.

The difference the tiers exist to show is where the private key lives. V0 and V1 keep it on the
build machine; V2 and the QEMU tier keep it in a Hardware Security Module (HSM) that signs on
request and has no operation that exports a key, so no build ever holds one.

## V0 - does it build and boot-image at all

The pinned Variscite Scarthgap BSP, `core-image-minimal`, no signing of any kind. This is the
control: if V1 fails, V0 tells you whether the BSP or the signing is at fault.

## V1 - the same image, signed the way a BSP signs it out of the box

HAB via `cst_signer` and the public `var-hab-certs` dev PKI, a FIT kernel signed with a key
poky generates on first build, kernel modules signed with the kernel's own ephemeral key, a
RAUC bundle signed with a generated dev certificate, dm-verity rootfs.

**No `meta-laavat` in `bblayers` at all.** This is the BSP's stock signing.

## V2 - the same targets, signed by the service

Same feature set as V1 plus OP-TEE, with five signing operations **added** at the service -
not moved: the dev-key signing keeps running. See the fragment/guard/glue table in `README.md`.

`make build KAS_CFG=kas/laavat-live.yml` will not reach the service: plain `make build` passes no
`--runtime-args`, so the build container cannot see it. Use the `kas-container` form above, which is
what `RUNBOOK.md` and `README.md` both give.

    make delta

diffs the flattened kas config of V1 against V2 and prints exactly what V2 adds: one
`bblayers` entry (`layers-50/meta-laavat`) and the `local.conf` lines. It is generated from the
configs themselves, so it cannot drift from what the build actually does.

`kas/laavat-live.yml` **includes** `kas/all.yml`, so the dev-key signing is not switched
off - for HAB the service signature is deployed *beside* the dev-key one as
`*.laavat-signed`, and the same input signed both ways is diffable.

Where the dev key stops mattering is not uniform, though, and "sidecar" describes where a
*file* lands rather than what the device trusts:

| Target | Dev key on this tier | What it takes to finish |
|---|---|---|
| OP-TEE TAs | **already gone** - `do_laavat_unpack` overwrites every `.ta` before packaging, and the core embeds the service's key as its anchor | nothing |
| RAUC bundle | **anchor already switched** - the dev key still signs during `do_bundle` (RAUC's own recommended shape), but `/etc/rauc/ca.cert.pem` is the *service's* issuing CA, pinned by digest, so the device refuses a dev-key bundle | deploy the `.laavat-signed` bundle |
| kernel FIT | **anchor already switched** - `laavat-fitkey` signs the copy U-Boot verifies, and `laavat-fitkey-uboot` puts the service's key in the control device tree the board appends | nothing |
| imx-boot (HAB) | still in force, and the PKI is the *public* `var-hab-certs` - the signature exercises the mechanism, it is not a security control | own `CST_CERTS_URI`, then a fused SRK hash |

So of the four artifact classes this tier signs, three already trust the service and nothing
else. **The one thing you would still be flashing dev-key signed is the boot image itself**,
because HAB's anchor is a hash fused into the SoC rather than anything a build can place.

There used to be a second i.MX tier here, and a `LAAVAT_FIT_ANCHOR` variable to select it:
the kernel FIT was signed but deployed as an unconsumed sidecar, leaving the control DTB
carrying the build's own key. The diff it existed for has been taken, so it is gone -
`LAAVAT_FIT_SIGN` now means the same thing on both machines.

## The QEMU tier - anchors, not just signatures

    make qemu-demo

builds `qemuarm64-secureboot` against the live service, boots it, and asserts what the boot
proves. Three of the four service-signed artifact classes are checked here - the boot image
is the exception, since HAB is the i.MX boot ROM's job and this machine has none. For each of
the three the *device's* trust anchor is the service's key and nothing else:

| Artifact | Operation | Anchor on the device | Placed by |
|---|---|---|---|
| kernel FIT | `SignKernel` | public key in U-Boot's control device tree | `laavat-fitkey` |
| trusted apps | `OP-TEESigning` | public key compiled into the TEE core | `laavat-optee` |
| update bundle | `RaucBundleSigningWithOneTimeKey` | issuing CA in `/etc/rauc/ca.cert.pem` | `laavat-rauc-keyring` |

There are no manual steps. The verification key is fetched from the service during the build,
pinned by digest and fail-closed; the control device tree and the update-bundle disk are both
produced by the harness at boot time.

### What the boot has to show

Every positive result is paired with negatives that must fail, and fail *for the right
reason* - otherwise a check can pass while proving nothing.

| Check | Claim |
|---|---|
| `ta-load-signed` | the TEE loaded a TA the service signed |
| `ta-reject-foreign` | it refused a TA signed with a **different key** - the anchor discriminates |
| `ta-reject-tampered` | it refused a **correctly signed TA with a flipped byte** - the signature covers the body |
| `bundle-verify` | the device verified the service-signed bundle |
| `bundle-reject-devkey` | it refused the same bundle dev-key signed |
| `bundle-reject-tampered` | it refused a service-signed bundle with a flipped byte |
| `uboot-fit-verified` | U-Boot verified the kernel before starting it (firmware log) |
| `uboot-fit-hash-refused` | with one byte of the kernel flipped, U-Boot says `Bad Data Hash` and stops. This is the FIT's hash node doing the work: the configuration signature still verifies on the tampered image, because it covers the hash *values*, not the bytes. A tamper that also recomputes `hash-1` is what would exercise the signature, and no boot does that yet. |
| `fit-tamper-refused` | and the tampered kernel **never reaches userspace** |

Each tamper is deterministic, not random: an earlier version corrupted the TA with
`/dev/urandom` and the outcome varied per boot - usually a clean refusal, occasionally a
kernel oops in `tee-supplicant` that left the remaining checks unrun. A gate cannot be a coin
flip.

The TA tamper gets a **boot of its own**, and it is the only check in it. Two facts force
that: the corruption has to happen before anything loads the TA, because the core keeps a
loaded TA resident and serves the resident copy - measured, by moving the check after
`ta-load-signed` and watching it turn into a FAIL - and refusing a corrupted TA sometimes
oopses `tee-supplicant`, which wedges every later TA check. One boot cannot satisfy both, so
`make qemu-demo` boots three times: the checks, the TA tamper, the kernel tamper.
The kernel tamper flips a byte in place, at the offset ext4 reports for `/fitImage`, so every
other byte of the disk is identical and the boot can only have failed because of that byte.

### The one machine-specific workaround

`qemuarm64-secureboot` sets `OF_BOARD`: U-Boot takes its control device tree from QEMU and
builds no `u-boot.dtb`, so there is nothing for the build to inject the key into. The config
says so explicitly with `LAAVAT_FIT_REQUIRE_CONTROL_DTB = "0"`, and the harness keys the tree
QEMU passes instead. That is a property of the emulated machine rather than of signing, so it
lives in `scripts/boot-verify.py` and not in `meta-laavat`.

On a machine that appends its own control device tree, `laavat-fitkey-uboot` puts the key
there during the build, and poky's own `fit_check_sign` then verifies the service's signature
against the service's key as part of the u-boot recipe. That path is not left to inference:
the i.MX tier runs it, and `bitbake u-boot-variscite` there logs
`sha256,rsa2048:laavat+ OK` with the deployed `u-boot.dtb-signed` carrying the service key's
`rsa,modulus`. Built and verified; **not booted on hardware**.

## Getting `meta-laavat`

    make fetch-laavat                                   # github.com/laavat/meta-laavat at LAAVAT_REF
    make fetch-laavat LAAVAT_SRC=/path/to/meta-laavat   # a local checkout instead

`LAAVAT_REF` (in the Makefile) is the release tag the test-bed was last verified against.

The `signing-tool` client comes from PyPI through the layer's own recipe - nothing to build
by hand.

## Credentials

V0 and V1 need none. V2 and the QEMU tier need a reachable service, a token file and the
product/operation UUIDs - see `README.md` "Signing against a real service". Four of the five
targets also run against `scripts/laavat-stub.py` with no service and no credentials at all;
OP-TEE is live-only, because the stub serves neither `OP-TEESigning` nor `getpubkey`.

In CI the sign tasks are ordinary bitbake tasks flagged `[network] = "1"`. The runner needs
egress to the API *and* to the presigned storage URLs, the token written `0600` with its **path**
in `LAAVAT_TOKEN_FILE` (passed through `BB_ENV_PASSTHROUGH_ADDITIONS`), and
`LAAVAT_STATE_DIR` outside `WORKDIR` so an interrupted job resumes its request instead of
submitting a second one. Without an approver token the build blocks up to
`LAAVAT_SIGN_TIMEOUT` (default 1800 s) waiting for a human to approve.
