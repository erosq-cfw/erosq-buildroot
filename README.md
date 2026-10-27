# erosq-buildroot

Buildroot external tree (`BR2_EXTERNAL`) for custom firmware on the EROS Q
music player (Ingenic X1000, 32 MB RAM, SPI-NAND). It builds the root
filesystem: musl userspace, MPD with ALSA output, BlueZ + BlueALSA for
Bluetooth audio, wpa_supplicant, swupdate for A/B updates, and the
[erosq-ui](https://github.com/erosq-cfw/erosq-ui) LVGL front end.

The kernel and U-Boot are built separately (`ci/kernel.sh`, `ci/uboot.sh`).
The kernel build produces the FIT image (`erosq.itb`, kernel + DTB) that goes
into a `.swu` update bundle with the root filesystem built here.

## Layout

| path | contents |
|---|---|
| `configs/erosq_defconfig` | the board configuration |
| `board/erosq/` | post-build/post-image scripts, swupdate and busybox config |
| `package/erosq-board/` | init scripts, Wi-Fi/BT/SD/USB helpers, splash image, stock-firmware extractor |
| `package/erosq-ui/`, `mpdctl/`, `erosq-splash/`, `libtinyalsa/`, `libldac/` | packages built from source |
| `global-patches/` | patches to BlueZ, MPD and wpa_supplicant |
| `patches/buildroot/` | patches to Buildroot itself (applied by `apply-patches.sh`) |
| `docs/fw-update-artifacts/` | `.swu` bundling script and `sw-description` template |
| `tests/` | host tests for the scripts and patches |

## Building

Requirements: a Linux host with the usual Buildroot dependencies, Python 3,
and `ubi_reader` (`pip install ubi_reader`) only if you build from a stock `.upt`.

```sh
mkdir erosq && cd erosq
git clone https://github.com/erosq-cfw/erosq-buildroot
wget https://buildroot.org/downloads/buildroot-2026.08.tar.gz
tar xf buildroot-2026.08.tar.gz
./erosq-buildroot/apply-patches.sh buildroot-2026.08

# the toolchain: download sdk-$(./erosq-buildroot/ci/sdk.sh id).tar.gz from the
# release of that name, or build it (about 20 min on 24 cores):
#   ./erosq-buildroot/ci/sdk.sh build sdk-build
./erosq-buildroot/ci/sdk.sh install sdk-<id>.tar.gz

make -C buildroot-2026.08 O=$PWD/output BR2_EXTERNAL=$PWD/erosq-buildroot erosq_defconfig
make -C buildroot-2026.08 O=$PWD/output
```

The root filesystem lands in `output/images/rootfs.squashfs`. erosq-ui and
LVGL are downloaded at the versions pinned in `pins.mk`. To build your own
erosq-ui checkout instead, put
`EROSQ_UI_OVERRIDE_SRCDIR = /path/to/erosq-ui` in `output/local.mk`.

`post-build.sh` writes `/etc/sw-versions` from `git describe` of this tree,
the erosq-ui version that was built, and the kernel version in
`../build-output/kernel.version` (written by the kernel build; `unknown` if
absent).

## Kernel and U-Boot

Both build from the commits pinned in `pins.mk` (`LINUX_SHA`, `UBOOT_SHA`)
with the SDK installed above; the host needs `mkimage` and `dtc`
(Debian/Ubuntu: `u-boot-tools device-tree-compiler`).

```sh
./erosq-buildroot/ci/kernel.sh kbuild   # kbuild/out/erosq-<version>.itb, kernel.version
./erosq-buildroot/ci/uboot.sh ubuild    # ubuild/out/u-boot.bin, u-boot-flash.bin, u-boot-spl.bin
```

Copy `kbuild/out/kernel.version` to `build-output/kernel.version` before the
root filesystem build so `/etc/sw-versions` names the kernel. A `.swu` update
never touches U-Boot; `u-boot-flash.bin` (padded to the 1 MiB the SPL loads)
is for recovery installs.

## Wi-Fi and Bluetooth chip firmware

The CYW43438 Wi-Fi firmware, its NVRAM and the Bluetooth patchram are the
stock EROS Q files, unmodified. By default the build downloads them from
[erosq-firmware](https://github.com/erosq-cfw/erosq-firmware) at
`FIRMWARE_SHA` (`pins.mk`). To take them from your own stock firmware instead:

1. Get the stock update file for your device (for example
   `update_erosQ_v2.2-rbuninstall.upt`).
2. Either put it in `erosq-buildroot/stock/` (gitignored; the first `*.upt`
   there is used), or set `BR2_PACKAGE_EROSQ_BOARD_STOCK_FW` in menuconfig to
   the `.upt`, its `SYSTEM.UBI`, or an already extracted stock rootfs
   directory.

A local stock file wins over the download. With neither (stock file absent and
`BR2_PACKAGE_EROSQ_FIRMWARE` off) the build warns and the image has no chip
firmware, so Wi-Fi and Bluetooth don't work.

Either way, `package/erosq-board/extract-stock-firmware.py` checks every file
against pinned sha256 sums and stops the build when they don't match. You can
also run it by hand:

```sh
python3 erosq-buildroot/package/erosq-board/extract-stock-firmware.py SOURCE OUTDIR
```

The firmware files are proprietary and carry no licence; see the
erosq-firmware README for how they are redistributed.

## Signing updates (self-signed builds)

Devices install a `.swu` only if its `sw-description` is signed (RSA-PSS) by
the key whose public half is in `/etc/swupdate/public.pem`. By default the
image ships the project's official public key, so it accepts official
releases only. To build and install your own updates, use your own key pair:

```sh
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out swu-priv.pem
openssl pkey -in swu-priv.pem -pubout -out swu-pub.pem
```

1. Set `BR2_PACKAGE_EROSQ_BOARD_SWU_PUBKEY` to the absolute path of
   `swu-pub.pem` and rebuild. The image then trusts your key instead of the
   official one.
2. Bundle and sign:

   ```sh
   erosq-buildroot/board/erosq/swu/mk-erosq-swu.sh --key swu-priv.pem \
       erosq.itb output/images/rootfs.squashfs erosq.swu
   ```

A device running an official image rejects your bundles, and the reverse is
also true. Moving a device from official to self-signed firmware (or back)
needs one install from SD. Keep the private key out of every repository.

## SSH access

The image contains no SSH keys. Dropbear reads root's keys from
`/root/.ssh`, which is a link to `/data/root/.ssh` on the persistent data
volume. Put your public key in `/data/root/.ssh/authorized_keys` (mode 0600)
to enable logins. SSH host keys are generated on first boot and kept in
`/data/etc/dropbear`.

For your own builds, `BR2_PACKAGE_EROSQ_BOARD_SEED_AUTHORIZED_KEYS` can point
at an authorized_keys file kept outside the repository (or under the
gitignored `private/`). The image then carries it as a seed, and on first
boot `erosq-ssh-seed` copies it once to `/data/root/.ssh/authorized_keys` if
that file does not exist yet. Leave it empty for images you publish.

## Tests

```sh
for t in tests/test_*.sh; do sh "$t" || echo "FAILED: $t"; done
```

Some tests need host tools (wpa_supplicant, python3, unprivileged user
namespaces) and print `SKIP` without them. The MPD patch tests build the
patched MPD on the host and need `BR=` (a Buildroot tree that has been built
once: they use its `output/host` meson/ninja and `dl/mpd/`) and `FLAC=` (any
`.flac` file); both default to `../buildroot-2026.08` and `../test.flac`.

## Licence

MIT for our files; see [LICENSE](LICENSE). Buildroot, the patches to it, and
the patches to third-party packages keep their own licences; see
[NOTICE](NOTICE).
