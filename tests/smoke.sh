#!/usr/bin/env bash
# The real Caddy binary from a build (./build.sh [aarch64] first) run by gateway-run.sh in BusyBox, under QEMU for the
# device's CPU, with stand-in addins that declare web services in their addin.manifest:
# - a password is made at the first start (root only) and every page and route needs it; a wrong one is refused
# - a service with ADDIN_WEB_PATH is routed under that path (and its port taken from its settings file through
#   ADDIN_WEB_PORT_SETTING); one without gets a port of its own (+10000), with the Host it would see through a tunnel
# - the start page's services.json lists them, up or down from the kernel's socket table; a service that starts later
#   turns up, and an addin removed while the gateway runs disappears and its port closes
# - a manifest holding shell code is never run, and a name holding markup is cleaned
# - your own routes.d route works, and one Caddy refuses is skipped
# - the device-only default listens on 127.0.0.1 only; bind=0.0.0.0 answers on the container's address
# - the certificate authority is offered; a second start replaces the first; a changed password works after the next
#   start; Caddy stops once "MPC" (a sleep standing in for it) exits
# Needs Docker with QEMU for the target. Usage: tests/smoke.sh [armv7|aarch64]
set -euo pipefail
cd "$(dirname "$0")/.."
ARCH=${1:-armv7}
case "$ARCH" in
    armv7) PKG=build PLATFORM=linux/arm/v7 IMAGE=arm32v7/alpine:3.20 ;;
    aarch64) PKG=build/aarch64 PLATFORM=linux/arm64 IMAGE=arm64v8/alpine:3.20 ;;
    *) echo "usage: $0 [armv7|aarch64]" >&2; exit 2 ;;
esac
[ -x "$PKG/mpc_gateway_addin.so" ] && [ -f "$PKG/caddy" ] || { echo "no build in $PKG: run ./build.sh $ARCH" >&2; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T" 2>/dev/null || true' EXIT
A=$T/addins
mkdir -p "$A/gateway/routes.d" "$A/filebrowser" "$A/remote" "$A/commander" "$A/evil" "$A/quiet"
find "$PKG" -maxdepth 1 -type f -exec cp {} "$A/gateway/" \;
chmod 644 "$A/gateway/caddy"   # as a copy through a FAT card leaves it
sed -i 's#^log=.*#log=/addins/gateway/log.txt#; s#^rescan_s=.*#rescan_s=2#' "$A/gateway/mpc_gateway_addin.conf"
printf 'ADDIN_ID=filebrowser\nADDIN_NAME="MPC File Browser"\nADDIN_CONF=mpc_filebrowser_addin.conf\nADDIN_WEB_PORT=6760\nADDIN_WEB_PORT_SETTING=port\nADDIN_WEB_PATH=/files/\n' > "$A/filebrowser/addin.manifest"
printf 'bind=127.0.0.1\nport=6761\n' > "$A/filebrowser/mpc_filebrowser_addin.conf"
printf 'ADDIN_ID=remote\nADDIN_NAME="MPC Remote <b>"\nADDIN_WEB_PORT=6720\n' > "$A/remote/addin.manifest"
printf 'ADDIN_ID=commander\nADDIN_NAME="MPC Commander"\nADDIN_WEB_PORT=6730\n' > "$A/commander/addin.manifest"
printf 'ADDIN_ID=evil\nADDIN_NAME=$(touch /tmp/pwned)\nADDIN_WEB_PORT=$(touch /tmp/pwned)\n' > "$A/evil/addin.manifest"
printf 'ADDIN_ID=quiet\nADDIN_NAME="No web"\n' > "$A/quiet/addin.manifest"
printf 'handle_path /mine/* {\n\trespond mine\n}\n' > "$A/gateway/routes.d/mine.caddy"
printf 'handle_path /broken/* {\n\tnot_a_directive\n}\n' > "$A/gateway/routes.d/broken.caddy"
docker run --rm --platform "$PLATFORM" -v "$A:/addins" "$IMAGE" sh -c '
G=/addins/gateway
fail=0; check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
get() { wget -q -T 10 --no-check-certificate -O /tmp/out "$@" 2>/tmp/err; }   # url; body in /tmp/out
up() { i=0; while [ $i -lt 120 ]; do get "https://127.0.0.1:${1:-443}/" 2>/dev/null; grep -q 401 /tmp/err && return 0; sleep 1; i=$((i + 1)); done; return 1; }
gone() { [ ! -d /proc/$1 ] || grep -q "^State:.*Z" /proc/$1/status; }
listening() { grep -qi ":$(printf %04X $1) 00000000:0000 0A" /proc/net/tcp; }   # anything on that port
waitfor() { i=0; while [ $i -lt 30 ]; do eval "$1" && return 0; sleep 1; i=$((i + 1)); done; return 1; }
svc() { get https://mpc:$PW@127.0.0.1/services.json && cat /tmp/out; }
# stand-ins for the addins: File Browser (on the port its settings give) and Remote, which answers with the Host it got
backend() {   # port body
    printf "{\n\tadmin off\n\tauto_https off\n\tpersist_config off\n}\nhttp://127.0.0.1:%s {\n\trespond \"%s\"\n}\n" "$1" "$2" > /tmp/b$1.caddy
    HOME=/tmp /tmp/backend-caddy run --config /tmp/b$1.caddy --adapter caddyfile > /tmp/b$1.log 2>&1 &
}
cp $G/caddy /tmp/backend-caddy; chmod 755 /tmp/backend-caddy
backend 6761 files-backend; backend 6720 "host={hostport} user={http.request.header.X-MPC-Gateway-User}"
sleep 1000 & MPC1=$!
ADDIN_DIR=$G MPC_PID=$MPC1 sh $G/gateway-run.sh &
check "answers on 443, and only with the password" up
PW=mpc
check "the default login, mpc / mpc, and the page says to change it" "[ ! -e $G/password.txt ] && get https://mpc:mpc@127.0.0.1/ && grep -q \"still has the default password\" /tmp/out"
check "a wrong password is refused" "! get https://mpc:wrong-password@127.0.0.1/ && grep -q 401 /tmp/err"
check "the start page with the password, the services listed in the page itself" "get https://mpc:\$PW@127.0.0.1/ && grep -q services.json /tmp/out && grep -q \">MPC File Browser</a>\" /tmp/out && grep -q \"data-port=.16720.\" /tmp/out"
check "services.json needs the password" "! get https://127.0.0.1/services.json && grep -q 401 /tmp/err"
check "the declared services are listed, sorted, the one with no web service left out" "svc | grep -o \"\\\"id\\\":\\\"[a-z]*\\\"\" | tr -d \"\\n\" | grep -qx \"\\\"id\\\":\\\"commander\\\"\\\"id\\\":\\\"filebrowser\\\"\\\"id\\\":\\\"remote\\\"\""
check "a path service: up, at its path, port from its settings" "svc | grep -q \"\\\"id\\\":\\\"filebrowser\\\",\\\"name\\\":\\\"MPC File Browser\\\",\\\"port\\\":6761,\\\"path\\\":\\\"/files/\\\",\\\"gateway_port\\\":0,\\\"up\\\":true\""
check "the path route reaches it, with the password only" "get https://mpc:\$PW@127.0.0.1/files/ && grep -qx files-backend /tmp/out && ! get https://127.0.0.1/files/"
check "the path without its slash is sent to it" "get https://mpc:\$PW@127.0.0.1/files && grep -qx files-backend /tmp/out"
check "a port service: up, on its port + 10000, markup taken out of its name" "svc | grep -q \"\\\"id\\\":\\\"remote\\\",\\\"name\\\":\\\"MPC Remote b\\\",\\\"port\\\":6720,\\\"path\\\":\\\"\\\",\\\"gateway_port\\\":16720,\\\"up\\\":true\""
check "its port reaches it, Host as through a tunnel, password only" "up 16720 && get https://mpc:\$PW@127.0.0.1:16720/ && grep -q \"^host=127.0.0.1:6720 \" /tmp/out"
check "the logged-in user passed on in X-MPC-Gateway-User, one a client sends replaced" "get --header \"X-MPC-Gateway-User: admin\" https://mpc:\$PW@127.0.0.1:16720/ && grep -qx \"host=127.0.0.1:6720 user=mpc\" /tmp/out"
check "a service not running is listed as down" "svc | grep -q \"\\\"id\\\":\\\"commander\\\",.*\\\"gateway_port\\\":16730,\\\"up\\\":false\""
check "its port says so when asked (502 with a message)" "! get https://mpc:\$PW@127.0.0.1:16730/ && grep -q 502 /tmp/err && grep -q \"MPC Commander isn.t running on this device right now\" $G/Caddyfile"
check "a manifest holding shell code is never run" "[ ! -e /tmp/pwned ] && grep -q \"evil: ADDIN_WEB_PORT=.* is not a port, left out\" $G/log.txt"
check "your own route works" "get https://mpc:\$PW@127.0.0.1/mine/ && grep -qx mine /tmp/out"
check "your route Caddy refuses is skipped, logged" "grep -q \"route $G/routes.d/broken.caddy: Caddy refuses it\" $G/log.txt && ! grep -q broken.caddy $G/Caddyfile"
check "device only by default (127.0.0.1)" "grep -qi \"0100007F:01BB 00000000:0000 0A\" /proc/net/tcp && ! grep -qi \"00000000:01BB 00000000:0000 0A\" /proc/net/tcp"
check "the certificate authority is offered" "waitfor \"get https://mpc:\$PW@127.0.0.1/root.crt\" && grep -q \"BEGIN CERTIFICATE\" /tmp/out"
backend 6730 commander-backend
check "a service that starts later turns up, without a reload" "waitfor \"svc | grep -q \\\"commander.*up.:true\\\"\" && ! grep -q \"Caddy reloaded\" $G/log.txt"
rm -rf /addins/remote
check "an addin removed while it runs disappears, its port closes" "waitfor \"! svc | grep -q remote\" && waitfor \"! listening 16720\" && grep -q \"Caddy reloaded\" $G/log.txt"
check "the other routes survive the reload" "get https://mpc:\$PW@127.0.0.1/files/ && grep -qx files-backend /tmp/out"
check "the settings page, behind the password" "get https://mpc:\$PW@127.0.0.1/settings/ && grep -q name=.bind. /tmp/out && ! get https://127.0.0.1/settings/ && grep -q 401 /tmp/err"
check "the settings, through Caddy to its backend, behind the password" "get https://mpc:\$PW@127.0.0.1/settings/api && grep -q .rescan_s.:.2. /tmp/out && ! grep -q ,.password.: /tmp/out && ! get https://127.0.0.1/settings/api"
check "a POST without the settings header is refused (403)" "! get --post-data port=8443 https://mpc:\$PW@127.0.0.1/settings/api && grep -q 403 /tmp/err"
check "a password saved on the settings page: the gateway starts again, the new one works, the old one not" "get --header \"X-Gateway-Settings: 1\" --post-data password=saved-pass https://mpc:\$PW@127.0.0.1/settings/api && grep -q .ok.:true /tmp/out && waitfor \"get https://mpc:saved-pass@127.0.0.1/\" && ! get https://mpc:mpc@127.0.0.1/ && ! grep -q \"default password\" /tmp/out"
PW=saved-pass
check "the routes are back after it" "get https://mpc:\$PW@127.0.0.1/files/ && grep -qx files-backend /tmp/out"
FIRST=$(cat $G/caddy.pid)
echo "     Caddy memory under QEMU: $(grep VmRSS /proc/$FIRST/status)"
sed -i "s/^password=.*/password=changed-in-conf/" $G/mpc_gateway_addin.conf
sleep 1000 & MPC2=$!          # MPC restarted after the setting changed, while the first run is still up
ADDIN_DIR=$G MPC_PID=$MPC2 sh $G/gateway-run.sh &
sleep 2
check "second start stops the first Caddy" "waitfor \"gone $FIRST\""
check "a changed password works after the next start" "up && get https://mpc:changed-in-conf@127.0.0.1/ && ! get https://mpc:\$PW@127.0.0.1/"
SECOND=$(cat $G/caddy.pid)
kill $MPC1 $MPC2
check "stops when MPC exits" "waitfor \"gone $SECOND\""
check "pid files removed" "waitfor \"[ ! -e $G/caddy.pid ] && [ ! -e $G/run.pid ]\""
sed -i "s/^bind=.*/bind=0.0.0.0/" $G/mpc_gateway_addin.conf
IP=$(ip -4 -o addr show | sed -n "s/.* inet \([0-9.]*\)\/.*/\1/p" | grep -v "^127\." | head -n 1)
sleep 1000 & MPC3=$!
ADDIN_DIR=$G MPC_PID=$MPC3 sh $G/gateway-run.sh &
check "bind=0.0.0.0: answers on the device address $IP" "waitfor \"get https://mpc:changed-in-conf@\$IP/files/\" && grep -qx files-backend /tmp/out"
check "bind=0.0.0.0: a certificate for that address" "grep -q \"https://\$IP:443\" $G/Caddyfile"
kill $MPC3; sleep 4
chmod -R a+rwX /addins 2>/dev/null
[ $fail = 0 ] || { echo "--- services.json"; cat $G/www/services.json; echo "--- log"; tail -n 40 $G/log.txt; exit 1; }
'
echo "PASSED ($ARCH)"
