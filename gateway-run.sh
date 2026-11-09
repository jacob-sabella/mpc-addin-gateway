#!/bin/sh
# Started by mpc_gateway_addin.so each time MPC starts, as its own process (ADDIN_DIR = this folder, MPC_PID = MPC).
# Writes Caddy's config from mpc_gateway_addin.conf and the routes other addins ship, runs ./caddy, starts it again if
# it exits (waiting longer each time it fails quickly), reloads it when the device's addresses change, and stops it
# once MPC has exited. Plain POSIX sh: it runs in the device's BusyBox.
set -u
D=${ADDIN_DIR:?}
MPC=${MPC_PID:?}
cd "$D" || exit 1
umask 077
CONF=mpc_gateway_addin.conf
PIDFILE=caddy.pid
USER_NAME=mpc

# The last value of a key in the settings file, without surrounding blanks or quotes ("" when it is missing).
conf() {
    v=$(sed -n "s/^[[:space:]]*$1[[:space:]]*=//p" "$CONF" 2>/dev/null | tail -n 1)
    v=$(printf '%s' "$v" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"\(.*\)"$/\1/')
    printf '%s' "$v"
}
say() { echo "$(date '+%Y-%m-%d %H:%M:%S') gateway-run: $*" >> "$LOG"; }

LOG=$(conf log)
case "$LOG" in /*) ;; *) LOG=/dev/null ;; esac

BIND=$(conf bind); PORT=$(conf port); MEMORY=$(conf memory_mb); ADDINS=$(conf addins_dir)
FORWARD=$(conf forward); USERCFG=$(conf config); RESCAN=$(conf rescan_s)
case "$BIND" in 127.0.0.1|0.0.0.0) ;; *) [ -z "$BIND" ] || say "bind=$BIND: only 127.0.0.1 or 0.0.0.0; using 127.0.0.1"; BIND=127.0.0.1 ;; esac
case "$PORT" in ''|*[!0-9]*) PORT=443 ;; esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || PORT=443
case "$MEMORY" in ''|*[!0-9]*) MEMORY=64 ;; esac
case "$RESCAN" in ''|*[!0-9]*) RESCAN=30 ;; esac
[ "$RESCAN" -ge 5 ] || RESCAN=5
case "$ADDINS" in /*) ;; *) ADDINS=${D%/*} ;; esac   # the folder that holds every addin's folder
grep -q '^[[:space:]]*forward[[:space:]]*=' "$CONF" 2>/dev/null ||
    FORWARD="remote:6720:16720 commander:6730:16730 filebrowser:6760:16760"

# The password: password= in the settings, or one made at the first start and kept in password.txt (root only).
# Caddy is given only its bcrypt hash, made again when the password changes (password.sum: its SHA-256).
PASSWORD=$(conf password)
case "$PASSWORD" in *[[:space:]]*|*\"*|*\\*)
    say "password: no spaces, quotes or backslashes; using password.txt instead"; PASSWORD="" ;;
esac
if [ -z "$PASSWORD" ]; then
    if [ ! -s password.txt ]; then
        pw=$(tr -dc 'abcdefghjkmnpqrstuvwxyz23456789' < /dev/urandom 2>/dev/null | head -c 20)
        [ ${#pw} -eq 20 ] || { say "can't make a password (no /dev/urandom?)"; exit 1; }
        printf '%s\n' "$pw" > password.txt.new && mv password.txt.new password.txt
        say "made a password, in $D/password.txt"
    fi
    PASSWORD=$(head -n 1 password.txt)
elif [ ${#PASSWORD} -lt 8 ]; then
    say "password: shorter than 8 characters, refused; using password.txt instead"
    PASSWORD=""; [ -s password.txt ] && PASSWORD=$(head -n 1 password.txt)
    [ -n "$PASSWORD" ] || { say "no usable password: set password= (8 or more characters)"; exit 1; }
fi

chmod 755 caddy 2>/dev/null   # the installer installs it 755; a copy through a FAT card may not have kept that
export GOMAXPROCS=1 GOMEMLIMIT="${MEMORY}MiB" HOME="$D" XDG_DATA_HOME="$D/xdg" XDG_CONFIG_HOME="$D/xdg"

SUM=$(printf '%s' "$PASSWORD" | sha256sum | cut -d' ' -f1)
if [ ! -s password.hash ] || [ "$(cat password.sum 2>/dev/null)" != "$SUM" ]; then
    # bcrypt cost 10: a wrong password costs Caddy one hash each time, so a cheaper hash keeps guessing from eating
    # the core MPC shares; a right one is cached after the first request.
    h=$(printf '%s' "$PASSWORD" | ./caddy hash-password --algorithm bcrypt --bcrypt-cost 10 2>> "$LOG")
    case "$h" in '$2'*) ;; *) say "caddy hash-password failed"; exit 1 ;; esac
    printf '%s\n' "$h" > password.hash.new && mv password.hash.new password.hash
    printf '%s\n' "$SUM" > password.sum.new && mv password.sum.new password.sum
    say "password hash made for user $USER_NAME"
fi
HASH=$(cat password.hash)

# The names the gateway answers to, each with its own certificate from Caddy's local authority: the device itself, and
# with bind=0.0.0.0 every IPv4 address it has now, its host name and <name>.local.
hosts() {
    echo 127.0.0.1; echo localhost
    [ "$BIND" = 0.0.0.0 ] || return 0
    { ip -4 -o addr show 2>/dev/null | sed -n 's/.* inet \([0-9.]*\)\/.*/\1/p'
      [ -n "$(command -v ip)" ] || ifconfig 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p; s/.*inet \([0-9.]*\) .*/\1/p'
    } | grep -v '^127\.' | sort -u
    n=$(hostname 2>/dev/null)
    case "$n" in ''|localhost|*[!A-Za-z0-9-]*) ;; *) echo "$n"; echo "$n.local" ;; esac
}
sites() {   # the site address list for a port: https://a:port, https://b:port
    s=""; for h in $HOSTS; do s="$s${s:+, }https://$h:$1"; done; printf '%s' "$s"
}

# Routes: each addin folder's gateway.caddy, and routes.d/*.caddy here (your own). A route is Caddyfile directives
# inside the gateway's site, behind its password, e.g. handle_path /files/* { reverse_proxy 127.0.0.1:6760 }.
# Optional first lines name it on the start page: "# name: File Browser" and "# path: /files/".
SKIP=" "
routes() {
    for f in "$ADDINS"/*/gateway.caddy "$D"/routes.d/*.caddy; do
        [ -f "$f" ] || continue
        case "$f" in *[!A-Za-z0-9/._-]*) say "route $f: odd characters in its path, skipped"; continue ;; esac
        case "$SKIP" in *" $f "*) continue ;; esac
        echo "$f"
    done
}
# Forwards: a port of the gateway in front of an addin's own port, for addins that can't live under a path. Each is
# name:addin_port:gateway_port, used only while /data/mpc-addins/<name> exists.
forwards() {
    seen=" $PORT "
    for fw in $FORWARD; do
        IFS=: read -r n a g <<EOF
$fw
EOF
        case "$n:$a:$g" in *[!a-z0-9:-]*|:*|*::*|*:) say "forward $fw: not name:port:port, skipped"; continue ;; esac
        case "$a$g" in *[!0-9]*) say "forward $fw: not name:port:port, skipped"; continue ;; esac
        [ "$a" -ge 1 ] && [ "$a" -le 65535 ] && [ "$g" -ge 1 ] && [ "$g" -le 65535 ] ||
            { say "forward $fw: bad port, skipped"; continue; }
        case "$seen" in *" $g "*) say "forward $fw: port $g is taken, skipped"; continue ;; esac
        [ -d "$ADDINS/$n" ] || continue
        seen="$seen$g "
        echo "$n $a $g"
    done
}

auth() {
    echo "	basic_auth {"
    echo "		$USER_NAME $HASH"
    echo "	}"
}
# Caddy's config: $1 = the file to write, $2 = the routes to put in it.
write_caddyfile() {
    {
        echo "# Written by gateway-run.sh each time MPC starts, from $CONF: edits here are lost."
        echo "# To run Caddy with a Caddyfile of your own, set config=/path/to/it there."
        echo "{"
        echo "	admin unix/$D/admin.sock"
        echo "	storage file_system $D/data"
        echo "	skip_install_trust"
        echo "	auto_https disable_redirects"
        echo "	persist_config off"
        [ "$BIND" = 127.0.0.1 ] && echo "	default_bind 127.0.0.1"
        echo "	servers {"
        echo "		protocols h1 h2"
        echo "	}"
        echo "	log {"
        echo "		level WARN"
        echo "	}"
        echo "}"
        echo ""
        echo "$(sites "$PORT") {"
        echo "	tls internal"
        auth
        for f in $2; do echo "	import $f"; done
        echo "	handle {"
        echo "		root * $D/www"
        echo "		file_server"
        echo "	}"
        echo "}"
        forwards | while read -r n a g; do
            echo ""
            echo "# $n"
            echo "$(sites "$g") {"
            echo "	tls internal"
            auth
            echo "	reverse_proxy 127.0.0.1:$a {"
            echo "		header_up Host 127.0.0.1:$a"
            echo "	}"
            echo "}"
        done
    } > "$1.new" && mv "$1.new" "$1"
}
valid() { ./caddy validate --config "$1" --adapter caddyfile > /dev/null 2>> "$LOG"; }

html() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }
# The start page: a link per route (by its "# path:") and per forward, and the certificate authority to trust.
write_page() {
    mkdir -p www
    {
        echo '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">'
        echo '<title>MPC Gateway</title>'
        echo '<style>body{font:16px system-ui,sans-serif;max-width:40rem;margin:2rem auto;padding:0 1rem;background:#111;color:#eee}'
        echo 'a{color:#ffcc33}li{margin:.4rem 0}small{color:#999}</style>'
        echo "<h1>$(html "$(hostname 2>/dev/null || echo MPC)")</h1><ul>"
        for f in $1; do
            n=$(sed -n '1,10s/^#[[:space:]]*name:[[:space:]]*//p' "$f" | head -n 1)
            p=$(sed -n '1,10s/^#[[:space:]]*path:[[:space:]]*//p' "$f" | head -n 1)
            [ -n "$n" ] || { n=${f%/gateway.caddy}; n=${n##*/}; n=${n%.caddy}; }
            case "$p" in /*) case "$p" in *[!A-Za-z0-9/._~-]*) p="" ;; esac ;; *) p="" ;; esac
            [ -n "$p" ] && echo "<li><a href=\"$p\">$(html "$n")</a> <small>$p</small></li>"
        done
        forwards | while read -r n a g; do
            echo "<li><a class=\"fw\" data-port=\"$g\" href=\"#\">$n</a> <small>port $g</small></li>"
        done
        echo '</ul><p><small>To stop the certificate warning, install <a href="/root.crt">this device'"'"'s certificate'
        echo 'authority</a> on your computer and trust it for websites.</small></p>'
        echo '<script>for(const a of document.querySelectorAll("a.fw"))a.href="https://"+location.hostname+":"+a.dataset.port+"/"</script>'
    } > www/index.html.new && mv www/index.html.new www/index.html
    [ -s data/pki/authorities/local/root.crt ] && cp -f data/pki/authorities/local/root.crt www/root.crt 2>/dev/null
    return 0
}

# Writes Caddyfile from the settings, the routes and the addresses now. A route Caddy refuses is left out (and logged),
# so one broken route never stops the others.
configure() {
    HOSTS=$(hosts)
    R=$(routes)
    write_caddyfile Caddyfile "$R"
    if ! valid Caddyfile; then
        for f in $R; do
            write_caddyfile Caddyfile.test "$f"
            valid Caddyfile.test || { say "route $f: Caddy refuses it, skipped"; SKIP="$SKIP$f "; }
        done
        rm -f Caddyfile.test
        R=$(routes)
        write_caddyfile Caddyfile "$R"
        valid Caddyfile || { say "Caddy refuses the config even without the routes"; return 1; }
    fi
    write_page "$R"
}

if [ -n "$USERCFG" ]; then
    CFG=$USERCFG
    [ -r "$CFG" ] || { say "config=$CFG can't be read"; exit 1; }
    HOSTS=""
else
    CFG=$D/Caddyfile
    configure || exit 1
fi

alive() { [ -r "/proc/$1/stat" ] && ! sed 's/.*) //' "/proc/$1/stat" | grep -q '^Z'; }

# A gateway left by an earlier MPC (still stopping, or started by a launcher that doesn't stop it): stop its script
# first (it stops its Caddy and would otherwise start it again while that MPC lingers), then any Caddy still left.
stop_old() {   # pid file, what the command line must hold
    [ -s "$1" ] || return 0
    old=$(cat "$1")
    case "$old" in ''|*[!0-9]*) return 0 ;; esac
    [ "$old" != $$ ] || return 0
    # ours: run from this folder (by cwd and command line; exe can name an emulator in tests)
    if alive "$old" && [ "$(readlink "/proc/$old/cwd" 2>/dev/null)" = "$D" ] &&
        tr '\0' ' ' < "/proc/$old/cmdline" 2>/dev/null | grep -q "$2"; then
        say "stopping the gateway of an earlier MPC run ($old)"
        kill "$old" 2>/dev/null
        i=0; while alive "$old" && [ $i -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
        alive "$old" && kill -9 "$old" 2>/dev/null
    fi
    return 0
}
stop_old run.pid 'gateway-run\.sh'
stop_old "$PIDFILE" '\./caddy run '
echo $$ > run.pid

CADDY=""
start() {
    ./caddy run --config "$CFG" --adapter caddyfile < /dev/null >> "$LOG" 2>&1 &
    CADDY=$!
    echo "$CADDY" > "$PIDFILE"
    STARTED=$(date +%s)
    say "started Caddy $CADDY on $BIND:$PORT for: $(echo $HOSTS)"
}
stop() {
    trap - TERM INT HUP
    if [ -n "$CADDY" ] && alive "$CADDY"; then
        kill "$CADDY" 2>/dev/null
        i=0; while alive "$CADDY" && [ $i -lt 25 ]; do sleep 0.2; i=$((i + 1)); done
        alive "$CADDY" && kill -9 "$CADDY" 2>/dev/null
        wait "$CADDY" 2>/dev/null
    fi
    rm -f "$PIDFILE"
    [ "$(cat run.pid 2>/dev/null)" = $$ ] && rm -f run.pid
    say "stopped"
    exit 0
}
trap stop TERM INT HUP

say "MPC $MPC started"
DELAY=5
start
LAST=$(date +%s)
while kill -0 "$MPC" 2>/dev/null; do
    if ! alive "$CADDY"; then
        wait "$CADDY" 2>/dev/null; rc=$?
        ran=$(( $(date +%s) - STARTED ))
        [ $ran -ge 60 ] && DELAY=5
        say "Caddy exited ($rc) after ${ran}s; starting it again in ${DELAY}s"
        sleep "$DELAY"
        DELAY=$((DELAY * 2)); [ $DELAY -le 300 ] || DELAY=300
        kill -0 "$MPC" 2>/dev/null || break
        start
    fi
    now=$(date +%s)
    if [ -z "$USERCFG" ] && [ $((now - LAST)) -ge "$RESCAN" ]; then
        LAST=$now
        # the certificate authority appears after Caddy's first start
        [ -s www/root.crt ] || { [ -s data/pki/authorities/local/root.crt ] && cp -f data/pki/authorities/local/root.crt www/root.crt; }
        new=$(hosts)
        if [ "$new" != "$HOSTS" ]; then
            say "addresses changed: $(echo $new)"
            if configure && ./caddy reload --config "$CFG" --adapter caddyfile --address "unix/$D/admin.sock" >> "$LOG" 2>&1; then
                say "Caddy reloaded"
            else
                say "reload failed: starting Caddy again"
                kill "$CADDY" 2>/dev/null
            fi
        fi
    fi
    sleep 2
done
say "MPC $MPC has exited"
stop
