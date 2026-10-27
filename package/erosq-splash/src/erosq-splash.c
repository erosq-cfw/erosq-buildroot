// SPDX-License-Identifier: MIT
// Copyright (c) 2026 erosqcfw
/* erosq boot splash: load an RGB565 image onto /dev/dri/card0 and hold the
 * modeset (so it stays until a GUI takes over). Image = argv[1] or /etc/splash.raw
 * (320x240 RGB565, little-endian). No libdrm. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <drm/drm.h>
#include <drm/drm_mode.h>

#define W 320
#define H 240

int main(int argc, char **argv)
{
	const char *path = argc > 1 ? argv[1] : "/etc/splash.raw";
	uint16_t raw[W * H];
	int rf = open(path, O_RDONLY);
	if (rf < 0) { perror("open splash"); return 1; }
	if (read(rf, raw, sizeof(raw)) != (ssize_t)sizeof(raw)) { fprintf(stderr, "short splash\n"); return 1; }
	close(rf);

	int fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
	if (fd < 0) { perror("open card0"); return 1; }

	struct drm_mode_card_res res = {0};
	if (ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res)) { perror("getres0"); return 1; }
	uint32_t conn[8] = {0}, crtc[8] = {0}, enc[8] = {0}, fbs[8] = {0};
	res.connector_id_ptr = (uintptr_t)conn; res.count_connectors = 8;
	res.crtc_id_ptr = (uintptr_t)crtc; res.count_crtcs = 8;
	res.encoder_id_ptr = (uintptr_t)enc; res.count_encoders = 8;
	res.fb_id_ptr = (uintptr_t)fbs; res.count_fbs = 8;
	if (ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res)) { perror("getres"); return 1; }
	if (!res.count_connectors || !res.count_crtcs) { fprintf(stderr, "no conn/crtc\n"); return 1; }

	struct drm_mode_get_connector gc = { .connector_id = conn[0] };
	struct drm_mode_modeinfo modes[16];
	if (ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &gc)) { perror("getconn"); return 1; }
	gc.modes_ptr = (uintptr_t)modes;
	if (gc.count_modes > 16) gc.count_modes = 16;
	gc.count_props = 0; gc.props_ptr = 0; gc.prop_values_ptr = 0;
	gc.count_encoders = 0; gc.encoders_ptr = 0;
	if (ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &gc)) { perror("getconn2"); return 1; }
	if (!gc.count_modes) { fprintf(stderr, "no modes\n"); return 1; }

	struct drm_mode_create_dumb cd = { .width = W, .height = H, .bpp = 16 };
	if (ioctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &cd)) { perror("create_dumb"); return 1; }
	struct drm_mode_fb_cmd fbc = { .width = W, .height = H, .bpp = 16,
		.depth = 16, .pitch = cd.pitch, .handle = cd.handle };
	if (ioctl(fd, DRM_IOCTL_MODE_ADDFB, &fbc)) { perror("addfb"); return 1; }
	struct drm_mode_map_dumb md = { .handle = cd.handle };
	if (ioctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &md)) { perror("map_dumb"); return 1; }
	uint8_t *map = mmap(NULL, cd.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, md.offset);
	if (map == MAP_FAILED) { perror("mmap"); return 1; }

	for (int y = 0; y < H; y++)
		memcpy(map + y * cd.pitch, raw + y * W, W * 2);

	struct drm_mode_crtc sc = { .crtc_id = crtc[0], .fb_id = fbc.fb_id,
		.set_connectors_ptr = (uintptr_t)&conn[0], .count_connectors = 1,
		.mode_valid = 1, .mode = modes[0] };
	if (ioctl(fd, DRM_IOCTL_MODE_SETCRTC, &sc)) { perror("setcrtc"); return 1; }

	printf("splash up\n");
	for (;;) pause();	/* hold the modeset until killed (e.g. by the GUI) */
	return 0;
}
