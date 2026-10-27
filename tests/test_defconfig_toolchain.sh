#!/bin/sh
# Host self-check: erosq_defconfig must describe the SDK that
# erosq_sdk_defconfig builds. Both must keep BR2_MIPS_SOFT_FLOAT unset
# (Buildroot's MIPS default is soft-float: packages would link against
# ld-musl-mipsel-sf.so.1 and not run), and the gcc and kernel-headers
# versions must match.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
MAIN="${MAIN:-$HERE/configs/erosq_defconfig}"        # MAIN=/SDK= override: mutant checks
SDK="${SDK:-$HERE/configs/erosq_sdk_defconfig}"
fail() { echo "FAIL: $*"; exit 1; }

for f in "$MAIN" "$SDK"; do
	grep -qx '# BR2_MIPS_SOFT_FLOAT is not set' "$f" || fail "$f: BR2_MIPS_SOFT_FLOAT not unset"
done
gcc=$(sed -n 's/^BR2_GCC_VERSION_\([0-9]*\)_X=y$/\1/p' "$SDK")
hdr=$(sed -n 's/^BR2_KERNEL_HEADERS_\([0-9_]*\)=y$/\1/p' "$SDK")
if [ -z "$gcc" ] || [ -z "$hdr" ]; then fail "$SDK: no gcc or kernel-headers version"; fi
grep -qx "BR2_TOOLCHAIN_EXTERNAL_GCC_$gcc=y" "$MAIN" || fail "$MAIN: gcc != SDK gcc $gcc"
grep -qx "BR2_TOOLCHAIN_EXTERNAL_HEADERS_$hdr=y" "$MAIN" || fail "$MAIN: headers != SDK headers $hdr"
grep -qx 'BR2_TOOLCHAIN_EXTERNAL_CUSTOM_MUSL=y' "$MAIN" || fail "$MAIN: SDK libc is musl"
echo "PASS: defconfig toolchain matches the SDK, hard-float"
