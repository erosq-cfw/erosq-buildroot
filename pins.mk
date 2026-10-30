# Pinned inputs for CI and release builds. Valid make and shell (KEY=value).
BUILDROOT_VERSION=2026.08
BUILDROOT_SHA256=d678e810abf877d04513e03ca2c99f992dd49118b9c2e18d6e25f5f58fa8c5cd
# erosq-ui: EROSQ_UI_DESCRIBE = `git describe --tags --always` of EROSQ_UI_SHA
# (goes into /etc/sw-versions; tests/test_pins.sh checks it)
EROSQ_UI_SHA=e4f0fc7758984d36314f5a61932bedb8d7fe626c
EROSQ_UI_DESCRIBE=e4f0fc7
LVGL_VERSION=9.6.0
# erosq-firmware: stock Wi-Fi/BT chip firmware (package/erosq-firmware)
FIRMWARE_SHA=650011c4508b869699bc9afd57c248cdd5a7661e
# kernel and U-Boot sources (ci/kernel.sh, ci/uboot.sh)
LINUX_SHA=5ce79c8444d604e4a48b90b56b683b60a25336d0
UBOOT_SHA=76df256d20ba9641ba6a154cdbe11a448b97bbeb
# SD-card bundle (ci/sdbundle.sh): launchers, games and emulators, built
# against the rootfs staging sysroot
SD_BUNDLE_SHA=2c1acd101a57dc2ab3fffe713f4e568f3d9887b0
PCSX_SHA=a1bb71beb68d2771a8e28ea7dd7cb372deaa8db1
PICOARCH_SHA=78547f3df57f59e19ec4c7e8f417ef98cd7cf448
GAMBATTE_SHA=9b3b5e3cc18ec92f460d37dd551eaf90c55bfcea
GPSP_SHA=69e86ebe89f14c3f5f75b809c12c0a953b3d6ce4
OPENTYRIAN_SHA=da5f634adcd95117ecf2b8b25388bf2aa9a137a9
OPENJAZZ_SHA=9300df85bc8cca6a85f8479d632db1a97b54e1dc
DOOM_SHA=5afb6e74c58e429b87ea84981cf4649fc784b635
DOOMGENERIC_SHA=dcb7a8dbc7a16ce3dda29382ac9aae9d77d21284
TINYALSA_SHA=df11091086b56e5fb71887f2fa320e1d2ffeff58
