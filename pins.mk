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
