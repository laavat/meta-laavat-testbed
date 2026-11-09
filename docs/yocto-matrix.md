# Which Yocto releases meta-laavat works on

Tested by parsing the QEMU tier on each release and checking every class still wires:
`make styhead`, `make walnascar`, `make whinlatter`, `make wrynose` (and `make check-layer`
for Yocto's own layer QA). The last column is a parse result (`bitbake -p`), not a full
build.

| Yocto | Codename | Built from | FIT | RAUC | OP-TEE | Parse |
|---|---|---|---|---|---|---|
| 5.0 LTS | scarthgap | poky | `laavat-fitkey` | ok | ok | 0 errors |
| 5.1 | styhead | poky | `laavat-fitkey` | ok | ok | 0 errors |
| 5.2 | walnascar | poky | `laavat-fitkey` | ok | ok | 0 errors |
| 5.3 | whinlatter | **bitbake + oe-core + meta-yocto** | **`laavat-fitimage`** | ok | ok | 0 errors |
| **6.0 LTS** | **wrynose** | bitbake + oe-core + meta-yocto | `laavat-fitimage` | ok | ok | 0 errors |

`LAYERSERIES_COMPAT_laavat` names all five, and each parses with 0 errors.

**Yocto 6.0 is `wrynose`.** Releases are named after Lake District passes, not after their
version, so looking for a branch called 6.0 finds nothing and invites the wrong conclusion.
`meta-yocto/wrynose` carries `DISTRO_VERSION = "6.0.3"`, and it needs **bitbake 2.18**
(`BB_MIN_VERSION = "2.18.0"`).

## poky is finished, as of the 6.0 LTS

The [poky repository](https://git.yoctoproject.org/poky)'s master branch has been retired.
Its README now reads:

> The poky repository master branch is no longer being updated.

and points at either separate clones of `bitbake` + `openembedded-core` + `meta-yocto`, or
the new `bitbake-setup` tool. poky's release branches stop at **walnascar (5.2)**; there is
no whinlatter branch and no 6.0 branch. The upstream announcement gave the reason and the
timing:

> If we're going to make a change, we really want this in the next LTS release, which is
> April 2026.

So **Yocto 6.0 is not poky-based**, and any tooling that assumes "clone poky" stops at 5.2.
`kas/whinlatter.yml` is what a post-poky config looks like:

- `bitbake` at branch `2.16` (oe-core whinlatter sets `BB_MIN_VERSION = "2.15.2"`), checked
  out as a sibling of oe-core because `scripts/oe-buildenv-internal` resolves
  `BITBAKEDIR="$OEROOT/../bitbake"`, and marked `.: excluded` in kas because **bitbake is
  not a layer** - add it to bblayers and parsing dies looking for `conf/layer.conf`.
- `openembedded-core` provides `meta` and the `oe-init-build-env` kas looks for.
- `meta-yocto` provides `meta-poky`; the poky *distro* still exists, only the repo is gone.

6.0 is tested: it is the `wrynose` row above, and it is the release the post-poky change
was made for - built from bitbake + oe-core + meta-yocto exactly as 5.3 is. `poky`'s master
branch stays a README; there is nothing there to test.

## The one real break: FIT moved in 5.3

5.3 replaced `kernel-fitimage.bbclass` with `kernel-fit-image.bbclass` and moved the FIT out
of the kernel recipe into its own, `linux-yocto-fitimage`. `kernel.bbclass` now errors if
`fitImage` is still named in `KERNEL_IMAGETYPE`. Every hook the old class used is gone:

    do_assemble_fitimage          no references in oe-core whinlatter
    do_kernel_generate_rsa_keys   gone
    fitImage-none                 gone

So `laavat-fitkey` cannot work on 5.3, and the port is a second class rather than a patch,
because it attaches to a different recipe:

| | <= 5.2 | >= 5.3 |
|---|---|---|
| class | `laavat-fitkey` | `laavat-fitimage` |
| inherit on | the kernel recipe | `linux-yocto-fitimage` |
| signs | `${B}/${KERNEL_OUTPUT_DIR}/fitImage-none` | `${B}/fitImage` |

Everything they share - fetching the service key, writing the placeholder private key and
the service certificate, installing the signed FIT back - lives in `laavat-fitkey-base`, so
neither copy can drift from the other. The u-boot half (`laavat-fitkey-uboot`) is unchanged
on both.

`laavat-fitkey` now fails at parse time on 5.3 with a message naming the replacement, rather
than with a confusing missing-task error.

## Test-bed structure notes

- **Each release needs its own checkout path and its own build dir.** `kas checkout`
  rewrites `build/conf/bblayers.conf`, and leaving one release's bitbake pointed at
  another's metadata fails as `ImportError: cannot import name 'multiprocessing' from 'bb'`,
  which names nothing useful.
- `sample-qemu-arm64`'s kernel bbappend tests `kernel-fitimage in KERNEL_CLASSES` as well as
  the usual guard, so the one layer works either side of 5.3. A real integrator targets one
  release and needs only one of the two bbappends; only this test-bed spans releases.
- `sample-qemu-arm64-yocto53` exists for the same reason: its bbappend names
  `linux-yocto-fitimage`, which does not exist before 5.3, and a bbappend with no matching
  recipe is a hard error rather than a no-op.
