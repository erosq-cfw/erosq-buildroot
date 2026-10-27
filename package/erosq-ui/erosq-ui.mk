################################################################################
#
# erosq-ui
#
################################################################################

EROSQ_UI_VERSION = erosq-local
# Build from <external>/../erosq-ui (a checkout of erosq-ui next to this tree),
# the same tree post-build.sh reads the `ui` version from (git describe), so the
# binary and /etc/sw-versions can't disagree.
EROSQ_UI_SITE = $(BR2_EXTERNAL_EROSQ_PATH)/../erosq-ui
EROSQ_UI_SITE_METHOD = local
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

# Apply the vendored-lvgl patches (build.sh does this via git-apply; replicate with patch -N
# so it's idempotent whether or not the copied lvgl tree already carries them).
# NB: this Buildroot's pkgdir strips the trailing slash (pkg-utils.mk patsubst),
# so the "/" below is load-bearing — without it the glob was
# ".../erosq-uilvgl-patches/*.patch" and the hook was a silent no-op.
define EROSQ_UI_PATCH_LVGL
	for p in $(EROSQ_UI_PKGDIR)/lvgl-patches/*.patch; do \
		patch -d $(@D)/lvgl -p1 -N -r - <$$p || true; \
	done
endef
# local-site packages have no extract step (they rsync -> .stamp_rsynced), so
# only POST_RSYNC_HOOKS fire; POST_EXTRACT_HOOKS silently never ran.
EROSQ_UI_POST_RSYNC_HOOKS += EROSQ_UI_PATCH_LVGL

# CMakeLists has no install() rule for the app: install explicitly.
define EROSQ_UI_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/buildroot-build/erosq-ui $(TARGET_DIR)/usr/bin/erosq-ui
	$(INSTALL) -D -m 0755 $(@D)/buildroot-build/podindex $(TARGET_DIR)/usr/bin/podindex
	$(INSTALL) -D -m 0644 $(@D)/manifest/extras.tsv $(TARGET_DIR)/usr/share/erosq-ui/extras.tsv
endef

$(eval $(cmake-package))
