################################################################################
#
# libldac
#
################################################################################

# Upstream ldacBT release tarball, unmodified.
LIBLDAC_VERSION = 2.0.2.6
LIBLDAC_SOURCE = ldacBT-$(LIBLDAC_VERSION).tar.gz
LIBLDAC_SITE = https://github.com/EHfive/ldacBT/releases/download/v$(LIBLDAC_VERSION)
LIBLDAC_INSTALL_STAGING = YES
LIBLDAC_LICENSE = Apache-2.0
LIBLDAC_LICENSE_FILES = LICENSE
# hard-float target: use the float build (soft-float OFF)
LIBLDAC_CONF_OPTS = -DLDAC_SOFT_FLOAT=OFF

$(eval $(cmake-package))
