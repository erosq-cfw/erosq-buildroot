// SPDX-License-Identifier: MIT
// Copyright (c) 2026 erosqcfw
/*
 * LD_PRELOAD fake of /dev/dri/card0 for a HOST build of erosq-splash
 * (tests/test_erosq_splash.sh). It answers the DRM ioctls the splash makes
 * with one connector/CRTC, one 320x240 mode and a dumb buffer whose pitch
 * (704) is wider than a row, logs each ioctl to $FAKEDRM_LOG, and on pause()
 * (the splash holding the modeset) writes the mapped buffer to $FAKEDRM_FB and
 * exits 42.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <drm/drm.h>
#include <drm/drm_mode.h>

#define CONN 31
#define CRTC 41
#define FB 55
#define HANDLE 7
#define PITCH 704
#define H 240

static int fake_fd = -1;
static uint8_t *fb;
static FILE *logf_;

static void lg(const char *fmt, ...)
{
	va_list ap;
	if (!logf_ && !(logf_ = fopen(getenv("FAKEDRM_LOG"), "w")))
		abort();
	va_start(ap, fmt);
	vfprintf(logf_, fmt, ap);
	va_end(ap);
	fputc('\n', logf_);
	fflush(logf_);
}

static int fake_open(const char *path, int flags, mode_t mode,
		     int (*real)(const char *, int, ...))
{
	if (strcmp(path, "/dev/dri/card0") == 0) {
		fake_fd = real("/dev/null", O_RDWR);
		lg("open card0 flags=%s", (flags & O_RDWR) && (flags & O_CLOEXEC) ?
		   "RDWR|CLOEXEC" : "other");
		return fake_fd;
	}
	return real(path, flags, mode);
}

int open(const char *path, int flags, ...)
{
	static int (*real)(const char *, int, ...);
	va_list ap;
	mode_t mode;
	if (!real)
		real = (int (*)(const char *, int, ...))dlsym(RTLD_NEXT, "open");
	va_start(ap, flags);
	mode = va_arg(ap, mode_t);
	va_end(ap);
	return fake_open(path, flags, mode, real);
}

int open64(const char *path, int flags, ...)
{
	static int (*real)(const char *, int, ...);
	va_list ap;
	mode_t mode;
	if (!real)
		real = (int (*)(const char *, int, ...))dlsym(RTLD_NEXT, "open64");
	va_start(ap, flags);
	mode = va_arg(ap, mode_t);
	va_end(ap);
	return fake_open(path, flags, mode, real);
}

int ioctl(int fd, unsigned long req, ...)
{
	va_list ap;
	void *arg;
	va_start(ap, req);
	arg = va_arg(ap, void *);
	va_end(ap);
	if (fd != fake_fd)
		abort();

	if (req == DRM_IOCTL_MODE_GETRESOURCES) {
		struct drm_mode_card_res *r = arg;
		if (r->connector_id_ptr) {
			*(uint32_t *)(uintptr_t)r->connector_id_ptr = CONN;
			*(uint32_t *)(uintptr_t)r->crtc_id_ptr = CRTC;
			lg("GETRESOURCES fill caps=%u,%u,%u,%u", r->count_connectors,
			   r->count_crtcs, r->count_encoders, r->count_fbs);
		} else {
			lg("GETRESOURCES count");
		}
		r->count_connectors = r->count_crtcs = r->count_encoders = 1;
		r->count_fbs = 0;
		return 0;
	}
	if (req == DRM_IOCTL_MODE_GETCONNECTOR) {
		struct drm_mode_get_connector *c = arg;
		lg("GETCONNECTOR id=%u modes_ptr=%s", c->connector_id,
		   c->modes_ptr ? "set" : "0");
		if (c->modes_ptr) {
			struct drm_mode_modeinfo *m = (void *)(uintptr_t)c->modes_ptr;
			memset(m, 0, sizeof(*m));
			m->hdisplay = 320;
			m->vdisplay = H;
			m->vrefresh = 60;
			strcpy(m->name, "320x240");
		}
		c->count_modes = 1;
		c->count_props = 3;
		c->count_encoders = 1;
		return 0;
	}
	if (req == DRM_IOCTL_MODE_CREATE_DUMB) {
		struct drm_mode_create_dumb *d = arg;
		lg("CREATE_DUMB %ux%u bpp=%u", d->width, d->height, d->bpp);
		d->pitch = PITCH;
		d->size = (uint64_t)PITCH * d->height;
		d->handle = HANDLE;
		return 0;
	}
	if (req == DRM_IOCTL_MODE_ADDFB) {
		struct drm_mode_fb_cmd *f = arg;
		lg("ADDFB %ux%u bpp=%u depth=%u pitch=%u handle=%u", f->width,
		   f->height, f->bpp, f->depth, f->pitch, f->handle);
		f->fb_id = FB;
		return 0;
	}
	if (req == DRM_IOCTL_MODE_MAP_DUMB) {
		struct drm_mode_map_dumb *m = arg;
		lg("MAP_DUMB handle=%u", m->handle);
		m->offset = 0x10000;
		return 0;
	}
	if (req == DRM_IOCTL_MODE_SETCRTC) {
		struct drm_mode_crtc *s = arg;
		lg("SETCRTC crtc=%u fb=%u conn=%u count=%u valid=%u mode=%ux%u %s",
		   s->crtc_id, s->fb_id,
		   *(uint32_t *)(uintptr_t)s->set_connectors_ptr,
		   s->count_connectors, s->mode_valid, s->mode.hdisplay,
		   s->mode.vdisplay, s->mode.name);
		return 0;
	}
	lg("UNEXPECTED ioctl 0x%lx", req);
	abort();
}

void *mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off)
{
	static void *(*real)(void *, size_t, int, int, int, off_t);
	if (!real)
		real = (void *(*)(void *, size_t, int, int, int, off_t))dlsym(RTLD_NEXT, "mmap");
	if (fd == fake_fd && fd >= 0) {
		lg("mmap len=%zu prot=%s shared=%d off=0x%lx", len,
		   prot == (PROT_READ | PROT_WRITE) ? "RW" : "other",
		   !!(flags & MAP_SHARED), (unsigned long)off);
		fb = calloc(1, len);
		return fb;
	}
	return real(addr, len, prot, flags, fd, off);
}

int pause(void)
{
	FILE *f = fopen(getenv("FAKEDRM_FB"), "wb");
	lg("pause");
	fwrite(fb, 1, (size_t)PITCH * H, f);
	fclose(f);
	fflush(stdout);
	_exit(42);
}
