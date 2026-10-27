################################################################################
#
# erosq-board  (prebuilt firmware + device scripts + splash)
#
################################################################################

EROSQ_BOARD_VERSION = erosq-local
EROSQ_BOARD_SITE = $(BR2_EXTERNAL_EROSQ_PATH)/package/erosq-board/files
EROSQ_BOARD_SITE_METHOD = local
EROSQ_BOARD_LICENSE = MIT (scripts), PROPRIETARY (WiFi/BT firmware from the stock image)

# Install AFTER these so the EROS /etc/mpd.conf and /etc/bluetooth/main.conf
# overrides win over the packages' generic defaults. busybox is here because
# its install unconditionally overwrites /etc/inittab: installing after it is
# what keeps the custom inittab (mdev -d for SD hot-plug) in the image.
EROSQ_BOARD_DEPENDENCIES = mpd bluez5_utils bluez-alsa busybox

define EROSQ_BOARD_INSTALL_TARGET_CMDS
	# device bring-up scripts (mpdctl comes from package/mpdctl)
	$(INSTALL) -D -m 0755 -t $(TARGET_DIR)/usr/bin $(@D)/usr/bin/*
	# SD-card lifecycle helpers (sd-mount / sd-hotplug / sd-eject)
	$(INSTALL) -D -m 0755 -t $(TARGET_DIR)/usr/sbin $(@D)/usr/sbin/*
	$(INSTALL) -D -m 0755 -t $(TARGET_DIR)/usr/share/udhcpc/default.script.d \
		$(@D)/usr/share/udhcpc/default.script.d/*
	# /etc tree: mpd.conf, bluetooth/main.conf, init.d S-scripts, splash.raw
	cp -a $(@D)/etc/. $(TARGET_DIR)/etc/
	# private builds only: SSH keys erosq-ssh-seed installs once on /data
	$(if $(EROSQ_BOARD_SEED_AUTHORIZED_KEYS),$(INSTALL) -D -m 0600 $(EROSQ_BOARD_SEED_AUTHORIZED_KEYS) \
		$(TARGET_DIR)/usr/share/erosq/seed-authorized_keys)
	# self-signed builds: trust the builder's key instead of the official one
	$(if $(EROSQ_BOARD_SWU_PUBKEY),$(INSTALL) -D -m 0644 $(EROSQ_BOARD_SWU_PUBKEY) \
		$(TARGET_DIR)/etc/swupdate/public.pem)
	chmod 0755 $(TARGET_DIR)/etc/init.d/S05mounts \
		$(TARGET_DIR)/etc/init.d/S10data $(TARGET_DIR)/etc/init.d/S15zram \
		$(TARGET_DIR)/etc/init.d/S25usbnet $(TARGET_DIR)/etc/init.d/S35wifi \
		$(TARGET_DIR)/etc/init.d/S90erosq-ui $(TARGET_DIR)/etc/init.d/S96sdscan
	# WiFi/BT chip firmware, extracted from the stock image in BUILD_CMDS
	mkdir -p $(TARGET_DIR)/lib/firmware
	cp -a $(@D)/stock-fw/. $(TARGET_DIR)/lib/firmware/
	# the UI launcher that falls back to /sbin/erosq-splash (package/erosq-splash)
	$(INSTALL) -D -m 0755 $(@D)/erosq-uilaunch $(TARGET_DIR)/usr/sbin/erosq-uilaunch
endef

EROSQ_BOARD_SWU_PUBKEY = $(call qstrip,$(BR2_PACKAGE_EROSQ_BOARD_SWU_PUBKEY))
EROSQ_BOARD_SEED_AUTHORIZED_KEYS = $(call qstrip,$(BR2_PACKAGE_EROSQ_BOARD_SEED_AUTHORIZED_KEYS))

# Where the chip firmware comes from, first match wins: a stock image set in
# Config.in or dropped in stock/ (private builds), else the pinned erosq-firmware
# package, else nothing (warning; Wi-Fi/BT won't work). Either source goes through
# extract-stock-firmware.py, which checks every file against pinned sha256 sums.
EROSQ_BOARD_STOCK_FW_LOCAL = $(or $(call qstrip,$(BR2_PACKAGE_EROSQ_BOARD_STOCK_FW)),\
	$(firstword $(wildcard $(BR2_EXTERNAL_EROSQ_PATH)/stock/*.upt)))
EROSQ_BOARD_STOCK_FW = $(or $(EROSQ_BOARD_STOCK_FW_LOCAL),\
	$(if $(BR2_PACKAGE_EROSQ_FIRMWARE),$(EROSQ_FIRMWARE_DIR)))
EROSQ_BOARD_DEPENDENCIES += $(if $(BR2_PACKAGE_EROSQ_FIRMWARE),erosq-firmware)

# UI launcher (S90erosq-ui): static, no stdio/malloc, so its resident cost is a few pages.
define EROSQ_BOARD_BUILD_CMDS
	rm -rf $(@D)/stock-fw
	$(if $(EROSQ_BOARD_STOCK_FW),\
		python3 -I $(EROSQ_BOARD_PKGDIR)/extract-stock-firmware.py \
			"$(EROSQ_BOARD_STOCK_FW)" $(@D)/stock-fw,\
		@echo "WARNING: erosq-board: no stock firmware and erosq-firmware disabled:" \
			"the image ships NO Wi-Fi/BT chip firmware"; mkdir -p $(@D)/stock-fw)
	$(TARGET_CC) $(TARGET_CFLAGS) -Os -static -Wall -Wextra \
		-Wl,-z,max-page-size=4096 -o $(@D)/erosq-uilaunch $(@D)/src/erosq-uilaunch.c
endef

$(eval $(generic-package))
