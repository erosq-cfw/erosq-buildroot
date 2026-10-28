#!/bin/sh
# $1 = TARGET_DIR. Final rootfs fixups after all packages install.
set -e
TARGET="${1:?usage: post-build.sh TARGET_DIR}"  # empty would rm -rf host paths

# ---------------------------------------------------------------------------
# Read-only squashfs root + writable sysdata (/data) — persistent write paths.
#
# The root FS is a RO squashfs (BR2_TARGET_ROOTFS_SQUASHFS). Anything a daemon
# writes at runtime must land on tmpfs (ephemeral) or /data (persistent UBIFS,
# mounted by S05mounts). /etc and /var/lib are RO, so each persistent path is
# baked here as a SYMLINK into /data/...; S05mounts creates the /data targets on
# first boot. Audit (every runtime writer to /):
#   /etc/dropbear        -> /data/etc/dropbear        (SSH host keys; persist or
#                                                       known-hosts breaks each boot)
#   /root/.ssh           -> /data/root/.ssh           (root's authorized_keys: the
#       image ships none; put your own public key there to enable SSH logins)
#   /var/lib/bluetooth   -> /data/lib/bluetooth       (BlueZ pairings)
#   /var/lib/bluealsa    -> /tmp/bluealsa             (bluealsa's per-device volume +
#       codec cache. TMPFS on purpose, not /data: erosq-ui already owns per-device BT
#       volume persistence (/data/erosq-ui.btvol) and bt_best_codec.sh re-selects the
#       codec after every connect, so nothing here needs to survive a reboot -- while
#       bluealsa rewrites the file on EVERY volume change, which at the UI's 2% wheel
#       step would be ~50 tiny UBIFS writes per volume sweep. Was MISSING from this
#       audit: with no writable dir bluealsa logged "Couldn't create storage
#       directory: Read-only file system" + an error on every device teardown.)
#   /var/lib/mpd         -> /data/lib/mpd             (MPD db/state/playlists)
#   /var/lib/seedrng     -> /data/lib/seedrng         (RNG seed across reboots)
#   /etc/wpa_supplicant.conf -> /data/etc/wpa_supplicant.conf  (saved WiFi nets;
#       seeded from the RO skeleton on first boot by S05mounts; erosq-ui persists
#       networks via SAVE_CONFIG, enabled by update_config=1 in the skeleton.
#       The link is for humans only: wifi_up.sh runs wpa_supplicant -c on the /data
#       path, because SAVE_CONFIG writes its temp file next to -c, i.e. in RO /etc)
#   /var/log -> ../tmp, /var/run -> ../run, /run,/tmp,/dev/shm = tmpfs (ephemeral)
#   resolv.conf: udhcpc writes /etc/resolv.conf -> symlink to tmpfs (/tmp)
# ---------------------------------------------------------------------------

# mount points
mkdir -p "$TARGET/data" "$TARGET/media/sd"

# Persistent write paths -> symlink into /data (target dirs made by S05mounts).
# Remove whatever the packages installed (dir or pre-existing symlink) first.
persist_symlink() {  # $1 = abs path under TARGET (no leading slash) ; $2 = /data target
	rm -rf "${TARGET:?}/$1"
	mkdir -p "$(dirname "$TARGET/$1")"
	ln -sf "$2" "$TARGET/$1"
}
persist_symlink etc/dropbear          /data/etc/dropbear
persist_symlink root/.ssh             /data/root/.ssh
persist_symlink var/lib/bluetooth     /data/lib/bluetooth
persist_symlink var/lib/mpd           /data/lib/mpd
persist_symlink var/lib/seedrng       /data/lib/seedrng

# Ephemeral (tmpfs) redirect -- deliberately NOT persist_symlink: see the audit note
# above for why bluealsa's storage must not land on /data. bt_audio_up.sh mkdir -p's
# the target through this symlink before starting bluealsa.
rm -rf "$TARGET/var/lib/bluealsa"
ln -sf /tmp/bluealsa "$TARGET/var/lib/bluealsa"

# wpa_supplicant.conf: redirect the file (not a dir) so saved networks persist on
# /data. The RO skeleton /etc/wpa_supplicant.conf.default ships from the
# erosq-board overlay (update_config=1, no network block); S05mounts seeds /data
# from it on first boot. DISCARD the package's own conf: Buildroot's stock sample
# carries a wildcard open network ({ key_mgmt=NONE }, no ssid) that auto-joins
# ANY open AP — it must never become the seed.
persist_symlink etc/wpa_supplicant    /data/etc/wpa_supplicant
if [ -f "$TARGET/etc/wpa_supplicant.conf" ] && [ ! -L "$TARGET/etc/wpa_supplicant.conf" ]; then
	rm -f "$TARGET/etc/wpa_supplicant.conf"
fi
ln -sf /data/etc/wpa_supplicant.conf "$TARGET/etc/wpa_supplicant.conf"

# resolv.conf is rewritten by udhcpc at runtime -> point at tmpfs.
rm -f "$TARGET/etc/resolv.conf"
ln -sf /tmp/resolv.conf "$TARGET/etc/resolv.conf"

# machine-id: dbus needs one, / is RO (bt_audio_up.sh's write failed silently
# every boot and dbus's /var/lib/dbus/machine-id symlink dangled). Persist it
# on /data; S05mounts seeds it on first boot.
rm -f "$TARGET/etc/machine-id"
ln -sf /data/etc/machine-id "$TARGET/etc/machine-id"

# Ship ONLY the newest module tree. Buildroot doesn't clean target/ between
# builds, so a kernel bump leaves stale version dirs behind. Derive the version
# to keep instead of hardcoding it (a hardcoded "6.12.93" here silently deleted
# the wrong tree after the 6.18 port -- never hardcode a kernel version).
KEEP=$(ls -1 "$TARGET"/lib/modules 2>/dev/null | sort -V | tail -1)
for d in "$TARGET"/lib/modules/*/; do
	[ -d "$d" ] || continue
	[ "$(basename "$d")" = "$KEEP" ] || rm -rf "$d"
done

# mpd.conf: BOTH package/mpd and erosq-board install /etc/mpd.conf, so whichever
# installs to target LAST wins — a plain `make` orders erosq-board after mpd, but
# an incremental `make mpd-dirclean && make` reinstalls mpd last and silently
# reverts to Buildroot's default conf (unscoped /var/lib/mpd/music). Enforce ours
# here, after all packages.
install -m 0644 "$BR2_EXTERNAL_EROSQ_PATH/package/erosq-board/files/etc/mpd.conf" \
	"$TARGET/etc/mpd.conf"

# Disable stock daemons that the lean original rcS never ran. On the 23.6 MB device
# every MB of headroom matters (memory thrash under playback causes choppy audio):
#  - dbus/bluetoothd: deferred — bt_audio_up.sh brings them up on demand.
#  - syslogd/klogd/crond: unneeded on a music appliance (use dmesg; no cron jobs).
# (rcS only runs /etc/init.d/S??* — a non-S prefix disables without deleting.)
for s in S30dbus-daemon S40bluetoothd S01syslogd S02klogd S50crond; do
	if [ -e "$TARGET/etc/init.d/$s" ]; then
		mv -f "$TARGET/etc/init.d/$s" "$TARGET/etc/init.d/disabled.$s"
	fi
done

# Prune audio dead weight (2026-07-08 audit): decoder-package CLI tools and
# libs nothing on the image links (verified by a full reverse-NEEDED scan of
# every ELF + a script grep — mpd is the only audio consumer). libvorbisenc is
# only safe to drop while mpd doesn't link it; guard each lib with a live
# NEEDED check so a future mpd/bluealsa config change re-ships it instead of
# breaking playback at boot.
rm -f "$TARGET"/usr/bin/flac "$TARGET"/usr/bin/metaflac "$TARGET"/usr/bin/faad \
	"$TARGET"/usr/bin/mpg123 "$TARGET"/usr/bin/mpg123-id3dump \
	"$TARGET"/usr/bin/mpg123-strip "$TARGET"/usr/bin/out123
rm -rf "$TARGET"/usr/lib/mpg123        # out123/mpg123 CLI output plugins
for lib in libmad libFLAC++ libfaad_drm libvorbisfile libvorbisenc; do
	if find "$TARGET" -type f \( -perm -u+x -o -name '*.so*' \) \
			-exec readelf -d {} \; 2>/dev/null | grep -q "NEEDED.*$lib\.so"; then
		echo "post-build: $lib still NEEDED by something — keeping it" >&2
	else
		rm -f "$TARGET"/usr/lib/$lib.so*
	fi
done

# gdb pretty-printer loader: no gdb on target, and it embeds the build path
rm -f "$TARGET"/usr/lib/libstdc++.so.*-gdb.py

# /etc/sw-versions: the update system's version source. REAL content-tied versions
# (not an arbitrary stamp): kernel = release + source commit captured by
# build-kernel.sh (build-output/kernel.version); rootfs = erosq-br git describe.
#
# `firmware` is the SINGLE version swupdate gates on (bundle-level, not per-image):
# a composite of both components, so it changes whenever EITHER changes -- the UI
# hands it to `swupdate -R <firmware>` (--no-reinstalling) so an identical .swu is a
# clean no-op while ANY different version (up or down) installs BOTH components,
# keeping the inactive A/B slot coherent. The `kernel`/`rootfs` lines are
# informational (About screen / debugging). board/erosq/swu/mk-erosq-swu.sh reads
# these lines back out of the squashfs, so the bundle always matches. See spec §2.1.
# $EROSQ_KERNEL_VERSION (ci/rootfs.sh) wins over the file.
KVER=${EROSQ_KERNEL_VERSION:-$(cat "$BR2_EXTERNAL_EROSQ_PATH/../build-output/kernel.version" 2>/dev/null || echo "unknown")}
RVER=$(git -C "$BR2_EXTERNAL_EROSQ_PATH" describe --tags --always --dirty 2>/dev/null || echo "unknown")
# erosq-ui is a SEPARATE repo whose binary lives in the rootfs, so a UI-only change
# does NOT move RVER (erosq-br describe). Fold its version into the composite
# firmware gate so such a change still bumps `firmware` and installs. (rootfs recipe
# = RVER, UI = UIVER; both are informational, `firmware` is the single gate.)
# The erosq-ui package records the version it built (pins.mk, or git describe of
# an OVERRIDE_SRCDIR checkout), so the binary and this line can't disagree.
# ponytail: newest wins if the output dir holds both a pinned and an override build.
UIVER=$(cat "$(ls -t "$BUILD_DIR"/erosq-ui-*/.erosq-ui-version 2>/dev/null | head -n1)" 2>/dev/null || echo "unknown")
FWVER="${RVER}+${KVER}+ui${UIVER}"
printf 'firmware %s\nkernel %s\nrootfs %s\nui %s\n' "$FWVER" "$KVER" "$RVER" "$UIVER" > "$TARGET/etc/sw-versions"
echo "post-build: /etc/sw-versions -> firmware $FWVER (kernel $KVER / rootfs $RVER / ui $UIVER)"
