# meta-laavat test-bed — thin wrapper around kas-container.
# KAS_CFG selects the feature set: kas/base.yml (unsigned baseline) … kas/all.yml (everything).
# Single feature: KAS_CFG=kas/{fit,hab,modsign,rauc,verity,optee}.yml. optee is not in all.yml.
KAS      ?= ./kas-container
KAS_CFG  ?= kas/all.yml
# The demo's two signed tiers: same feature set, dev keys vs the service. See DEMO.md.
V1_CFG   ?= kas/all.yml
V2_CFG   ?= kas/laavat-live.yml
# with everything enabled every component must really be checked: a SKIP then fails
# Runtime checks the image must print, and firmware markers the boot log must show.
REQUIRE_CHECKS  ?=
REQUIRE_MARKERS ?=
REQUIRE  ?= $(strip \
  $(if $(filter $(V1_CFG),$(KAS_CFG)),baseline fit hab modsign rauc verity) \
  $(if $(filter $(V2_CFG),$(KAS_CFG)),baseline fit hab modsign rauc verity optee))
# meta-laavat under test: cloned from its public repository at a pinned release by
# `make fetch-laavat`. LAAVAT_SRC=/path/to/meta-laavat installs a local checkout instead,
# for working on the layer itself. The signing-tool client comes from PyPI, through the
# layer's own recipe.
LAAVAT_URL ?= https://github.com/laavat/meta-laavat.git
LAAVAT_REF ?= v1.0.0
LAAVAT_SRC ?=

# Extra container arguments for the tiers that reach a signing service, e.g. a docker
# network: KAS_RUNTIME_ARGS="--network=host". Empty by default.
KAS_RUNTIME_ARGS ?=
KAS_RUN = $(KAS) $(if $(strip $(KAS_RUNTIME_ARGS)),--runtime-args "$(KAS_RUNTIME_ARGS)")

.PHONY: fetch fetch-laavat dev-keys build build-min shell verify boot delta disk clean-tmp
.PHONY: qemu-demo qemu-build qemu-boot qemu-tamper qemu-ta-tamper qemu-tools
.PHONY: simplicity stub-smoke skip-smoke walnascar styhead whinlatter wrynose yocto-matrix check-layer

fetch: dev-keys   ## clone/checkout all layers at their pinned commits (no build)
	$(KAS) checkout $(KAS_CFG)

# Throwaway RAUC keys for the dev-key tiers: `rauc bundle` refuses to run without one,
# even where the service re-signs the bundle afterwards. Generated on first use, never
# committed; see scripts/gen-dev-keys.sh.
dev-keys:         ## generate the throwaway RAUC dev keys (once; kept until deleted)
	@./scripts/gen-dev-keys.sh

fetch-laavat:     ## install meta-laavat at $(LAAVAT_REF), or from LAAVAT_SRC=<checkout>
	@if [ -n "$(LAAVAT_SRC)" ]; then \
	    mkdir -p layers-50/meta-laavat; \
	    rsync -a --delete --delete-excluded \
	        --exclude .git --exclude __pycache__ --exclude .pytest_cache \
	        "$(LAAVAT_SRC)/" layers-50/meta-laavat/; \
	    echo "meta-laavat: installed from $(LAAVAT_SRC)"; \
	  else \
	    if [ -e layers-50/meta-laavat ] && [ ! -d layers-50/meta-laavat/.git ]; then \
	        echo "fetch-laavat: layers-50/meta-laavat exists but is not a git checkout"; \
	        echo "  (installed from LAAVAT_SRC earlier?). Remove it, then re-run."; exit 1; \
	    fi; \
	    [ -d layers-50/meta-laavat ] || git clone --quiet $(LAAVAT_URL) layers-50/meta-laavat; \
	    git -C layers-50/meta-laavat fetch --quiet --tags origin; \
	    git -C layers-50/meta-laavat checkout --quiet --detach $(LAAVAT_REF); \
	    echo "meta-laavat: $(LAAVAT_REF) ($$(git -C layers-50/meta-laavat rev-parse --short HEAD))"; \
	  fi

build build-min: dev-keys | build/logs

build:            ## build $(KAS_CFG) (default: everything signed)
	$(KAS) build $(KAS_CFG)

build-min:        ## unsigned baseline: proves BSP + distro + image
	$(KAS) build kas/base.yml

build/logs:       # for the operator's `nohup make build > build/logs/x.log` redirect
	mkdir -p $@

shell:            ## bitbake shell inside the container for $(KAS_CFG)
	$(KAS) shell $(KAS_CFG)

# The QEMU demo. One command from sources to a boot that proves the service signed the
# kernel, the trusted applications and the update bundle - and that the device refuses
# the things it should. Every check is required: a skipped one is a failure.
QEMU_CFG     ?= kas/qemu-live.yml
QEMU_CHECKS  ?= optee-present,supplicant,ta-present-signed,ta-load-signed,ta-reject-foreign,bundle-verify,bundle-reject-devkey,bundle-reject-tampered
QEMU_MARKERS ?= uboot-fit-verified,optee-initialised
# Container paths: these are read inside kas, where the build directory is /build.
QEMU_DEPLOY  ?= /build/tmp/deploy/images/qemuarm64-secureboot
FIT_KEY_DIR  ?= /build/keys/fit
# The boot harness runs these through oe-run-native, which needs each recipe's own
# recipe-sysroot-native - exactly what rm_work deletes once the recipe is built. Staging
# them again is cheap and self-healing; excluding them from rm_work would not be, because
# it cannot restore a sysroot that has already been removed.
QEMU_NATIVE  ?= u-boot-tools-native dtc-native e2fsprogs-native dosfstools-native mtools-native

qemu-demo: qemu-build qemu-boot qemu-ta-tamper qemu-tamper  ## build against the live service, prove it boots and verifies, and prove a tampered kernel does not

qemu-build: fetch-laavat dev-keys  ## build $(QEMU_CFG) against the live service
	$(KAS_RUN) build $(QEMU_CFG)

qemu-tools:       ## stage the native tools the boot harness runs
	$(KAS) shell $(QEMU_CFG) -c 'bitbake -c addto_recipe_sysroot $(QEMU_NATIVE)'

qemu-boot: qemu-tools  ## boot the built image, requiring every check and firmware marker
	$(KAS) shell $(QEMU_CFG) -c 'python3 /work/scripts/boot-verify.py \
	    --fit-key-dir $(FIT_KEY_DIR) --bundle-disk $(QEMU_DEPLOY) \
	    --log /build/logs/boot.log \
	    --require "$(QEMU_CHECKS)" --require-markers "$(QEMU_MARKERS)"'

qemu-ta-tamper: qemu-tools  ## corrupt a signed TA and require the TEE to refuse it
	$(KAS) shell $(QEMU_CFG) -c 'python3 /work/scripts/boot-verify.py \
	    --fit-key-dir $(FIT_KEY_DIR) --bundle-disk $(QEMU_DEPLOY) --ta-tamper \
	    --require ta-reject-tampered --log /build/logs/boot-ta-tamper.log'

qemu-tamper: qemu-tools  ## flip one byte in the signed kernel and require the boot to stop
	$(KAS) shell $(QEMU_CFG) -c 'python3 /work/scripts/boot-verify.py \
	    --fit-key-dir $(FIT_KEY_DIR) --tamper-fit $(QEMU_DEPLOY) \
	    --require-markers uboot-fit-hash-refused --timeout 300 --log /build/logs/boot-tamper.log'

boot:             ## boot $(KAS_CFG)'s image under QEMU and check the serial log
	$(KAS) shell $(KAS_CFG) -c 'python3 /work/scripts/boot-verify.py \
	    --require "$(REQUIRE_CHECKS)" --require-markers "$(REQUIRE_MARKERS)"'

verify:           ## host-side signature checks for $(KAS_CFG)
	$(KAS) shell $(KAS_CFG) -c 'REQUIRE="$(REQUIRE)" /work/scripts/verify-signing.sh'

delta:            ## what V2 adds to V1: the layer entry and the local.conf lines
	@mkdir -p build
	@$(KAS) dump $(V1_CFG) > build/delta-v1.yml
	@$(KAS) dump $(V2_CFG) > build/delta-v2.yml
	@diff -u --label $(V1_CFG) --label $(V2_CFG) build/delta-v1.yml build/delta-v2.yml || true

simplicity:       ## how many lines does integrating meta-laavat cost, per BSP
	./scripts/simplicity.sh

# The signing checks that need no credentials; everything else that exercises a signing
# path needs a live service. Uses the signing-tool installed on the host
# (pip install signing-tool), or CLIENT=<signing-tool source tree>.
stub-smoke:       ## exercise the signing-tool verbs against the stub, no credentials
	./scripts/stub-smoke.sh

# The other half of "evaluate it without an account": that a build with no credentials
# actually completes, through do_deploy. Real bitbake, because that is the only thing
# that runs a do_deploy at all.
skip-smoke: fetch-laavat dev-keys  ## build a signing target with LAAVAT_SIGN_SKIP and no credentials
	$(KAS) shell kas/laavat/common.yml -c \
	  'bitbake laavat-deploy-smoke -c cleansstate && bitbake laavat-deploy-smoke -c deploy'

# The release axis. Everything else here is scarthgap; meta-laavat also declares walnascar,
# and this is what checks that half of the declaration. Its own build dir on purpose: two
# Yocto releases cannot share one, and mixing them fails as an ImportError from bitbake
# rather than anything that names the real problem.
walnascar:        ## parse the QEMU tier on Yocto 5.2
	KAS_BUILD_DIR=$(CURDIR)/build-52 $(KAS) shell kas/walnascar.yml -c 'bitbake -p'

styhead:          ## parse the QEMU tier on Yocto 5.1
	KAS_BUILD_DIR=$(CURDIR)/build-51 $(KAS) shell kas/styhead.yml -c 'bitbake -p'

# Yocto 5.3, and the first tier not built from poky: its master branch is retired and the
# release branches stop at 5.2, so this assembles bitbake + oe-core + meta-yocto instead.
# That layout is what the April 2026 LTS will use. See docs/yocto-matrix.md.
whinlatter:       ## parse the QEMU tier on Yocto 5.3 (post-poky layout)
	KAS_BUILD_DIR=$(CURDIR)/build-53 $(KAS) shell kas/whinlatter.yml -c 'bitbake -p'

# Yocto 6.0 LTS. Codenames are Lake District passes, so 6.0 is "wrynose" - there is no
# branch named after the version anywhere.
wrynose:          ## parse the QEMU tier on Yocto 6.0 LTS
	KAS_BUILD_DIR=$(CURDIR)/build-60 $(KAS) shell kas/wrynose.yml -c 'bitbake -p'

yocto-matrix: walnascar styhead whinlatter wrynose  ## every supported Yocto release

# yocto-check-layer's signature test is the one that matters here: it proves that merely
# having meta-laavat in bblayers changes no other recipe's signature, which is the whole
# premise of every guarded inherit. Needs a poky-only build so the tool can add layers
# itself; inside a normal tier it collides with kas's own bblayers.
check-layer:      ## run Yocto's own layer QA against meta-laavat
	$(KAS) shell kas/check-layer.yml -c 'yocto-check-layer /build/../work/layers-50/meta-laavat \
	  --dependency /build/../work/layers-50/meta-openembedded/meta-oe \
	  /build/../work/layers-50/meta-openembedded/meta-python \
	  /build/../work/layers-50/meta-rauc /build/../work/layers-50/meta-security \
	  /build/../work/layers-50/meta-security/meta-integrity'

disk:             ## disk usage of the build (df is the truth on btrfs+compression)
	scripts/disk-check.sh

clean-tmp:        ## drop build/tmp (keeps downloads + sstate)
	rm -rf build/tmp
