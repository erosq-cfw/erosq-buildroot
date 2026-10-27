#!/bin/sh
# Host check for package/mpdctl: runs mpdctl against a fake MPD socket server
# (mpdctl_check.py) and asserts on the exact bytes sent, stdout and exit code.
#   (no args)                       build src/mpdctl.c with the host cc and test it
#   test_mpdctl.sh RUNNER... BIN    test a given binary, e.g. a target build:
#     test_mpdctl.sh qemu-mipsel-static output/target/usr/bin/mpdctl
# Needs python3 and unprivileged user namespaces (unshare -rm) for the
# default /run/mpd.sock case.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
if [ $# -eq 0 ]; then
	W=$(mktemp -d /tmp/mpdctl-test.XXXXXX)
	trap 'rm -rf "$W"' EXIT
	${CC:-cc} -O2 -Wall -Wextra -o "$W/mpdctl" "$HERE/package/mpdctl/src/mpdctl.c"
	set -- "$W/mpdctl"
fi
python3 -I "$HERE/tests/mpdctl_check.py" "$@"
