################################################################################
#
# erosq-ui
#
################################################################################

# Pinned in pins.mk. Developers build a local checkout instead with
#   EROSQ_UI_OVERRIDE_SRCDIR = /path/to/erosq-ui
# in the output directory's local.mk; LVGL then still comes from the pin below.
EROSQ_UI_VERSION = $(EROSQ_UI_SHA)
EROSQ_UI_SITE = https://github.com/erosq-cfw/erosq-ui.git
EROSQ_UI_SITE_METHOD = git
EROSQ_UI_LVGL_SOURCE = v$(LVGL_VERSION).tar.gz
EROSQ_UI_EXTRA_DOWNLOADS = https://github.com/lvgl/lvgl/archive/refs/tags/$(EROSQ_UI_LVGL_SOURCE)
EROSQ_UI_LICENSE = MIT
EROSQ_UI_LICENSE_FILES = LICENSE
# expat: podindex's XML parser. Already built as a dbus dependency, so this
# declares what we actually use rather than inheriting it by accident.
EROSQ_UI_DEPENDENCIES = libdrm libtinyalsa libglib2 dbus expat

# Out-of-source build (matches build.sh's `-B build`); binary lands in buildroot-build/.
EROSQ_UI_SUPPORTS_IN_SOURCE_BUILD = NO

# Device (DRM) build. Point the manual path-vars at Buildroot staging:
#   libdrm  = shared 2.4.131 (xf86drm.h in usr/include, drm headers in usr/include/libdrm)
#   tinyalsa = static 1.1.1 (.a in usr/lib, headers under usr/include/tinyalsa)
# BUILD_SHARED_LIBS=OFF: Buildroot's cmake infra defaults it ON, which would build LVGL as
# liblvgl.so.9 (not installed -> runtime "cannot load liblvgl.so.9"). The hand build links LVGL
# statically; match that so erosq-ui is self-contained (only libdrm.so + libc dynamic).
EROSQ_UI_CONF_OPTS = \
	-DBUILD_SHARED_LIBS=OFF \
	-DEROSQ_HOST=OFF \
	-DLIBDRM_INC="$(STAGING_DIR)/usr/include;$(STAGING_DIR)/usr/include/libdrm" \
	-DLIBDRM_LIB=$(STAGING_DIR)/usr/lib/libdrm.so \
	-DLIBTINYALSA_INC=$(STAGING_DIR)/usr/include \
	-DLIBTINYALSA_LIB=$(STAGING_DIR)/usr/lib/libtinyalsa.a

# LVGL is not vendored in erosq-ui: unpack the pinned release into lvgl/ and
# apply our patches (a patch that no longer applies fails the build). Runs after
# the git extract and, for an OVERRIDE_SRCDIR build, after the rsync. Also record
# the erosq-ui version for post-build.sh's /etc/sw-versions.
define EROSQ_UI_ADD_LVGL
	rm -rf $(@D)/lvgl
	mkdir -p $(@D)/lvgl
	$(call suitable-extractor,$(EROSQ_UI_LVGL_SOURCE)) $(EROSQ_UI_DL_DIR)/$(EROSQ_UI_LVGL_SOURCE) | \
		$(TAR) --strip-components=1 -C $(@D)/lvgl $(TAR_OPTIONS) -
	$(APPLY_PATCHES) $(@D)/lvgl $(EROSQ_UI_PKGDIR)/lvgl-patches \*.patch
	$(if $(EROSQ_UI_OVERRIDE_SRCDIR),\
		git -C $(EROSQ_UI_OVERRIDE_SRCDIR) describe --tags --always --dirty,\
		echo $(EROSQ_UI_DESCRIBE)) > $(@D)/.erosq-ui-version
endef
EROSQ_UI_POST_EXTRACT_HOOKS += EROSQ_UI_ADD_LVGL
EROSQ_UI_POST_RSYNC_HOOKS += EROSQ_UI_ADD_LVGL

# CMakeLists has no install() rule for the app: install explicitly.
define EROSQ_UI_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/buildroot-build/erosq-ui $(TARGET_DIR)/usr/bin/erosq-ui
	$(INSTALL) -D -m 0755 $(@D)/buildroot-build/podindex $(TARGET_DIR)/usr/bin/podindex
	$(INSTALL) -D -m 0644 $(@D)/manifest/extras.tsv $(TARGET_DIR)/usr/share/erosq-ui/extras.tsv
endef

$(eval $(cmake-package))
