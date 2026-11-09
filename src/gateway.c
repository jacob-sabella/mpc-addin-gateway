// mpc-addin-gateway: preloaded into MPC, this addin starts Caddy (a web server, its own static binary in the
// addin's folder) beside MPC, as one password-protected HTTPS front door for the web servers other addins run on
// the device.
//
// The library itself does almost nothing inside MPC: once, as MPC starts, it starts gateway-run.sh from its folder
// as a separate process and returns. That script writes Caddy's config from the settings file, runs it, restarts
// it if it exits, and stops it when MPC exits. The script is started through a double fork, with everything prepared
// before the first fork (MPC may already have threads from other addins), so the children only make plain system
// calls until the exec. It runs detached (its own session), without LD_PRELOAD, with every signal at its default, at
// the settings' nice value and in the idle I/O class, so Caddy gets disk time only when MPC isn't using it.
// It starts only in the process whose executable is named MPC (or MPC Sample, on the MPC Sample); anything else that
// inherits LD_PRELOAD loads it and does nothing.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef ADDIN_VERSION
#define ADDIN_VERSION "dev"
#endif
#define API __attribute__((visibility("default")))
#define RUN_SCRIPT "gateway-run.sh"
#define IOPRIO_CLASS_IDLE 3
#define IOPRIO_WHO_PROCESS 1

static struct {
    int enabled, nice;
} C;

static void LOG(const char *fmt, ...)
{
    char b[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(b, sizeof b, fmt, ap);
    va_end(ap);
    fprintf(stderr, "mpc-gateway-addin: %s", b);
}

static char *trim(char *s)
{
    while (*s == ' ' || *s == '\t') s++;
    char *e = s + strlen(s);
    while (e > s && (e[-1] == ' ' || e[-1] == '\t' || e[-1] == '\n' || e[-1] == '\r')) *--e = 0;
    if (e - s >= 2 && *s == '"' && e[-1] == '"') { e[-1] = 0; s++; }
    return s;
}

static int to_int(const char *v, int lo, int hi, int *out)
{
    char *end;
    long n = strtol(v, &end, 10);
    if (!*v || *end || n < lo || n > hi) return -1;
    *out = (int)n;
    return 0;
}

// Only enabled= and nice= are read here; the script reads the rest of the file. Returns the lines not understood.
static int conf_load(const char *path)
{
    C.enabled = 1;
    C.nice = 19;
    FILE *f = fopen(path, "re");
    if (!f) return 0;
    char line[1024];
    int bad = 0;
    while (fgets(line, sizeof line, f)) {
        char *s = trim(line);
        if (!*s || *s == '#') continue;
        char *eq = strchr(s, '=');
        if (!eq) { bad++; continue; }
        *eq = 0;
        const char *k = trim(s), *v = trim(eq + 1);
        if (!strcmp(k, "enabled") && to_int(v, 0, 1, &C.enabled)) bad++;
        if (!strcmp(k, "nice") && to_int(v, 0, 19, &C.nice)) bad++;
    }
    fclose(f);
    return bad;
}

// The folder this .so was loaded from (the settings file and the script sit next to it), through /proc/self/maps.
static void addin_dir(char *out, size_t n)
{
    out[0] = 0;
    FILE *f = fopen("/proc/self/maps", "re");
    if (!f) return;
    uintptr_t me = (uintptr_t)&addin_dir;
    char line[512];
    while (fgets(line, sizeof line, f)) {
        unsigned long a, b;
        char *path = strchr(line, '/');
        if (!path || sscanf(line, "%lx-%lx", &a, &b) != 2 || me < a || me >= b) continue;
        path[strcspn(path, "\n")] = 0;
        char *slash = strrchr(path, '/');
        if (slash) *slash = 0;
        snprintf(out, n, "%s", path);
        break;
    }
    fclose(f);
}

static int is_mpc_process(void)
{
    char exe[256];
    ssize_t n = readlink("/proc/self/exe", exe, sizeof exe - 1);
    if (n <= 0) return 0;
    exe[n] = 0;
    const char *base = strrchr(exe, '/');
    base = base ? base + 1 : exe;
    return !strcmp(base, "MPC") || !strcmp(base, "MPC Sample");   // the MPC Sample's binary is /usr/bin/MPC Sample
}

// The grandchild, between fork and exec: raw system calls only, never a libc function by name. The fork happens in
// this library's constructor, which runs before the other preloaded libraries' constructors (the last one preloaded is
// initialised first), and a preload that overrides open() or close() (the device's MIDI injector does) would otherwise
// run here, in a copy of MPC whose other addins aren't initialised yet: on a Key 37 that ran their start-up in this
// process, which then bound their ports and made a second MIDI client before the exec (docs/NOTES.md, 2026-11-05).
static void __attribute__((noreturn)) exec_script(const char *sh, char *const argv[], char *const envp[], int nice)
{
    syscall(SYS_setsid);
    unsigned long zero[16] = {0};   // an empty signal mask, and a kernel sigaction that is SIG_DFL in every layout
    syscall(SYS_rt_sigprocmask, SIG_SETMASK, zero, NULL, (long)(_NSIG / 8));
    for (int s = 1; s < 65; s++)    // fails harmlessly for SIGKILL, SIGSTOP and gaps
        syscall(SYS_rt_sigaction, s, zero, NULL, (long)(_NSIG / 8));
    struct sched_param sp = {0};
    syscall(SYS_sched_setscheduler, 0, SCHED_OTHER, &sp);   // in case the forking thread was real-time
    syscall(SYS_setpriority, PRIO_PROCESS, 0, nice);
    syscall(SYS_ioprio_set, IOPRIO_WHO_PROCESS, 0, IOPRIO_CLASS_IDLE << 13);
    long null = syscall(SYS_openat, AT_FDCWD, "/dev/null", O_RDWR);
    for (int fd = 0; null >= 0 && fd < 3; fd++) if (fd != null) syscall(SYS_dup3, null, fd, 0);
    struct { unsigned long long cur, max; } rl;
    int max = syscall(SYS_prlimit64, 0, RLIMIT_NOFILE, NULL, &rl) == 0 && rl.cur < 65536 ? (int)rl.cur : 65536;
    for (int fd = 3; fd < max; fd++) syscall(SYS_close, fd);
    syscall(SYS_execve, sh, argv, envp);
    syscall(SYS_exit_group, 127);
    __builtin_unreachable();
}

// Settings, then the script. 0 when it was started, -1 when disabled or it failed. A test harness calls it directly.
API int mpc_gateway_addin_start(void)
{
    char dir[400], path[512], script[512];
    addin_dir(dir, sizeof dir);
    if (!dir[0]) { LOG("can't find my own folder\n"); return -1; }
    snprintf(path, sizeof path, "%s/mpc_gateway_addin.conf", dir);
    int bad = conf_load(path);
    if (bad) LOG("%d line(s) of %s not understood, ignored\n", bad, path);
    if (!C.enabled) { LOG("disabled in %s\n", path); return -1; }
    snprintf(script, sizeof script, "%s/" RUN_SCRIPT, dir);
    if (access(script, R_OK)) { LOG("no %s: reinstall the addin\n", script); return -1; }

    const char *sh = getenv("MPC_GATEWAY_ADDIN_SH");   // tests: the shell to run the script with
    if (!sh || !*sh) sh = "/bin/sh";
    char e_dir[512], e_pid[32], e_home[512];
    snprintf(e_dir, sizeof e_dir, "ADDIN_DIR=%s", dir);
    snprintf(e_pid, sizeof e_pid, "MPC_PID=%ld", (long)getpid());
    snprintf(e_home, sizeof e_home, "HOME=%s", dir);
    char *argv[] = {(char *)sh, script, NULL};
    char *envp[] = {e_dir, e_pid, e_home, "PATH=/usr/sbin:/usr/bin:/sbin:/bin", NULL};

    pid_t child = fork();
    if (child < 0) { LOG("can't start %s: %s\n", RUN_SCRIPT, strerror(errno)); return -1; }
    if (child == 0) {
        pid_t g = fork();   // the grandchild runs the script; this child exits at once, so MPC never has to reap it
        if (g == 0) exec_script(sh, argv, envp, C.nice);
        _exit(g < 0 ? 1 : 0);
    }
    int st = 0;
    pid_t w;
    while ((w = waitpid(child, &st, 0)) < 0 && errno == EINTR) {}
    // w < 0 (ECHILD) when SIGCHLD is ignored: the child was reaped already and its status is unknown
    if (w == child && (!WIFEXITED(st) || WEXITSTATUS(st))) { LOG("can't start %s\n", RUN_SCRIPT); return -1; }
    return 0;
}

__attribute__((constructor)) static void addin_init(void)
{
    if (getenv("MPC_GATEWAY_ADDIN_DISABLE") || !is_mpc_process()) return;
    LOG("version %s\n", ADDIN_VERSION);
    if (mpc_gateway_addin_start() == 0) LOG("started %s\n", RUN_SCRIPT);
}
