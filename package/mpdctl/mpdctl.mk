################################################################################
#
# mpdctl  (tiny MPD unix-socket client; source in src/)
#
################################################################################

MPDCTL_VERSION = erosq-local
MPDCTL_SITE = $(BR2_EXTERNAL_EROSQ_PATH)/package/mpdctl/src
MPDCTL_SITE_METHOD = local
MPDCTL_LICENSE = MIT

# static like erosq-uilaunch: no loader or libc mapping for a short-lived helper.
define MPDCTL_BUILD_CMDS
	$(TARGET_CC) $(TARGET_CFLAGS) -Os -static -Wall -Wextra \
		-Wl,-z,max-page-size=4096 -o $(@D)/mpdctl $(@D)/mpdctl.c
endef

define MPDCTL_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/mpdctl $(TARGET_DIR)/usr/bin/mpdctl
endef

$(eval $(generic-package))
