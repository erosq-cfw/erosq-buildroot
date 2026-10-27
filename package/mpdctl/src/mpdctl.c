// SPDX-License-Identifier: MIT
// Copyright (c) 2026 erosqcfw
/*
 * mpdctl: minimal MPD client over the AF_UNIX socket (MPD on the EROS Q has
 * TCP disabled and busybox nc has no -U).
 *
 *   mpdctl 'cmd one' 'cmd two' ...
 *
 * Each argument is sent as one MPD command line, followed by "close"; every
 * byte MPD replies is copied to stdout until EOF. Socket path comes from
 * $MPD_HOST_SOCK, default /run/mpd.sock. Exit 1 if the socket can't be
 * opened or connected, else 0.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>

int main(int argc, char **argv)
{
	const char *path = getenv("MPD_HOST_SOCK");
	if (!path)
		path = "/run/mpd.sock";
	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0) { perror("socket"); return 1; }
	struct sockaddr_un sa;
	memset(&sa, 0, sizeof sa);
	sa.sun_family = AF_UNIX;
	strncpy(sa.sun_path, path, sizeof sa.sun_path - 1);
	if (connect(fd, (struct sockaddr *)&sa, sizeof sa) < 0) { perror("connect"); return 1; }
	for (int i = 1; i < argc; i++) {
		(void)!write(fd, argv[i], strlen(argv[i]));
		(void)!write(fd, "\n", 1);
	}
	(void)!write(fd, "close\n", 6);
	char buf[4096];
	ssize_t n;
	while ((n = read(fd, buf, sizeof buf)) > 0)
		(void)!write(1, buf, n);
	close(fd);
	return 0;
}
