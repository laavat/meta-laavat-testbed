# Signs a 64KiB FIT against scripts/laavat-stub.py or a real service; proves the
# do_laavat_sign chain (bbclass -> signing-tool -> HTTP -> digest -> install).
# The address and IDs come from kas/laavat/common.yml (stub) or kas/laavat-live.yml (service).
SUMMARY = "Hermetic do_laavat_sign smoke"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# meta-laavat is only in the layer set for kas/laavat*.yml; parse (task-less) without it.
inherit ${@'laavat-sign' if bb.utils.which(d.getVar('BBPATH'), 'classes/laavat-sign.bbclass') else ''}

EXCLUDE_FROM_WORLD = "1"
INHIBIT_DEFAULT_DEPS = "1"
DEPENDS = "u-boot-tools-native dtc-native"

# SignUBoot/SignKernel are mkimage -F re-signs, so the payload must be a FIT carrying an
# unsigned signature node — a bare blob is rejected by the service with "No signatures added".
do_compile() {
    head -c 65536 /dev/urandom > ${B}/payload.bin
    cat > ${B}/payload.its <<'EOF'
/dts-v1/;
/ {
	description = "laavat-sign smoke payload";
	#address-cells = <1>;
	images {
		payload {
			description = "noise";
			data = /incbin/("payload.bin");
			type = "firmware";
			arch = "arm64";
			os = "u-boot";
			compression = "none";
			load = <0x40000000>;
			hash-1 { algo = "sha256"; };
			signature-1 { algo = "sha256,rsa2048"; key-name-hint = "dev"; };
		};
	};
	configurations {
		default = "conf";
		conf {
			description = "smoke";
			firmware = "payload";
		};
	};
};
EOF
    cd ${B} && mkimage -f payload.its payload.fit
}

LAAVAT_SIGN_OPERATION = "SignUBoot"
LAAVAT_SIGN_INPUT = "${B}/payload.fit"
LAAVAT_SIGN_OUTPUT = "${B}/payload.fit.signed"

addtask laavat_sign after do_compile
