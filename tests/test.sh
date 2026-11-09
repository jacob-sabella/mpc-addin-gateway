#!/usr/bin/env bash
# Host tests (x86): the library preloaded into a process named MPC starts gateway-run.sh as a detached process (own
# session, not MPC's child, no LD_PRELOAD, the settings' nice value), the script runs ./caddy (a stand-in here that
# records what it is asked) with the Caddyfile it wrote, and stops it once MPC exits; enabled=0, a process with another
# name and a missing script start nothing and leave MPC running. Then the Caddyfile and services.json the script makes
# from addins' manifests: port services and their gateway ports (collisions move up), path services, the port setting,
# refusals of odd keys, forward=, and fallbacks for bad settings. The script runs in /bin/sh and in BusyBox (installed,
# or a static one taken from Docker's busybox:musl image). tests/smoke.sh runs the real Caddy under QEMU.
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d)
cleanup() { pkill -f "$T/" 2>/dev/null || true; rm -rf "$T"; }
trap cleanup EXIT
gcc -std=gnu11 -O1 -g -Wall -Wextra -Werror -fPIC -shared -fvisibility=hidden -o "$T/mpc_gateway_addin.so" src/gateway.c
gcc -std=gnu11 -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined -o "$T/gateway-settings" src/settings.c
mkdir -p "$T/bin"
# A stand-in that sleeps under any name. Not a copy of sleep: a multi-call coreutils picks the tool from its name.
printf '#include <stdlib.h>\n#include <unistd.h>\nint main(int c, char **v) { sleep(c > 1 ? atoi(v[1]) : 60); return 0; }\n' |
    gcc -x c -o "$T/bin/MPC" -
cp "$T/bin/MPC" "$T/bin/other"; cp "$T/bin/MPC" "$T/bin/MPC Sample"
BB=$(command -v busybox || true)
if [ -z "$BB" ] && command -v docker > /dev/null; then
    docker run --rm busybox:1.36-musl cat /bin/busybox > "$T/bin/busybox" 2>/dev/null && chmod 755 "$T/bin/busybox" && BB=$T/bin/busybox
fi
fail=0; check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
wait_for() { i=0; while [ $i -lt 50 ]; do eval "$1" && return 0; sleep 0.1; i=$((i + 1)); done; return 1; }
gone() { [ ! -d "/proc/$1" ] || grep -q '^State:.*Z' "/proc/$1/status"; }
field() { sed 's/.*) //' "/proc/$1/stat" | cut -d' ' -f"$2"; }   # fields counted from 3 (state)

# A fresh set of addins: the gateway (the library, the script, a stand-in caddy, settings with the given extra lines)
# and the given addins' manifests (made by the caller in $T/addins/<id>/).
G=$T/addins/gateway
setup() {
    rm -rf "$T/addins"; mkdir -p "$G"
    cp "$T/mpc_gateway_addin.so" "$T/gateway-settings" gateway-run.sh "$G/"
    cat > "$G/caddy" <<'EOF'
#!/bin/sh
case "$1" in
    hash-password) cat > /dev/null; echo '$2a$10$fakehashfakehashfakehash' ;;
    validate)   # refuses a config that imports a file holding INVALID
        for f in $(sed -n 's/^[[:space:]]*import //p' "$3"); do grep -q INVALID "$f" && exit 1; done; exit 0 ;;
    run) env > "$HOME/fake.env"; echo "$@" > "$HOME/fake.args"; echo $$ > "$HOME/fake.pid"
         trap 'echo stopped > "$HOME/fake.stopped"; exit 0' TERM
         while :; do sleep 0.2; done ;;
    reload) echo reload >> "$HOME/fake.reloads" ;;
esac
EOF
    chmod 644 "$G/caddy"   # as a copy through a FAT card leaves it
    { echo "nice=17"; echo "log=$G/log.txt"; printf '%s\n' "$@"; } > "$G/mpc_gateway_addin.conf"
}
manifest() {   # id, lines...
    mkdir -p "$T/addins/$1"; m=$T/addins/$1/addin.manifest; shift; printf '%s\n' "$@" > "$m"
}
mpc() {   # start "MPC" (or another program) with the addin preloaded; sets PID
    LD_PRELOAD="$G/mpc_gateway_addin.so" "$T/bin/${1:-MPC}" 60 2> "$T/mpc.err" &
    PID=$!
}
started() { wait_for "[ -s $G/fake.pid ]"; }
stop_mpc() { kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; wait_for "[ ! -e $G/run.pid ]" || true; }
svc() { grep -q "$1" "$G/www/services.json"; }
api() { curl -s --max-time 5 --unix-socket "$G/settings.sock" "$@" http://gateway/settings/api; }   # the settings backend

echo "--- the device's BusyBox"
# The devices' BusyBox (1.36.1, MPC OS 3.x) lacks some options other builds have: head -c and head -NUM (2026-11-09).
check "no head -c or head -NUM in the script" '! grep -nE "head +-(c|[0-9])" gateway-run.sh'

for SH in /bin/sh ${BB:+busybox}; do
    echo "--- script run by $SH"
    if [ "$SH" = busybox ]; then
        printf '#!/bin/sh\nexec %s sh "$@"\n' "$BB" > "$T/bin/bbsh"; chmod 755 "$T/bin/bbsh"
        export MPC_GATEWAY_ADDIN_SH="$T/bin/bbsh"
    else
        unset MPC_GATEWAY_ADDIN_SH
    fi
    setup "rescan_s=2"
    manifest remote 'ADDIN_NAME="MPC Remote"' ADDIN_WEB_PORT=6720
    manifest files 'ADDIN_NAME="Files"' ADDIN_CONF=files.conf ADDIN_WEB_PORT=6760 ADDIN_WEB_PORT_SETTING=port ADDIN_WEB_PATH=/files/
    printf 'port=6799\n' > "$T/addins/files/files.conf"
    mpc
    check "caddy started" started
    C=$(cat "$G/fake.pid" 2>/dev/null || echo 0)
    RUNNER=$(field "$C" 2 2>/dev/null || echo 0)   # its parent: the script
    check "started with the Caddyfile it wrote" 'grep -q -- "run --config $G/Caddyfile --adapter caddyfile" "$G/fake.args"'
    check "no LD_PRELOAD in its environment" '! grep -q LD_PRELOAD "$G/fake.env"'
    check "MPC_PID is MPC" 'grep -qx "MPC_PID=$PID" "$G/fake.env"'
    check "Go limits and Caddy's folders set" 'grep -qx "GOMAXPROCS=1" "$G/fake.env" && grep -qx "GOMEMLIMIT=64MiB" "$G/fake.env" && grep -qx "XDG_DATA_HOME=$G/xdg" "$G/fake.env"'
    check "script is not MPC's child" '[ "$(field "$RUNNER" 2)" != "$PID" ]'
    check "script has its own session" '[ "$(field "$RUNNER" 4)" != "$(field "$PID" 4)" ]'
    check "nice value from the settings" '[ "$(field "$C" 17)" = 17 ]'
    check "caddy made executable" '[ -x "$G/caddy" ]'
    check "default login mpc / mpc, only its hash in the Caddyfile" 'grep -q "mpc \$2a\$10\$fakehash" "$G/Caddyfile" && [ "$(cat "$G/password.sum")" = "$(printf %s mpc | sha256sum | cut -d" " -f1)" ] && [ ! -e "$G/password.txt" ]'
    check "the start page warns about the default password, links Settings" 'grep -q "still has the default password, mpc" "$G/www/index.html" && grep -q "href=\"/settings/\">Settings" "$G/www/index.html"'
    check "the settings page, its backend on a socket here behind the password" '[ -s "$G/www/settings.html" ] && grep -q "reverse_proxy unix/$G/settings.sock" "$G/Caddyfile" && wait_for "[ -S $G/settings.sock ]"'
    check "settings backend: GET shows the settings, never the password" 'api | grep -q "\"port\":\"\",.*\"nice\":\"17\".*\"default_password\":true" && ! api | grep -q "\"password\""'
    check "settings backend: a POST without its header is refused" 'api -X POST -d port=8443 | grep -q "header is missing" && [ ! -e "$G/settings.changed" ] && ! grep -q "^port=" "$G/mpc_gateway_addin.conf"'
    check "settings backend: a bad value is refused, nothing written" 'api -X POST -H "X-Gateway-Settings: 1" -d "bind=0.0.0.0&port=0" | grep -q "port: a port" && ! grep -q "bind=0.0.0.0" "$G/mpc_gateway_addin.conf"'
    check "device only by default" 'grep -q "default_bind 127.0.0.1" "$G/Caddyfile" && grep -q "^https://127.0.0.1:443, https://localhost:443 {" "$G/Caddyfile"'
    check "the login passed on to the addins (X-MPC-Gateway-User)" 'grep -q "header_up X-MPC-Gateway-User {http.auth.user.id}" "$G/Caddyfile"'
    check "a port service gets port + 10000" 'grep -q "^https://127.0.0.1:16720, https://localhost:16720 {" "$G/Caddyfile" && grep -q "reverse_proxy 127.0.0.1:6720 {" "$G/Caddyfile"'
    check "a path service under its path, port from its settings" 'grep -q "redir /files /files/" "$G/Caddyfile" && grep -q "handle /files/\* {" "$G/Caddyfile" && grep -q "reverse_proxy 127.0.0.1:6799 {" "$G/Caddyfile"'
    check "services.json lists both" 'svc "\"id\":\"files\",\"name\":\"Files\",\"port\":6799,\"path\":\"/files/\"" && svc "\"id\":\"remote\",\"name\":\"MPC Remote\",\"port\":6720,\"path\":\"\",\"gateway_port\":16720,\"up\":false"'
    check "the start page lists them" 'grep -q ">Files</a>" "$G/www/index.html" && grep -q "data-port=\"16720\"" "$G/www/index.html"'
    check "MPC itself still running" '! gone "$PID"'
    manifest commander 'ADDIN_NAME="MPC Commander"' ADDIN_WEB_PORT=6730
    check "an addin installed while it runs is picked up, Caddy reloaded" 'wait_for "grep -q 16730 $G/Caddyfile" && wait_for "[ -s $G/fake.reloads ]"'
    RUN0=$(cat "$G/run.pid")
    check "settings saved from the page: written, and the gateway starts again with them" 'api -X POST -H "X-Gateway-Settings: 1" -d "port=8443&user=jacob&password=n3w-pass" | grep -q "\"ok\":true" && wait_for "grep -q \"^https://127.0.0.1:8443\" $G/Caddyfile" && grep -q "jacob \$2a" "$G/Caddyfile"'
    check "the same script (exec), a new Caddy, the backend back, no banner" 'wait_for "! gone \$(cat $G/fake.pid) && [ \$(cat $G/fake.pid) != $C ]" && [ "$(cat "$G/run.pid")" = "$RUN0" ] && wait_for "[ -S $G/settings.sock ]" && ! grep -q "default password" "$G/www/index.html" && grep -q "settings changed on the settings page" "$G/log.txt"'
    check "the settings file keeps its other lines" 'grep -qx "nice=17" "$G/mpc_gateway_addin.conf" && grep -qx "password=n3w-pass" "$G/mpc_gateway_addin.conf"'
    C=$(cat "$G/fake.pid"); H=$(cat "$G/settings.pid")
    stop_mpc
    check "the settings backend stops too, its socket removed" 'wait_for "gone $H" && [ ! -e "$G/settings.sock" ]'
    check "caddy stopped after MPC exits" 'wait_for "gone $C" && [ -e "$G/fake.stopped" ]'
    check "script gone too, pid files removed" 'wait_for "gone $RUNNER" && [ ! -e "$G/run.pid" ] && [ ! -e "$G/caddy.pid" ]'
done
unset MPC_GATEWAY_ADDIN_SH

echo "--- manifests"
setup "rescan_s=2" "forward=mine:7000:16721 bad:x:1"
manifest a ADDIN_WEB_PORT=6720
manifest b ADDIN_WEB_PORT=6720
manifest c 'ADDIN_WEB_PORT=6720' 'ADDIN_WEB_PATH=/x/../y/'
manifest d 'ADDIN_WEB_PORT=99999'
manifest e 'ADDIN_WEB_PORT=6730' 'ADDIN_CONF=e.conf' 'ADDIN_WEB_PORT_SETTING=port'
printf 'port=nope\n' > "$T/addins/e/e.conf"
manifest f 'ADDIN_WEB_PORT=6740' 'ADDIN_WEB_PATH=nofix'
manifest g 'ADDIN_WEB_PORT=6750' 'ADDIN_CONF=../../etc/passwd' 'ADDIN_WEB_PORT_SETTING=port'
manifest h 'ADDIN_NAME="Braces {env.HOME} and \\slash"' 'ADDIN_WEB_PORT=6752'
manifest 'bad id' 'ADDIN_WEB_PORT=6751'
manifest gateway2 'ADDIN_NAME="no web service"'
mkdir -p "$G/routes.d"; printf 'INVALID\n' > "$G/routes.d/broken.caddy"; printf 'respond /ok ok\n' > "$G/routes.d/fine.caddy"
mpc; started
check "same port twice: the second moves up, past a forward's port" 'svc "\"id\":\"a\",[^}]*\"gateway_port\":16720" && svc "\"id\":\"b\",[^}]*\"gateway_port\":16722" && svc "\"id\":\"c\",[^}]*\"gateway_port\":16723"'
check "a path with .. refused: a port of its own" 'svc "\"id\":\"c\",[^}]*\"path\":\"\"" && grep -q "c: ADDIN_WEB_PATH=/x/../y/ refused" "$G/log.txt"'
check "not a port: left out" '! svc "\"id\":\"d\"" && grep -q "d: ADDIN_WEB_PORT=99999 is not a port, left out" "$G/log.txt"'
check "a bad port setting: the manifest port kept" 'svc "\"id\":\"e\",[^}]*\"port\":6730" && grep -q "e: port=nope in e.conf is not a port, using 6730" "$G/log.txt"'
check "a path without slashes ignored" 'svc "\"id\":\"f\",[^}]*\"path\":\"\"" && grep -q "f: ADDIN_WEB_PATH must start and end with /" "$G/log.txt"'
check "a settings file outside its folder never read" 'svc "\"id\":\"g\",[^}]*\"port\":6750" && grep -q "g: odd ADDIN_WEB_PORT_SETTING or ADDIN_CONF, ignored" "$G/log.txt"'
check "an odd folder name and an addin with no web service left out" '! grep -q "bad id" "$G/www/services.json" && ! svc gateway2'
check "braces and backslashes taken out of a name (no Caddy placeholders)" 'svc "\"id\":\"h\",\"name\":\"Braces env.HOME and slash\"" && grep -q "Braces env.HOME and slash isn.t running" "$G/Caddyfile"'
check "the gateway never lists itself" '! svc "\"id\":\"gateway\""'
check "your forward is routed and listed; a bad one skipped" 'grep -q "reverse_proxy 127.0.0.1:7000 {" "$G/Caddyfile" && svc "\"id\":\"mine\",[^}]*\"forward\":true" && grep -q "forward bad:x:1: not name:port:port" "$G/log.txt"'
check "your route kept, the refused one skipped" 'grep -q "import $G/routes.d/fine.caddy" "$G/Caddyfile" && ! grep -q broken.caddy "$G/Caddyfile" && grep -q "route $G/routes.d/broken.caddy: Caddy refuses it" "$G/log.txt"'
reloads() { if [ -f "$G/fake.reloads" ]; then wc -l < "$G/fake.reloads"; else echo 0; fi; }
R0=$(reloads)
sleep 5
check "nothing changed: no reload" '[ "$(reloads)" = "$R0" ]'
rm -rf "$T/addins/a"
check "an addin removed: dropped, Caddy reloaded" 'wait_for "! grep -q \"\\\"id\\\":\\\"a\\\"\" $G/www/services.json" && [ "$(reloads)" -gt "$R0" ]'
stop_mpc

echo "--- settings"
setup "bind=1.2.3.4; rm -rf /" "port=99999" "password=has space" "user=bad name!"
manifest mine ADDIN_WEB_PORT=6900 ADDIN_WEB_PATH=/settings/
mpc; started
check "bad bind and port fall back to the defaults" 'grep -q "default_bind 127.0.0.1" "$G/Caddyfile" && grep -q "https://127.0.0.1:443" "$G/Caddyfile" && grep -q "bind=1.2.3.4; rm -rf /: only" "$G/log.txt"'
check "a bad password and user name: mpc / mpc" 'grep -q "using the default, mpc" "$G/log.txt" && grep -q "user=bad name!: letters" "$G/log.txt" && grep -q "mpc \$2a" "$G/Caddyfile"'
check "an addin can't take /settings/: a port of its own" 'grep -q "mine: ADDIN_WEB_PATH=/settings/ is the gateway.s own" "$G/log.txt" && grep -q ":16900 {" "$G/Caddyfile"'
stop_mpc
setup "bind=0.0.0.0" "port=8443" "password=a-long-password"
mpc; started
check "bind=0.0.0.0: every address, the host name, no default_bind" '! grep -q default_bind "$G/Caddyfile" && grep -q "https://$(hostname):8443" "$G/Caddyfile" && grep -q "https://$(hostname).local:8443" "$G/Caddyfile"'
check "password= from the settings, no password.txt made" '[ ! -e "$G/password.txt" ] && [ "$(cat "$G/password.sum")" = "$(printf %s a-long-password | sha256sum | cut -d" " -f1)" ]'
stop_mpc

echo "--- refusals"
setup "enabled=0"; mpc; sleep 1
check "enabled=0 starts nothing" '[ ! -e "$G/fake.pid" ] && grep -q "disabled in" "$T/mpc.err"'
kill "$PID" 2>/dev/null || true
setup; mpc "MPC Sample"
check "the MPC Sample's process (MPC Sample) starts it" started
stop_mpc
setup; mpc other; sleep 1
check "a process not named MPC starts nothing" '[ ! -e "$G/fake.pid" ] && ! grep -q mpc-gateway-addin "$T/mpc.err"'
kill "$PID" 2>/dev/null || true
setup; rm "$G/gateway-run.sh"; mpc; sleep 1
check "no script: says so, MPC keeps running" 'grep -q "reinstall the addin" "$T/mpc.err" && ! gone "$PID"'
kill "$PID" 2>/dev/null || true

[ $fail = 0 ] && echo PASSED || { echo FAILED; cat "$T/mpc.err" "$G/log.txt" 2>/dev/null; exit 1; }
