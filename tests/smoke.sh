#!/usr/bin/env bash
# The real Caddy binary from a build (./build.sh [aarch64] first) run by gateway-run.sh in BusyBox, under QEMU for the
# device's CPU: a password is made at the first start (root only), every page needs it, an addin's route and a forward
# reach their stand-in servers (with the Host they expect), a route Caddy refuses is left out and the others still
# work, a forward is only used while its addin is installed, the device-only default listens on 127.0.0.1 only, the
# certificate authority appears on the start page, a second start replaces the first, a changed password works after
# the next start, bind=0.0.0.0 answers on the container's own address, and Caddy stops once "MPC" (a sleep standing in
# for it) exits. Needs Docker with QEMU for the target.
# Usage: tests/smoke.sh [armv7|aarch64]
set -euo pipefail
cd "$(dirname "$0")/.."
ARCH=${1:-armv7}
case "$ARCH" in
    armv7) PKG=build PLATFORM=linux/arm/v7 IMAGE=arm32v7/alpine:3.20 ;;
    aarch64) PKG=build/aarch64 PLATFORM=linux/arm64 IMAGE=arm64v8/alpine:3.20 ;;
    *) echo "usage: $0 [armv7|aarch64]" >&2; exit 2 ;;
esac
[ -x "$PKG/mpc_gateway_addin.so" ] && [ -f "$PKG/caddy" ] || { echo "no build in $PKG: run ./build.sh $ARCH" >&2; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T" 2>/dev/null || docker run --rm -v "$T:/t" alpine rm -rf /t/addin /t/addins' EXIT
mkdir -p "$T/addins/gateway" "$T/addins/filebrowser" "$T/addins/broken" "$T/addins/remote"
find "$PKG" -maxdepth 1 -type f -exec cp {} "$T/addins/gateway/" \;
chmod 644 "$T/addins/gateway/caddy"   # as a copy through a FAT card leaves it
sed -i 's#^log=.*#log=/addins/gateway/log.txt#; s#^rescan_s=.*#rescan_s=5#' "$T/addins/gateway/mpc_gateway_addin.conf"
printf '# name: File Browser\n# path: /files/\nhandle_path /files/* {\n\treverse_proxy 127.0.0.1:6760\n}\n' > "$T/addins/filebrowser/gateway.caddy"
printf 'handle_path /broken/* {\n\tnot_a_directive\n}\n' > "$T/addins/broken/gateway.caddy"
docker run --rm --platform "$PLATFORM" -v "$T/addins:/addins" "$IMAGE" sh -c '
G=/addins/gateway
fail=0; check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
get() { wget -q -T 10 --no-check-certificate -O /tmp/out "$@" 2>/tmp/err; }   # url; body in /tmp/out
up() { i=0; while [ $i -lt 120 ]; do get "https://127.0.0.1:${1:-443}/" 2>/dev/null; grep -q 401 /tmp/err && return 0; sleep 1; i=$((i + 1)); done; return 1; }
gone() { [ ! -d /proc/$1 ] || grep -q "^State:.*Z" /proc/$1/status; }
listening() { grep -qi ":$(printf %04X $1) 00000000:0000 0A" /proc/net/tcp; }   # anything on that port
# stand-ins for the addins: File Browser, and Remote answering with the Host it was sent
printf "{\n\tadmin off\n\tauto_https off\n\tpersist_config off\n}\nhttp://127.0.0.1:6760 {\n\trespond files-backend\n}\nhttp://127.0.0.1:6720 {\n\trespond \"host={hostport}\"\n}\n" > /tmp/backends.caddy
cp $G/caddy /tmp/backend-caddy; chmod 755 /tmp/backend-caddy
HOME=/tmp /tmp/backend-caddy run --config /tmp/backends.caddy --adapter caddyfile > /tmp/backends.log 2>&1 &
sleep 1000 & MPC1=$!
ADDIN_DIR=$G MPC_PID=$MPC1 sh $G/gateway-run.sh &
check "answers on 443, and only with the password" up
PW=$(cat $G/password.txt 2>/dev/null)
check "a password made at the first start, root only" "[ \${#PW} -eq 20 ] && [ \"\$(stat -c %a $G/password.txt)\" = 600 ]"
check "the start page with the password" "get https://mpc:\$PW@127.0.0.1/ && grep -q \"File Browser\" /tmp/out && grep -q \"data-port=\\\"16720\\\"\" /tmp/out"
check "a wrong password is refused" "! get https://mpc:wrong-password@127.0.0.1/ && grep -q 401 /tmp/err"
check "the route reaches its server" "get https://mpc:\$PW@127.0.0.1/files/ && grep -qx files-backend /tmp/out"
check "the route needs the password too" "! get https://127.0.0.1/files/ && grep -q 401 /tmp/err"
check "a route Caddy refuses is left out, logged" "grep -q \"route /addins/broken/gateway.caddy: Caddy refuses it\" $G/log.txt && ! grep -q broken $G/Caddyfile"
check "a forward to an installed addin, Host as through a tunnel" "up 16720 && get https://mpc:\$PW@127.0.0.1:16720/ && grep -qx host=127.0.0.1:6720 /tmp/out"
check "the forward needs the password" "! get https://127.0.0.1:16720/ && grep -q 401 /tmp/err"
check "no forward for an addin that is not installed" "! listening 16730"
check "device only by default (127.0.0.1)" "grep -qi \"0100007F:01BB 00000000:0000 0A\" /proc/net/tcp && ! grep -qi \"00000000:01BB 00000000:0000 0A\" /proc/net/tcp"
sleep 7
check "the certificate authority on the start page" "get https://mpc:\$PW@127.0.0.1/root.crt && grep -q \"BEGIN CERTIFICATE\" /tmp/out"
FIRST=$(cat $G/caddy.pid)
echo "     Caddy memory: $(grep VmRSS /proc/$FIRST/status)"
sed -i "s/^password=.*/password=changed-in-conf/" $G/mpc_gateway_addin.conf
sleep 1000 & MPC2=$!          # MPC restarted after the setting changed, while the first run is still up
ADDIN_DIR=$G MPC_PID=$MPC2 sh $G/gateway-run.sh &
sleep 2
check "second start stops the first Caddy" "i=0; while ! gone $FIRST && [ \$i -lt 20 ]; do sleep 1; i=\$((i+1)); done; gone $FIRST"
check "a changed password works after the next start" "up && get https://mpc:changed-in-conf@127.0.0.1/ && ! get https://mpc:\$PW@127.0.0.1/"
SECOND=$(cat $G/caddy.pid)
kill $MPC1 $MPC2
check "stops when MPC exits" "i=0; while ! gone $SECOND && [ \$i -lt 20 ]; do sleep 1; i=\$((i+1)); done; gone $SECOND"
check "pid file removed" "i=0; while [ -e $G/caddy.pid ] && [ \$i -lt 10 ]; do sleep 1; i=\$((i+1)); done; [ ! -e $G/caddy.pid ]"
sed -i "s/^bind=.*/bind=0.0.0.0/" $G/mpc_gateway_addin.conf
IP=$(ip -4 -o addr show | sed -n "s/.* inet \([0-9.]*\)\/.*/\1/p" | grep -v "^127\." | head -n 1)
sleep 1000 & MPC3=$!
ADDIN_DIR=$G MPC_PID=$MPC3 sh $G/gateway-run.sh &
check "bind=0.0.0.0: answers on the device address $IP" "i=0; while ! get https://mpc:changed-in-conf@\$IP/ && [ \$i -lt 120 ]; do sleep 1; i=\$((i+1)); done; grep -q \"File Browser\" /tmp/out"
check "bind=0.0.0.0: a certificate for that address" "grep -q \"https://\$IP:443\" $G/Caddyfile"
kill $MPC3; sleep 4
chmod -R a+rwX /addins 2>/dev/null; [ $fail = 0 ] || { echo "--- backends"; tail -n 5 /tmp/backends.log; echo "--- log"; tail -n 40 $G/log.txt; exit 1; }
'
echo "PASSED ($ARCH)"
