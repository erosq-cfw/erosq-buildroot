#!/bin/sh
# Host self-check for S99abcommit's ab_nocommit hold. Runs the SHIPPED script
# against a fake U-Boot env (stubbed fw_printenv/fw_setenv), a fake
# /proc/cmdline and /dev/kmsg.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
SRC="${SRC:-$HERE/package/erosq-board/files/etc/init.d/S99abcommit}"   # SRC= override: mutant checks
fail() { echo "FAIL: $*"; exit 1; }

run() {   # $1 = upgrade_available, $2 = ab_nocommit ("" = unset), $3 = running slot
	T=$(mktemp -d); export T
	mkdir -p "$T/bin" "$T/env"
	echo b > "$T/env/boot_slot"; echo "$3" > "$T/env/boot_try"; echo 1 > "$T/env/bootcount"
	echo "$1" > "$T/env/upgrade_available"; [ -n "$2" ] && echo "$2" > "$T/env/ab_nocommit"
	: > "$T/kmsg"
	[ "$3" = b ] && echo "console=ttyS2 ubi.block=0,rootfs_b" > "$T/cmdline" || echo "console=ttyS2 ubi.block=0,rootfs" > "$T/cmdline"
	cat > "$T/bin/fw_printenv" <<'EOF'
#!/bin/sh
[ "$1" = -n ] && shift; cat "$T/env/$1" 2>/dev/null || exit 1
EOF
	cat > "$T/bin/fw_setenv" <<'EOF'
#!/bin/sh
k=$1; shift; if [ $# -eq 0 ]; then rm -f "$T/env/$k"; else echo "$*" > "$T/env/$k"; fi
EOF
	printf '#!/bin/sh\nexit 0\n' > "$T/bin/logger"; chmod +x "$T/bin/"*
	sed -e "s|/proc/cmdline|$T/cmdline|g; s|/dev/kmsg|$T/kmsg|g" "$SRC" > "$T/s99"
	PATH="$T/bin:$PATH" sh "$T/s99" start
}
env() { cat "$T/env/$1" 2>/dev/null || echo "<unset>"; }

run 1 "" a     # normal try-boot of slot a: commit
[ "$(env boot_slot)" = a ] && [ "$(env upgrade_available)" = 0 ] && [ "$(env boot_try)" = "<unset>" ] && [ "$(env bootcount)" = 0 ] || fail "unheld try-boot not committed"; rm -rf "$T"
run 1 1 a      # held trial: nothing committed, revert stays armed
[ "$(env boot_slot)" = b ] || fail "held: boot_slot changed to $(env boot_slot)"
[ "$(env upgrade_available)" = 1 ] && [ "$(env boot_try)" = a ] && [ "$(env bootcount)" = 1 ] || fail "held: revert disarmed"
grep -q "commit held" "$T/kmsg" || fail "held: not logged"; rm -rf "$T"
run 1 0 a      # ab_nocommit=0 behaves as unset
[ "$(env boot_slot)" = a ] || fail "ab_nocommit=0 blocked the commit"; rm -rf "$T"
run 0 "" b     # no try-boot pending: untouched
[ "$(env boot_slot)" = b ] && [ "$(env bootcount)" = 1 ] || fail "idle boot touched env"; rm -rf "$T"
echo "test_abcommit_hold: all checks passed"
