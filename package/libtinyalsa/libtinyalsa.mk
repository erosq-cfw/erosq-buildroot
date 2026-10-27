################################################################################
#
# libtinyalsa  (pinned 1.1.1 — see Config.in)
#
################################################################################

LIBTINYALSA_VERSION = 1.1.1
LIBTINYALSA_SITE = $(call github,tinyalsa,tinyalsa,$(LIBTINYALSA_VERSION))
LIBTINYALSA_INSTALL_STAGING = YES
LIBTINYALSA_LICENSE = BSD-3-Clause
LIBTINYALSA_LICENSE_FILES = NOTICE

define LIBTINYALSA_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D)/src clean
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D)/src CROSS_COMPILE=$(TARGET_CROSS) libtinyalsa.a
endef

define LIBTINYALSA_INSTALL_STAGING_CMDS
	$(INSTALL) -D -m 0644 $(@D)/src/libtinyalsa.a $(STAGING_DIR)/usr/lib/libtinyalsa.a
	mkdir -p $(STAGING_DIR)/usr/include/tinyalsa
	cp -a $(@D)/include/tinyalsa/. $(STAGING_DIR)/usr/include/tinyalsa/
endef

# static-only: nothing resident on target
define LIBTINYALSA_INSTALL_TARGET_CMDS
	:
endef

$(eval $(generic-package))
