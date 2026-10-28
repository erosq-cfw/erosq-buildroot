################################################################################
#
# erosq-firmware
#
################################################################################

# Only downloaded and unpacked: erosq-board's extract-stock-firmware.py checks
# and installs the files from $(EROSQ_FIRMWARE_DIR) (same layout as the stock rootfs).
EROSQ_FIRMWARE_VERSION = $(FIRMWARE_SHA)
EROSQ_FIRMWARE_SITE = https://github.com/erosq-cfw/erosq-firmware.git
EROSQ_FIRMWARE_SITE_METHOD = git
EROSQ_FIRMWARE_LICENSE = PROPRIETARY (stock EROS Q firmware, redistributed unmodified)
EROSQ_FIRMWARE_LICENSE_FILES = README.md
EROSQ_FIRMWARE_REDISTRIBUTE = NO
EROSQ_FIRMWARE_INSTALL_TARGET = NO

$(eval $(generic-package))
