// gateway-settings: the gateway's settings page backend. gateway-run.sh starts it beside Caddy; it listens on a Unix
// socket in the gateway's folder (never on the network), and Caddy sends it /settings/api, behind the gateway's password.
//   GET  /settings/api   the settings as JSON (never the password itself: only whether it is the default)
//   POST /settings/api   form fields (application/x-www-form-urlencoded) for any of the keys below. Every value is
//                        checked; then mpc_gateway_addin.conf is rewritten in place (comments and order kept, through
//                        a .new file and rename) and settings.changed is made, which gateway-run.sh sees and restarts with.
// A POST needs the header X-Gateway-Settings: 1. A page on another site can't send that header without a CORS
// preflight, which nothing here answers, so it can't change the settings through a browser that has the password.
// One request at a time, 5 s to send it, 16 KB at most: it's a settings page, used by one person now and then.
// Usage: gateway-settings <socket path> <settings file>
#define _GNU_SOURCE
#include <ctype.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

#define MAX_REQ 16384
#define MAX_VAL 512
#define MAX_CONF 65536

static const char *KEYS[] = {"enabled", "bind", "port", "user", "password", "forward", "nice", "memory_mb", "rescan_s",
                             "log", "config", "addins_dir"};
#define NKEYS (sizeof KEYS / sizeof *KEYS)
static const char *conf_path;
static char changed_path[4096];

static int key_index(const char *k) {
    for (size_t i = 0; i < NKEYS; i++)
        if (!strcmp(k, KEYS[i])) return (int)i;
    return -1;
}

static int num_in(const char *v, long lo, long hi) {
    if (!*v || strlen(v) > 6) return 0;
    for (const char *p = v; *p; p++)
        if (!isdigit((unsigned char)*p)) return 0;
    long n = strtol(v, NULL, 10);
    return n >= lo && n <= hi;
}
static int chars_in(const char *v, const char *extra) {
    for (const char *p = v; *p; p++)
        if (!isalnum((unsigned char)*p) && !strchr(extra, *p)) return 0;
    return 1;
}
static int path_ok(const char *v) {   // empty, or an absolute path of plain characters with no . or .. part
    if (!*v) return 1;
    if (*v != '/' || !chars_in(v, "/._-") || strstr(v, "//")) return 0;
    for (const char *p = v; (p = strchr(p, '/')); p++)
        if (!strncmp(p, "/./", 3) || !strncmp(p, "/../", 4) || !strcmp(p, "/.") || !strcmp(p, "/..")) return 0;
    return 1;
}
static int forward_ok(const char *v) {   // name:local_port:gateway_port, separated by single spaces
    char buf[MAX_VAL + 1];
    if (strlen(v) > MAX_VAL) return 0;
    strcpy(buf, v);
    for (char *save = NULL, *t = strtok_r(buf, " ", &save); t; t = strtok_r(NULL, " ", &save)) {
        char *a = strchr(t, ':'), *b = a ? strchr(a + 1, ':') : NULL;
        if (!a || !b || a == t) return 0;
        *a = *b = 0;
        if (!chars_in(t, "_-") || !num_in(a + 1, 1, 65535) || !num_in(b + 1, 1, 65535)) return 0;
    }
    return 1;
}
// Why a value is refused, or NULL when it's fine.
static const char *refuse(const char *k, const char *v) {
    if (strlen(v) > MAX_VAL) return "too long";
    for (const char *p = v; *p; p++)
        if ((unsigned char)*p < 0x20 || *p == 0x7f) return "control characters";
    if (!strcmp(k, "enabled")) return !strcmp(v, "0") || !strcmp(v, "1") ? NULL : "0 or 1";
    if (!strcmp(k, "bind")) return !strcmp(v, "127.0.0.1") || !strcmp(v, "0.0.0.0") ? NULL : "127.0.0.1 or 0.0.0.0";
    if (!strcmp(k, "port")) return num_in(v, 1, 65535) ? NULL : "a port, 1 to 65535";
    if (!strcmp(k, "user")) return *v && strlen(v) <= 32 && chars_in(v, "._-") ? NULL : "1 to 32 letters, digits, . _ -";
    if (!strcmp(k, "password"))   // "" keeps the one there is; the page never sends ""
        return strlen(v) <= 128 && !strpbrk(v, " \t\"'\\") ? NULL : "no spaces, quotes or backslashes";
    if (!strcmp(k, "forward")) return forward_ok(v) ? NULL : "name:local_port:gateway_port, separated by spaces";
    if (!strcmp(k, "nice")) return num_in(v, 0, 19) ? NULL : "0 to 19";
    if (!strcmp(k, "memory_mb")) return num_in(v, 16, 4096) ? NULL : "16 to 4096";
    if (!strcmp(k, "rescan_s")) return num_in(v, 2, 3600) ? NULL : "2 to 3600";
    return path_ok(v) ? NULL : "empty, or an absolute path (letters, digits, / . _ -)";   // log, config, addins_dir
}

// The settings file's value for a key, as gateway-run.sh reads it: the last key= line, blanks and quotes trimmed.
static void conf_value(const char *text, const char *k, char *out, size_t n) {
    size_t kl = strlen(k);
    out[0] = 0;
    for (const char *line = text; line && *line; line = strchr(line, '\n') ? strchr(line, '\n') + 1 : NULL) {
        const char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (strncmp(p, k, kl)) continue;
        p += kl;
        while (*p == ' ' || *p == '\t') p++;
        if (*p != '=') continue;
        p++;
        while (*p == ' ' || *p == '\t') p++;
        const char *e = strchr(p, '\n');
        size_t l = e ? (size_t)(e - p) : strlen(p);
        while (l && (p[l - 1] == ' ' || p[l - 1] == '\t' || p[l - 1] == '\r')) l--;
        if (l >= 2 && p[0] == '"' && p[l - 1] == '"') p++, l -= 2;
        if (l >= n) l = n - 1;
        memcpy(out, p, l);
        out[l] = 0;
    }
}
static char *read_conf(void) {
    FILE *f = fopen(conf_path, "r");
    if (!f) return NULL;
    char *b = malloc(MAX_CONF + 1);
    size_t n = b ? fread(b, 1, MAX_CONF, f) : 0;
    fclose(f);
    if (b) b[n] = 0;
    return b;
}

static void reply(int fd, int code, const char *body) {
    char h[256];
    const char *why = code == 200 ? "OK" : code == 400 ? "Bad Request" : code == 403 ? "Forbidden" : code == 404 ? "Not Found" : "Error";
    int n = snprintf(h, sizeof h, "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nCache-Control: no-store\r\n"
                     "Content-Length: %zu\r\nConnection: close\r\n\r\n", code, why, strlen(body));
    if (write(fd, h, (size_t)n) < 0 || write(fd, body, strlen(body)) < 0) return;
}
static void reply_error(int fd, int code, const char *key, const char *why) {
    char b[512];
    snprintf(b, sizeof b, "{\"error\":\"%s%s%s\"}", key ? key : "", key ? ": " : "", why);
    reply(fd, code, b);
}
static void json_str(char *out, size_t n, const char *v) {   // values are checked, but escape anyway
    size_t o = 0;
    for (; *v && o + 7 < n; v++) {
        if (*v == '"' || *v == '\\') out[o++] = '\\', out[o++] = *v;
        else if ((unsigned char)*v < 0x20) o += (size_t)snprintf(out + o, n - o, "\\u%04x", *v);
        else out[o++] = *v;
    }
    out[o] = 0;
}

static void get_settings(int fd) {
    char *text = read_conf();
    if (!text) { reply_error(fd, 500, NULL, "can't read the settings file"); return; }
    char body[8192], v[MAX_VAL + 1], e[MAX_VAL * 6 + 1], pw[MAX_VAL + 1];
    size_t o = (size_t)snprintf(body, sizeof body, "{");
    for (size_t i = 0; i < NKEYS; i++) {
        if (!strcmp(KEYS[i], "password")) continue;
        conf_value(text, KEYS[i], v, sizeof v);
        json_str(e, sizeof e, v);
        o += (size_t)snprintf(body + o, sizeof body - o, "\"%s\":\"%s\",", KEYS[i], e);
        if (o >= sizeof body) break;
    }
    conf_value(text, "password", pw, sizeof pw);
    snprintf(body + o, sizeof body - o, "\"default_password\":%s}", !*pw || !strcmp(pw, "mpc") ? "true" : "false");
    free(text);
    reply(fd, 200, body);
}

static int hexval(int c) { return isdigit(c) ? c - '0' : isxdigit(c) ? (tolower(c) - 'a' + 10) : -1; }
static int url_decode(char *s) {   // in place; 0 on a bad escape
    char *o = s;
    for (; *s; s++) {
        if (*s == '+') *o++ = ' ';
        else if (*s == '%') {
            int a = hexval((unsigned char)s[1]), b = a < 0 ? -1 : hexval((unsigned char)s[2]);
            if (b < 0) return 0;
            *o++ = (char)(a * 16 + b);
            s += 2;
        } else *o++ = *s;
    }
    *o = 0;
    return 1;
}

static void post_settings(int fd, char *body) {
    char *val[NKEYS] = {0};
    for (char *save = NULL, *pair = strtok_r(body, "&", &save); pair; pair = strtok_r(NULL, "&", &save)) {
        char *eq = strchr(pair, '=');
        if (!eq) { reply_error(fd, 400, NULL, "a field without a value"); return; }
        *eq = 0;
        if (!url_decode(pair) || !url_decode(eq + 1)) { reply_error(fd, 400, NULL, "a bad % escape"); return; }
        int i = key_index(pair);
        if (i < 0) { reply_error(fd, 400, NULL, "an unknown setting"); return; }
        const char *why = refuse(pair, eq + 1);
        if (why) { reply_error(fd, 400, KEYS[i], why); return; }
        val[i] = eq + 1;
    }
    int pw = key_index("password");
    if (val[pw] && !*val[pw]) val[pw] = NULL;   // empty: keep the password there is

    char *text = read_conf();
    if (!text) { reply_error(fd, 500, NULL, "can't read the settings file"); return; }
    char tmp[4200];
    snprintf(tmp, sizeof tmp, "%s.new", conf_path);
    FILE *f = fopen(tmp, "w");
    if (!f) { free(text); reply_error(fd, 500, NULL, "can't write the settings file"); return; }
    int done[NKEYS] = {0};
    for (char *line = text; *line;) {
        char *nl = strchr(line, '\n');
        size_t len = nl ? (size_t)(nl - line) : strlen(line);
        const char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        int hit = -1;
        for (size_t i = 0; i < NKEYS && hit < 0; i++) {
            size_t kl = strlen(KEYS[i]);
            const char *q = p + kl;
            while (*q == ' ' || *q == '\t') q++;
            if (val[i] && !strncmp(p, KEYS[i], kl) && *q == '=' && q < line + len) hit = (int)i;
        }
        if (hit >= 0) { fprintf(f, "%s=%s\n", KEYS[hit], val[hit]); done[hit] = 1; }
        else fprintf(f, "%.*s\n", (int)len, line);
        line += len + (nl ? 1 : 0);
    }
    for (size_t i = 0; i < NKEYS; i++)
        if (val[i] && !done[i]) fprintf(f, "%s=%s\n", KEYS[i], val[i]);
    free(text);
    int bad = ferror(f) | (fflush(f) != 0) | (fsync(fileno(f)) != 0);
    bad |= fclose(f) != 0;
    if (bad || rename(tmp, conf_path) != 0) { unlink(tmp); reply_error(fd, 500, NULL, "can't write the settings file"); return; }
    FILE *c = fopen(changed_path, "w");
    if (c) fclose(c);
    reply(fd, 200, "{\"ok\":true}");
}

static const char *header(const char *head, const char *name) {   // the value after "Name:", case-insensitive
    size_t n = strlen(name);
    for (const char *p = strstr(head, "\r\n"); p; p = strstr(p + 2, "\r\n")) {
        if (!strncasecmp(p + 2, name, n) && p[2 + n] == ':') {
            const char *v = p + 3 + n;
            while (*v == ' ') v++;
            return v;
        }
    }
    return NULL;
}

static void serve(int fd) {
    static char req[MAX_REQ + 1];
    size_t got = 0;
    char *end = NULL;
    while (got < MAX_REQ) {
        ssize_t r = read(fd, req + got, MAX_REQ - got);
        if (r <= 0) return;
        got += (size_t)r;
        req[got] = 0;
        if ((end = strstr(req, "\r\n\r\n"))) break;
    }
    if (!end) { reply_error(fd, 400, NULL, "request too large"); return; }
    *end = 0;
    char *body = end + 4;
    int get = !strncmp(req, "GET /settings/api ", 18), post = !strncmp(req, "POST /settings/api ", 19);
    if (!get && !post) { reply_error(fd, 404, NULL, "not here"); return; }
    if (get) { get_settings(fd); return; }
    // The whole body is read before any answer: closing with some of it unread would reset the connection, and Caddy
    // would answer 502 instead of passing the refusal on.
    const char *cl = header(req, "Content-Length");
    long want = cl ? strtol(cl, NULL, 10) : -1;
    size_t have = got - (size_t)(body - req);
    if (want < 0 || (size_t)want > MAX_REQ - (size_t)(body - req)) { reply_error(fd, 400, NULL, "a body of up to 16 KB"); return; }
    while (have < (size_t)want) {
        ssize_t r = read(fd, body + have, (size_t)want - have);
        if (r <= 0) return;
        have += (size_t)r;
    }
    body[want] = 0;
    const char *x = header(req, "X-Gateway-Settings");
    if (!x || strncmp(x, "1", 1)) { reply_error(fd, 403, NULL, "the X-Gateway-Settings header is missing"); return; }
    post_settings(fd, body);
}

int main(int argc, char **argv) {
    if (argc != 3 || strlen(argv[1]) >= sizeof(((struct sockaddr_un *)0)->sun_path) || strlen(argv[2]) > 4000) {
        fprintf(stderr, "usage: gateway-settings <socket path> <settings file>\n");
        return 2;
    }
    conf_path = argv[2];
    const char *slash = strrchr(conf_path, '/');   // settings.changed goes next to the settings file
    if (slash) snprintf(changed_path, sizeof changed_path, "%.*s/settings.changed", (int)(slash - conf_path), conf_path);
    else snprintf(changed_path, sizeof changed_path, "settings.changed");
    signal(SIGPIPE, SIG_IGN);
    umask(077);
    int s = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    struct sockaddr_un a = {.sun_family = AF_UNIX};
    strcpy(a.sun_path, argv[1]);
    unlink(argv[1]);
    if (s < 0 || bind(s, (struct sockaddr *)&a, sizeof a) < 0 || listen(s, 4) < 0) {
        fprintf(stderr, "gateway-settings: can't listen on %s: %s\n", argv[1], strerror(errno));
        return 1;
    }
    for (;;) {
        int c = accept4(s, NULL, NULL, SOCK_CLOEXEC);
        if (c < 0) { if (errno == EINTR) continue; return 1; }
        struct timeval t = {.tv_sec = 5};
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &t, sizeof t);
        setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &t, sizeof t);
        serve(c);
        close(c);
    }
}
