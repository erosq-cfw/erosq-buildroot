/*
 * erosq-uilaunch -- boot launcher for erosq-ui with the splash as fallback.
 *
 * Replaces S90erosq-ui's `setsid sh -c '/usr/bin/erosq-ui || /sbin/erosq-splash'`
 * with the same semantics and a much smaller resident parent (the busybox sh
 * that waits on erosq-ui costs ~52 kB anon+swap; this costs a few pages):
 *   - run erosq-ui as a child and wait for it;
 *   - exit status 0             -> exit 0, no splash;
 *   - non-zero exit, killed by any signal, or exec failure (127)
 *                               -> exec the splash in THIS pid, exactly as
 *                                  `a || b` does when b is the last command.
 * Static, no stdio, no malloc: only the stack and a few data pages are dirty.
 *
 * Usage: erosq-uilaunch [UI [SPLASH]]   (paths default to the shipped ones;
 * the arguments exist only so the fallback can be tested with a copy in /data)
 */
#include <errno.h>
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    const char *ui = argc > 1 ? argv[1] : "/usr/bin/erosq-ui";
    const char *splash = argc > 2 ? argv[2] : "/sbin/erosq-splash";

    pid_t pid = fork();
    if (pid == 0) {
        execl(ui, ui, (char *)0);
        _exit(127);                       /* same status sh gives a missing command */
    }
    if (pid > 0) {
        int st;
        while (waitpid(pid, &st, 0) < 0)
            if (errno != EINTR) { st = 1; break; }
        if (WIFEXITED(st) && WEXITSTATUS(st) == 0)
            return 0;
    }
    execl(splash, splash, (char *)0);
    return 127;
}
