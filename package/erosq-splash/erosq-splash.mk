################################################################################
#
# erosq-splash  (fallback DRM boot splash; source in src/)
#
################################################################################

EROSQ_SPLASH_VERSION = erosq-local
EROSQ_SPLASH_SITE = $(BR2_EXTERNAL_EROSQ_PATH)/package/erosq-splash/src
EROSQ_SPLASH_SITE_METHOD = local
EROSQ_SPLASH_LICENSE = MIT
# DRM uapi headers (drm/drm.h, drm/drm_mode.h) come from the toolchain's
# kernel headers; no libdrm.

# static like erosq-uilaunch and mpdctl: it is exec'd in the launcher's pid as
# the last resort when erosq-ui fails, so it must not depend on anything else.
define EROSQ_SPLASH_BUILD_CMDS
	$(TARGET_CC) $(TARGET_CFLAGS) -Os -static -Wall -Wextra \
		-Wl,-z,max-page-size=4096 -o $(@D)/erosq-splash $(@D)/erosq-splash.c
endef

define EROSQ_SPLASH_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/erosq-splash $(TARGET_DIR)/sbin/erosq-splash
endef

$(eval $(generic-package))
