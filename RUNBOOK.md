# Runbook: build it, sign it, demo it

Copy-pasteable, in order, from an empty directory to a boot log that proves the
service signed the kernel. The signing keys never reach your build machine: they stay
in a Hardware Security Module (HSM), which signs on request and has no operation that
exports a private key.

## Start here

If you just want it running, this is the whole thing:

    git clone https://github.com/laavat/meta-laavat-testbed.git && cd meta-laavat-testbed
    make fetch
    make fetch-laavat
    mkdir -p build/logs                                  # build/ is gitignored
    setsid nohup make build > build/logs/v1.log 2>&1 &   # ~2 h, dev keys, no account

then, once that build has finished (`tail -f build/logs/v1.log`):

    make verify                                          # one PASS/FAIL line per component

That is **Path A** below: a complete signed i.MX8MM image using local development
keys, with no LAAVAT account and no network beyond source fetching. Path B then
exercises the signing task against a local stub, and Path C is the real demo
against a LAAVAT service. Read section 0 first if anything above is unfamiliar.

### What this repo is

A **test-bed**, not a product: a working Yocto build wired to every signing path
`meta-laavat` supports, so you can watch the mechanism work before putting it in
your own BSP. `meta-laavat` is the layer that does the signing; this repo is the
worked example around it. If your goal is to add signing to a build you already
have, read the [integration guide](https://github.com/laavat/meta-laavat/blob/main/docs/INTEGRATION.md)
instead - this runbook is for running *this* tree.

### Which file to read

| File | Answers |
|---|---|
| **`RUNBOOK.md`** (this one) | *How do I run it?* Commands in order, prerequisites, traps. |
| `DEMO.md` | *What does each tier prove?* The V0/V1/V2/QEMU tiers and their claims. |
| `README.md` | *Why is it built this way?* Design rationale, per-target wiring, findings. |
| [meta-laavat `docs/INTEGRATION.md`](https://github.com/laavat/meta-laavat/blob/main/docs/INTEGRATION.md) | *How do I add signing to my own build?* |
| [meta-laavat `README.md`](https://github.com/laavat/meta-laavat/blob/main/README.md) | Reference: every variable and the verification rules. |
| `docs/presentation/getting-started.html` | The same ground with diagrams, in a browser - plus how to get the layer into a build that does not use kas. |

---

Three paths, and they get progressively more demanding. Start at the top.

| Path | Needs | Time (12 cores) | What you end up with |
|---|---|---|---|
| **A. Build it** | Docker/Podman, 35 GB | ~70 min / ~2 h | An i.MX8MM image signed with dev keys - no LAAVAT account required |
| **B. Sign one artifact** | + a signing stub | +5 min | `do_laavat_sign` exercised end to end, still no account |
| **C. The demo** | + a reachable LAAVAT service | +~2 h cold | A boot log where the device verifies the service-signed kernel, trusted applications and update bundle - and refuses tampered copies of each |

Path C is the demo. Paths A and B exist so that if C fails you know which half broke.

---

## 0. Prerequisites

### What `kas-container` is, and why you need nothing else

You do **not** install bitbake, set up a build host, or run
`oe-init-build-env` here. [kas](https://kas.readthedocs.io/) is a Siemens tool
that describes a whole Yocto build - which layers, which commits, which machine,
which `local.conf` lines - in one YAML file, so `kas build kas/all.yml` replaces
"clone eight repos, write bblayers.conf, source the env, run bitbake".

`kas-container` is a shell script that runs kas inside a container image with the
build host already set up in it. So the only thing your machine needs is a
container engine; the compiler, Python, bitbake and every build dependency live in
the image. The script is vendored in this repo (`./kas-container`, byte-identical
to upstream tag 4.7) so you do not install kas either.

If you are used to `repo` + `oe-init-build-env`, a **kas config** is the
equivalent of a manifest and a `local.conf` fused into one file, and configs
compose: `kas/all.yml` is `kas/base.yml` plus one fragment per feature. `make
shell` drops you into an ordinary bitbake environment inside that container if you
would rather drive it by hand.

### On the host

- **Linux x86-64.** The BSP layers and the container image assume it.
- **A container engine**: Docker or Podman. kas-container picks whichever it
  finds. With Docker your user must be able to reach the daemon -
  `docker info` printing without `sudo` is the check; if it does not, add
  yourself to the `docker` group and log in again, or use rootless Docker.
- **`git`, `make`, `openssl`**, plus the coreutils/`awk`/`diff` that `make disk`
  and `make delta` use (`rsync` too, if you install the layer from a local checkout).
  `openssl` generates the throwaway RAUC dev keys (`make dev-keys`, run automatically).
  That is the complete list - everything else is inside the container, and nothing on
  the host runs `python3`.
  There is deliberately **no bitbake, no Python package and no `signing-tool`**
  on the host; the signing client is built from PyPI by the layer's own recipe
  during the build.
- **~35 GB free** on the filesystem holding `build/`, plus room for the container
  image. btrfs with compression is fine; `make disk` reports the truth (`du` lies
  under compression) and exits 1 under 10 GB.
- **RAM and cores** are the wall-clock knob, not a hard floor: 8 GB is workable,
  16 GB comfortable, and the times quoted here are for 12 cores. Half the cores
  is roughly twice the wait.

### Network

- **GitHub**, **PyPI** and **`downloads.yoctoproject.org`** for sources. `imx-cst`'s Debian
  URL 404s upstream and is served by the Yocto source mirror instead, so a proxy
  that blocks the mirror breaks the HAB tier specifically.
- Nothing else for Paths A and B. Path C additionally needs egress to your LAAVAT
  API **and** to the storage URLs it hands back - see C1.

Once the repo is cloned:

    make disk        # free space, largest build dirs, docker usage

**Launch every long build detached.** A build killed mid-compile truncates `.o`
files, and the next run fails with a bogus "undefined reference" in openssl or
sqlite3 that looks like a source problem and is not:

    mkdir -p build/logs
    setsid nohup make build > build/logs/build.log 2>&1 &

---

## 1. Get the tree and the layer

    git clone https://github.com/laavat/meta-laavat-testbed.git
    cd meta-laavat-testbed
    make fetch          # clone the pinned BSP layers into layers-50/
    make fetch-laavat   # install meta-laavat itself

`make fetch` is `kas checkout`: it clones every BSP layer at the exact commit the
kas configs pin, into `layers-50/`. Nothing is built.

`make fetch-laavat` clones [meta-laavat](https://github.com/laavat/meta-laavat) into
`layers-50/meta-laavat/` at `LAAVAT_REF`, the release tag set in the Makefile. To work on
the layer itself, point it at your own checkout instead:

    make fetch-laavat LAAVAT_SRC=/path/to/meta-laavat

`layers-50/` is gitignored, and with `LAAVAT_SRC` `fetch-laavat` rsyncs with `--delete`.
**Never edit anything under `layers-50/meta-laavat/`** - edit your checkout and re-run
`make fetch-laavat LAAVAT_SRC=...`.

Success: `ls layers-50/` lists `poky` and `meta-laavat` alongside the BSP layers.

---

## Path A - build it, no service, no account

`DEMO.md` calls the tiers V0/V1/V2; you only need two of them here. **V0** is the
stock BSP with no signing at all, **V1** is the same image with every signing path
switched on using local development keys. Both are ordinary Yocto builds.

**One at a time** - they share `build/tmp`, and bitbake holds a lock on it:

    mkdir -p build/logs
    setsid nohup make build-min > build/logs/v0.log 2>&1 &   # V0, ~70 min

wait for that to finish, then:

    setsid nohup make build > build/logs/v1.log 2>&1 &       # V1, ~2 h
    make verify                                              # PASS/FAIL per component

You can skip straight to V1; V0 is the control. If V1 fails, V0 tells you whether
the BSP or the signing is at fault - which is worth the extra hour the first time
you build on a new host, and never again after that.

Follow a running build with `tail -f build/logs/v1.log`. Nothing is signed by a
service on this path, so it needs no credentials at all.

`make verify` prints one line per component and exits 1 on any FAIL. Under the
default `KAS_CFG=kas/all.yml` every component is *required*, so a SKIP is also a
failure:

    PASS baseline
    PASS fit
    PASS hab
    PASS modsign
    PASS rauc
    PASS verity
    SKIP optee (optee not in MACHINE_FEATURES)

`kas/all.yml` does not enable OP-TEE, so that SKIP is expected and is not required
for this tier - it does not fail the run.

One feature at a time, if you want to see them in isolation:

    make build KAS_CFG=kas/fit.yml    # or hab, modsign, rauc, verity, optee
    make verify KAS_CFG=kas/fit.yml REQUIRE=fit

`REQUIRE` is what makes a SKIP fail. It is set automatically only for the two whole-tier
configs, so on a single-feature config `make verify` prints the right lines but exits 0 even
if the component it is checking skipped entirely - name the component to gate it.

These share one `build/tmp`, so building a single-feature config **replaces** the
deploy directory: a plain `kas/optee.yml` build drops the HAB-signed `imx-boot`,
and `make verify KAS_CFG=kas/all.yml` afterwards reports those as FAIL until you
rebuild. That is displacement, not breakage.

---

## Path B - sign one artifact with no service at all

`scripts/laavat-stub.py` answers the signing API on the container's own loopback.
No credentials, no network, no account. It covers every wired target except OP-TEE,
which is live-only (the stub serves neither `OP-TEESigning` nor `getpubkey`).

The `BB_ENV_PASSTHROUGH_ADDITIONS` line matters: bitbake empties the environment it
gives a task and repopulates it only from variables it was told to keep, so an
exported variable that is not named there never reaches the signing task.

    ./kas-container shell kas/laavat/common.yml -c '
      printf "%s" dummy-token > /tmp/laavat-token && chmod 600 /tmp/laavat-token
      export LAAVAT_TOKEN_FILE=/tmp/laavat-token
      export BB_ENV_PASSTHROUGH_ADDITIONS="$BB_ENV_PASSTHROUGH_ADDITIONS LAAVAT_TOKEN_FILE"
      python3 /work/scripts/laavat-stub.py --port 8943 & sleep 1
      bitbake laavat-sign-smoke -c laavat_sign'

Success: `log.do_laavat_sign` ends with the digest the class verified, and
`build/tmp/work/*/laavat-sign-smoke/*/*/payload.fit.signed` exists.

Check the *other* direction too - a class that only ever succeeds proves nothing:

    ./kas-container shell kas/laavat/common.yml -c '
      printf "%s" dummy-token > /tmp/laavat-token && chmod 600 /tmp/laavat-token
      export LAAVAT_TOKEN_FILE=/tmp/laavat-token
      export BB_ENV_PASSTHROUGH_ADDITIONS="$BB_ENV_PASSTHROUGH_ADDITIONS LAAVAT_TOKEN_FILE"
      python3 /work/scripts/laavat-stub.py --port 8943 --corrupt-digest & sleep 1
      bitbake laavat-sign-smoke -c laavat_sign -f'

The task must **fail** and leave no output. Re-runs need `-f`; the task is stamped.

Swap `kas/laavat/common.yml` for `kas/laavat/hab.yml`, `kas/laavat/fit.yml` or
`kas/laavat/rauc.yml` and the matching recipe (`imx-boot`, `linux-variscite`,
`sample-variscite-imx8mm-bundle`) to exercise the others - README writes each one out in full.

---

## Path C - the demo

### C1. You need a reachable LAAVAT service

This is the one prerequisite the repo cannot provide. You need:

- an **API URL**,
- a **writer token** (a user in the requester group),
- an **approver token** - or nothing, and a human approves each request within
  `LAAVAT_SIGN_TIMEOUT` (1800 s),
- the service's **CA bundle**, if it uses a private CA,
- and **one product UUID + operation UUID pair per signing target** - the tier's
  `*-live.yml` names every pair it needs.

**First, the credentials.** Put them in `build/laavat/` (gitignored); the kas container
sees that directory as `/build/laavat/`:

    mkdir -p build/laavat
    printf '%s' "$WRITER_TOKEN"   > build/laavat/token-writer.jwt
    printf '%s' "$APPROVER_TOKEN" > build/laavat/token-approver.jwt
    chmod 600 build/laavat/token-*.jwt
    cp /path/to/ca.crt              build/laavat/combined_ca.crt

**Then the ids.** Nothing on your host has `signing-tool` - it is built inside the
container - so the simplest route is to install it where you are:

    pip install signing-tool
    signing-tool -c -a "$URL" -t @build/laavat/token-writer.jwt product getall
    signing-tool -c -a "$URL" -t @build/laavat/token-writer.jwt product get -P <product-id>

To use the one the build makes instead, get a shell in its environment - this builds the
recipe, so it needs a route to the service (C2) if the layer is not staged yet:

    ./kas-container shell kas/qemu-live.yml -c 'bitbake signing-tool-native -c devshell'

The first call lists products with their UUIDs; the second lists that product's operations
with theirs. Each target needs one product id, one operation id, and the operation's *name*.

**Then the config.** Edit `kas/qemu-live.yml` in place, replacing the API URL, the
product/operation pairs and the key pins under its `live:` section - nothing else in that
file is site-specific. Editing in place matters: `make qemu-demo` builds
`QEMU_CFG ?= kas/qemu-live.yml`, so a copy under another name is not what runs unless you
say so:

    make qemu-demo QEMU_CFG=kas/my-live.yml

(For the i.MX tier the file is `kas/laavat-live.yml`, which wires more targets and so needs
more pairs; the same applies - the commands below name that file, not a copy of it.)

**Never `--skipssl`.** A CA bundle is the fix; the client honours
`REQUESTS_CA_BUNDLE`, which the config exports.

### C2. Reach the service from inside the build container

The build runs in its own container, and it needs HTTPS access to the API URL **and**
to the storage host named in the presigned upload and download URLs the service hands
back. On an ordinary network that needs nothing extra. If the container needs extra
arguments to get there - a particular Docker network, `--network=host` - pass them
through `KAS_RUNTIME_ARGS`, which every Makefile target that reaches the service uses:

    make qemu-demo KAS_RUNTIME_ARGS="--network=host"

and `--runtime-args` when you call `./kas-container` yourself.

Prove connectivity before spending a two-hour build:

    ./kas-container shell kas/qemu-live.yml -c 'curl --cacert /build/laavat/combined_ca.crt \
        <api-url>/products'

If that fails, no bitbake wiring will fix it.

### C3. Run it

    mkdir -p build/logs
    setsid nohup make qemu-demo > build/logs/qemu-demo.log 2>&1 &

One command, four phases, no manual step:

1. **build** `core-image-minimal` + a RAUC bundle for `qemuarm64-secureboot`, with
   three live signing calls (`SignKernel`, `OP-TEESigning`,
   `RaucBundleSigningWithOneTimeKey`) and two key fetches - the OP-TEE TA anchor and
   the FIT verification key - in the middle of it
2. **boot** and require every runtime check and firmware marker the Makefile names
3. **boot again** with a corrupted signed TA, and require the TEE to refuse it
4. **boot again** with one byte of the kernel flipped, and require U-Boot to stop

Roughly two hours cold; about ten minutes warm. The first two boots stop as soon as
their completion marker appears; the kernel-tamper boot has no marker to wait for - a
correctly refused boot never reaches userspace - so it runs out its `--timeout 300`.
The TA tamper gets a boot of its own for two measured reasons: see `DEMO.md`.

The phases are separate targets, so after a successful build you can re-run only
the boots (they need no service):

    make qemu-boot qemu-ta-tamper qemu-tamper

### C4. What a passing run prints

```
  optee-present          PASS
  supplicant             PASS  <pid>
  ta-present-signed      PASS
  ta-load-signed         PASS  TEE test application done!
  ta-reject-foreign      PASS  refused: ...
  bundle-verify          PASS
  bundle-reject-devkey   PASS  refused: ...
  bundle-reject-tampered PASS  refused: ...
  uboot-fit-verified     PASS     (firmware log)
  optee-initialised      PASS     (firmware log)

all checks passed
```

then, in boot 2, `ta-reject-tampered PASS refused`, and in boot 3
`uboot-fit-refused PASS` and `fit-tamper-refused PASS`. The run exits 0 only if every
assertion in all three boots passed; a missing check is a failure, not a skip.

The line that carries the weight is in the firmware log:

    Verifying Hash Integrity ... sha256,rsa2048:laavat+ OK

`laavat` there is only a key *name*. What makes it meaningful is which key sits
behind it: the certificate in that control device tree carries the modulus of the
`SignKernel` operation's public key, as fetched from the service and pinned by
`LAAVAT_FIT_PUBKEY_SHA256`. Serial logs land in `build/logs/boot*.log`.

---

## Signing the i.MX tier against the service

The QEMU tier is the one verified at runtime. The i.MX tier signs the same targets
and anchors the device to the service for all of them except the boot image, which is
also deployed as a `*.laavat-signed` **sidecar** beside the dev-key one - HAB's anchor
is a hash fused into the SoC, so no build can place it.

    make delta            # exactly what V2 adds to V1: one bblayers entry + local.conf lines

Then one target at a time:

    ./kas-container shell kas/laavat-live.yml -c 'bitbake laavat-sign-smoke -c laavat_sign'

and again with each of these in place of that last argument:

    bitbake imx-boot           -c laavat_sign     # SignHAB, hab-archive-v1
    bitbake linux-variscite    -c laavat_sign     # SignKernel
    bitbake sample-variscite-imx8mm-bundle -c laavat_sign     # RaucBundleSigningWithOneTimeKey
    bitbake optee-os           -c laavat_unpack   # OP-TEESigning

**Always name the task.** On a warm cache a plain `bitbake <recipe>` can cover
`do_laavat_sign` with a `do_deploy` setscene hit and sign nothing, silently.

---

## Troubleshooting

**The signing task did not run and there was no error.** Setscene coverage. Name
the task: `bitbake <recipe> -c laavat_sign`.

**`LAAVAT_TOKEN_FILE must point at a readable token file`.** The variable is set in
your shell but bitbake dropped it - add it to `BB_ENV_PASSTHROUGH_ADDITIONS`, or
name the path in `local.conf` as the kas configs do.

**`digest mismatch for <request>`.** A genuine mismatch: the client checks the
download against the reported digest in both storage encodings, so this is a
corrupted or substituted download, not configuration. Nothing was installed.

**An authorization error from the service.** The token expired; tokens are
short-lived. Write a fresh one to the same path and re-run - the pending request is
resumed, not duplicated.

**The task waited and then timed out.** The request is still alive. Approve it and
re-run the task; `NOTE: resuming signing request <id>` confirms it was picked up
rather than duplicated.

**Bogus "undefined reference" in openssl/gdbm/sqlite3.** A previous build was killed
mid-compile and truncated its object files. Wipe that tune's work and stamps -
`cortexa57-poky-linux` and `qemuarm64_secureboot-poky-linux` are the QEMU tier's,
i.MX uses `cortexa53-crypto*` - rather than chasing it recipe by recipe. Then launch
detached (section 0).

**A `.bbappend` seems to do nothing.** A dangling bbappend is an *error*
("No recipes in default available for"), not a no-op. Confirm with
`bitbake-layers show-appends`; a silently-dropped append parses identically to a
clean one.

**Massive sstate misses on a config you just added.** `local.conf` drift. A
`DISTRO_FEATURES` that differs by one word rebuilds every native from scratch. Any
new tier must `include: kas/core.yml` verbatim rather than hand-copy its
`local_conf_header`.

**Out of disk.** `make disk`, then `make clean-tmp` (keeps `downloads/` and
`sstate-cache/`). `docker image prune -f` and `docker builder prune -f` are safe.

---

## What this proves, and what it does not

Proven, observed rather than inferred:

- Four artifact classes signed by a live service during `bitbake`: the boot image,
  the kernel FIT, the OP-TEE trusted applications and the RAUC update bundle.
- Three of those four - kernel, trusted applications, bundle - verified **at runtime
  by the device** against a key the service owns and nothing else.
- Each of those three keys refuses a tampered artifact, with the refusal read out
  of the boot log.
- The u-boot half of the FIT anchor on a machine that owns its control device tree
  (the i.MX tier), verified at build time by poky's own
  `fit_check_sign` - the verdict is in the bitbake task log, not in `build/logs/`:
  `build/tmp/work/imx8mm_var_dart-poky-linux/u-boot-variscite/*/temp/log.do_uboot_assemble_fitimage.*`
  ends `sha256,rsa2048:laavat+ / OK`, and the deployed `u-boot.dtb` carries the
  service key's `key-name-hint`.

Not proven:

- **The boot image is signed but the weakest-proven of the four.** The service-signed
  image is only *inspected* (`scripts/ivt-csf.py` shows CSF blocks at the SPL and
  U-Boot IVTs) - that is a header dump, not a signature check, and no offline
  verification of the service-signed image has been run. Its real check is the i.MX
  boot ROM against an SRK hash burned into fuses, which no emulator models and which
  is a one-way door on hardware. On the i.MX tier it is also still deployed beside
  the dev-key image.
- **Kernel modules never reach the service at all** - the kernel signs each `.ko`
  during its own build, so there is no per-artifact step to hook and no service
  operation for one.
- **No board has booted any of this.** `qemuarm64-secureboot` is not an i.MX8MM,
  and its OP-TEE is 4.1 against the board's 4.4. What the QEMU tier demonstrates is
  that the glue, the anchors and the formats verify at runtime - not that the board
  boots.
- The i.MX HAB tier still deploys sidecars; the flashable image is dev-key signed,
  and no SRK hash is fused.
