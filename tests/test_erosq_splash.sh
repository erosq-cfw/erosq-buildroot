#!/bin/sh
# Host check for package/erosq-splash (erosq_splash_check.py does the asserts).
#   (no args)                         build src/erosq-splash.c with the host cc;
#                                     run the full modeset path against the
#                                     LD_PRELOAD fake DRM device, then the
#                                     error/default-path checks
#   test_erosq_splash.sh RUNNER... BIN  error/default-path checks of a given
#                                     binary, e.g. a target build:
#     test_erosq_splash.sh qemu-mipsel-static output/target/sbin/erosq-splash
# Needs python3 and unprivileged user namespaces (unshare -rm).
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
CHECK="$HERE/tests/erosq_splash_check.py"
if [ $# -eq 0 ]; then
	W=$(mktemp -d /tmp/erosq-splash-test.XXXXXX)
	trap 'rm -rf "$W"' EXIT
	${CC:-cc} -O2 -Wall -Wextra -o "$W/erosq-splash" \
		"$HERE/package/erosq-splash/src/erosq-splash.c"
	${CC:-cc} -O2 -Wall -Wextra -shared -fPIC -o "$W/fakedrm.so" \
		"$HERE/tests/erosq_splash_fakedrm.c" -ldl
	python3 -I "$CHECK" fakedrm "$W/fakedrm.so" "$W/erosq-splash"
	set -- "$W/erosq-splash"
fi
python3 -I "$CHECK" errors "$@"
