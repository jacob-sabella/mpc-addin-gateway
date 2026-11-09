#!/bin/sh
# Started by mpc_gateway_addin.so each time MPC starts, as its own process (ADDIN_DIR = this folder, MPC_PID = MPC).
# Writes Caddy's config from mpc_gateway_addin.conf and the web services other addins declare in their addin.manifest,
# runs ./caddy, starts it again if it exits (waiting longer each time it fails quickly), keeps the start page's list
# current, reloads Caddy when the services or the device's addresses change, and stops it once MPC has exited.
# Plain POSIX sh: it runs in the device's BusyBox.
set -u
D=${ADDIN_DIR:?}
MPC=${MPC_PID:?}
cd "$D" || exit 1
umask 077
CONF=mpc_gateway_addin.conf
PIDFILE=caddy.pid
USER_NAME=mpc
TAB=$(printf '\t')

# The last value of a key in a key=value file, without surrounding blanks or quotes ("" when it is missing).
kv() {   # file, key
    v=$(sed -n "s/^[[:space:]]*$2[[:space:]]*=//p" "$1" 2>/dev/null | tail -n 1)
    v=$(printf '%s' "$v" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"\(.*\)"$/\1/')
    printf '%s' "$v"
}
conf() { kv "$CONF" "$1"; }
say() { echo "$(date '+%Y-%m-%d %H:%M:%S') gateway-run: $*" >> "$LOG"; }
isport() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

LOG=$(conf log)
case "$LOG" in /*) ;; *) LOG=/dev/null ;; esac

BIND=$(conf bind); PORT=$(conf port); MEMORY=$(conf memory_mb); ADDINS=$(conf addins_dir)
FORWARD=$(conf forward); USERCFG=$(conf config); RESCAN=$(conf rescan_s)
case "$BIND" in 127.0.0.1|0.0.0.0) ;; *) [ -z "$BIND" ] || say "bind=$BIND: only 127.0.0.1 or 0.0.0.0; using 127.0.0.1"; BIND=127.0.0.1 ;; esac
isport "$PORT" || PORT=443
case "$MEMORY" in ''|*[!0-9]*) MEMORY=64 ;; esac
case "$RESCAN" in ''|*[!0-9]*) RESCAN=10 ;; esac
[ "$RESCAN" -ge 2 ] || RESCAN=2
case "$ADDINS" in /*) ;; *) ADDINS=${D%/*} ;; esac   # the folder that holds every addin's folder
ME=${D##*/}

# The password: password= in the settings, or one made at the first start and kept in password.txt (root only).
# Caddy is given only its bcrypt hash, made again when the password changes (password.sum: its SHA-256).
PASSWORD=$(conf password)
case "$PASSWORD" in *[[:space:]]*|*\"*|*\\*)
    say "password: no spaces, quotes or backslashes; using password.txt instead"; PASSWORD="" ;;
esac
if [ -n "$PASSWORD" ] && [ ${#PASSWORD} -lt 8 ]; then
    say "password: shorter than 8 characters, refused; using password.txt instead"; PASSWORD=""
fi
if [ -z "$PASSWORD" ]; then
    if [ ! -s password.txt ]; then
        pw=$(tr -dc 'abcdefghjkmnpqrstuvwxyz23456789' < /dev/urandom 2>/dev/null | head -c 20)
        [ ${#pw} -eq 20 ] || { say "can't make a password (no /dev/urandom?)"; exit 1; }
        printf '%s\n' "$pw" > password.txt.new && mv password.txt.new password.txt
        say "made a password, in $D/password.txt"
    fi
    PASSWORD=$(head -n 1 password.txt)
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

# The web services other addins declare in their addin.manifest (docs/ADDINS.md in mpc-vst-plugins):
#   ADDIN_WEB_PORT=6760          its web server, on 127.0.0.1
#   ADDIN_WEB_PORT_SETTING=port  optional: the key in its settings file (ADDIN_CONF) that overrides the port
#   ADDIN_WEB_PATH=/files/       optional: it works under this path of the gateway; without it, the gateway gives it a
#                                port of its own, ADDIN_WEB_PORT + 10000 (or the next free one above)
# Only these keys, ADDIN_NAME and ADDIN_CONF are read, with sed: another addin's manifest is never run. One line per
# service, tab separated: id, name, port, path ("-" for none), gateway port ("-" for a path). Sorted by id.
services() {
    taken=" $PORT "
    for fw in $FORWARD; do taken="$taken${fw##*:} "; done
    for m in "$ADDINS"/*/addin.manifest; do
        [ -f "$m" ] || continue
        dir=${m%/addin.manifest}; id=${dir##*/}
        [ "$id" != "$ME" ] || continue
        case "$id" in *[!A-Za-z0-9_-]*) continue ;; esac
        p=$(kv "$m" ADDIN_WEB_PORT)
        [ -n "$p" ] || continue
        isport "$p" || { say "$id: ADDIN_WEB_PORT=$p is not a port, left out"; continue; }
        s=$(kv "$m" ADDIN_WEB_PORT_SETTING); c=$(kv "$m" ADDIN_CONF)
        if [ -n "$s" ]; then
            case "$s$c" in *[!A-Za-z0-9._-]*|.*) say "$id: odd ADDIN_WEB_PORT_SETTING or ADDIN_CONF, ignored" ;; *)
                q=$(kv "$dir/$c" "$s")
                if [ -n "$q" ]; then isport "$q" && p=$q || say "$id: $s=$q in $c is not a port, using $p"; fi ;;
            esac
        fi
        path=$(kv "$m" ADDIN_WEB_PATH)
        case "$path" in
            '') path=- ;;
            /*/) case "$path" in *//*|*[!A-Za-z0-9/._~-]*|*/./*|*/../*) say "$id: ADDIN_WEB_PATH=$path refused"; path=- ;; esac ;;
            *) say "$id: ADDIN_WEB_PATH must start and end with /, ignored"; path=- ;;
        esac
        name=$(kv "$m" ADDIN_NAME | tr -d '\t<>&"')
        [ -n "$name" ] || name=$id
        echo "$id$TAB$name$TAB$p$TAB$path"
    done | sort | while IFS="$TAB" read -r id name p path; do
        g=-
        if [ "$path" = - ]; then
            g=$((p + 10000))
            while [ $g -le 65535 ] && case "$taken" in *" $g "*) true ;; *) false ;; esac; do g=$((g + 1)); done
            [ $g -le 65535 ] || { say "$id: no free gateway port above $p, left out"; continue; }
            taken="$taken$g "
        fi
        echo "$id$TAB$name$TAB$p$TAB$path$TAB$g"
    done
}
# Your own ports in front of local servers, from forward= (name:local_port:gateway_port ...).
forwards() {
    seen=" $PORT "
    for fw in $FORWARD; do
        IFS=: read -r n a g <<EOF
$fw
EOF
        case "$n" in ''|*[!a-z0-9-]*) say "forward $fw: not name:port:port, skipped"; continue ;; esac
        isport "$a" && isport "$g" || { say "forward $fw: not name:port:port, skipped"; continue; }
        case "$seen" in *" $g "*) say "forward $fw: port $g is taken, skipped"; continue ;; esac
        seen="$seen$g "
        echo "$n $a $g"
    done
}
# Your own routes: routes.d/*.caddy here, Caddyfile directives inside the gateway's site, behind its password.
SKIP=" "
routes() {
    for f in "$D"/routes.d/*.caddy; do
        [ -f "$f" ] || continue
        case "$f" in *[!A-Za-z0-9/._-]*) say "route $f: odd characters in its path, skipped"; continue ;; esac
        case "$SKIP" in *" $f "*) continue ;; esac
        echo "$f"
    done
}

# Whether something listens on 127.0.0.1 or every address at a port: the kernel's socket tables, nothing sent to it.
listening() {   # port
    hx=$(printf '%04X' "$1")
    awk -v p=":$hx" '$4 == "0A" && substr($2, length($2) - 4) == p {
            a = substr($2, 1, length($2) - 5)
            if (a == "0100007F" || a == "00000000" || a == "00000000000000000000000000000000" ||
                a == "00000000000000000000000001000000" || a == "0000000000000000FFFF00000100007F") { f = 1; exit }
        } END { exit !f }' /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

auth() {
    echo "	basic_auth {"
    echo "		$USER_NAME $HASH"
    echo "	}"
}
proxy() {   # indent, port
    echo "$1reverse_proxy 127.0.0.1:$2 {"
    echo "$1	header_up Host 127.0.0.1:$2"
    echo "$1}"
}
# Caddy's config: $1 = the file to write, $2 = your routes to put in it.
write_caddyfile() {
    {
        echo "# Written by gateway-run.sh from $CONF and the addins' manifests: edits here are lost."
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
        printf '%s\n' "$SERVICES" | while IFS="$TAB" read -r id name p path g; do
            [ -n "$id" ] && [ "$path" != - ] || continue
            echo "	# $id"
            echo "	redir ${path%/} $path"
            echo "	handle $path* {"
            proxy "		" "$p"
            echo "	}"
        done
        for f in $2; do echo "	import $f"; done
        echo "	handle {"
        echo "		root * $D/www"
        echo "		file_server"
        echo "	}"
        echo "}"
        { printf '%s\n' "$SERVICES" | while IFS="$TAB" read -r id name p path g; do
            [ -n "$id" ] && [ "$g" != - ] && echo "$id $p $g"
          done; forwards; } | while read -r n a g; do
            echo ""
            echo "# $n"
            echo "$(sites "$g") {"
            echo "	tls internal"
            auth
            proxy "	" "$a"
            echo "}"
        done
    } > "$1.new" && mv "$1.new" "$1"
}
valid() { ./caddy validate --config "$1" --adapter caddyfile > /dev/null 2>> "$LOG"; }

js() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
item() {   # name, up (true/false), path, gateway port: one row of the start page (names hold no < > & " by now)
    if [ "$2" = true ]; then c=up n=""; else c=down n="not running · "; fi
    if [ -n "$3" ]; then echo "<li class=\"$c\"><span class=\"dot\"></span><a class=\"name\" href=\"$3\">$1</a><small>$n$3</small></li>"
    else echo "<li class=\"$c\"><span class=\"dot\"></span><a class=\"name\" data-port=\"$4\" href=\"#\">$1</a><small>${n}port $4</small></li>"; fi
}
# services.json and the start page: each declared service and your forwards, with whether it is listening now. Both
# are written again only when something in them changed.
write_status() {
    : > www/items.new
    {
        echo '{"host":"'"$(js "$(hostname 2>/dev/null)")"'","services":['
        sep=""
        printf '%s\n' "$SERVICES" | { while IFS="$TAB" read -r id name p path g; do
            [ -n "$id" ] || continue
            listening "$p" && up=true || up=false
            [ "$path" = - ] && path=""; [ "$g" = - ] && g=0
            printf '%s{"id":"%s","name":"%s","port":%s,"path":"%s","gateway_port":%s,"up":%s}\n' \
                "$sep" "$id" "$(js "$name")" "$p" "$path" "$g" "$up"
            item "$name" "$up" "$path" "$g" >> www/items.new
            sep=,
        done
        forwards | while read -r n a g; do
            listening "$a" && up=true || up=false
            printf '%s{"id":"%s","name":"%s","port":%s,"path":"","gateway_port":%s,"up":%s,"forward":true}\n' \
                "$sep" "$n" "$n" "$a" "$g" "$up"
            item "$n" "$up" "" "$g" >> www/items.new
            sep=,
        done; }
        echo ']}'
    } > www/services.json.new
    [ -s www/root.crt ] || { [ -s data/pki/authorities/local/root.crt ] && cp -f data/pki/authorities/local/root.crt www/root.crt; }
    if [ -f www/services.json ] && [ -f www/index.html ] && [ "$(cat www/services.json.new)" = "$(cat www/services.json)" ]; then
        rm -f www/services.json.new www/items.new
        return 0
    fi
    mv www/services.json.new www/services.json
    [ -s www/items.new ] || echo '<li class="empty">No addin declares a web service yet.</li>' > www/items.new
    write_page www/items.new
    rm -f www/items.new
}

# The start page, with the list as it is now; its script reads services.json again every few seconds.
write_page() {   # file with the list's rows
    h=$(hostname 2>/dev/null | tr -d '<>&"'); [ -n "$h" ] || h=MPC
    {
    cat <<'EOF'
<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>MPC Gateway</title>
<style>
:root{--bg:#120d1f;--card:#1d1530;--fg:#f1eafc;--dim:#a99bc4;--accent:#ff4fd8;--up:#3ee6a4;--down:#ff6b6b}
*{box-sizing:border-box}body{margin:0;font:16px/1.4 system-ui,sans-serif;background:var(--bg);color:var(--fg)}
main{max-width:44rem;margin:0 auto;padding:1.5rem 1rem}h1{font-size:1.4rem;margin:0 0 .2rem}
p.sub{color:var(--dim);margin:0 0 1.2rem}ul{list-style:none;padding:0;margin:0}
li{display:flex;align-items:center;gap:.8rem;background:var(--card);border-radius:.6rem;padding:.8rem 1rem;margin:.5rem 0}
li a.name{color:var(--fg);font-weight:600;text-decoration:none;flex:1}li a.name:hover{color:var(--accent)}
li.down a.name{color:var(--dim);pointer-events:none}small{color:var(--dim)}
.dot{width:.7rem;height:.7rem;border-radius:50%;background:var(--down);flex:none}li.up .dot{background:var(--up)}
.empty{color:var(--dim)}footer{margin-top:2rem;color:var(--dim);font-size:.9rem}footer a{color:var(--accent)}
</style>
<main>
EOF
    echo "<h1>$h</h1>"
    echo '<p class="sub">Web services on this device</p>'
    echo '<ul id="list">'
    cat "$1"
    cat <<'EOF'
</ul>
<footer>To stop the certificate warning, install <a href="/root.crt">this device's certificate authority</a> on your
computer and trust it for websites.</footer>
</main>
<script>
// Port services link to this page's host name on their own port. The list refreshes from services.json (by origin:
// a page opened with user:password@ in its address can't fetch a relative one).
function ports() {
  for (const a of document.querySelectorAll("a[data-port]")) a.href = "https://" + location.hostname + ":" + a.dataset.port + "/";
}
function el(t, c, x) { const e = document.createElement(t); if (c) e.className = c; if (x) e.textContent = x; return e; }
async function load() {
  try {
    const r = await fetch(location.origin + "/services.json", {cache: "no-store"});
    if (!r.ok) return;
    const d = await r.json(), list = document.getElementById("list");
    list.replaceChildren();
    if (!d.services.length) list.append(el("li", "empty", "No addin declares a web service yet."));
    for (const s of d.services) {
      const li = el("li", s.up ? "up" : "down"), a = el("a", "name", s.name);
      if (s.path) a.href = s.path; else { a.dataset.port = s.gateway_port; a.href = "#"; }
      li.append(el("span", "dot"), a, el("small", "", (s.up ? "" : "not running · ") + (s.path || "port " + s.gateway_port)));
      list.append(li);
    }
    ports();
  } catch (e) { }
}
ports(); setInterval(load, 5000);
</script>
</html>
EOF
    } > www/index.html.new && mv www/index.html.new www/index.html
}

# Writes Caddyfile from the settings, the services and the addresses now. A route of yours that Caddy refuses is left
# out (and logged), so one broken route never stops the rest.
configure() {
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
        valid Caddyfile || { say "Caddy refuses the config even without your routes"; return 1; }
    fi
    write_status
}

HOSTS=$(hosts)
SERVICES=$(services)
mkdir -p www
if [ -n "$USERCFG" ]; then
    CFG=$USERCFG
    [ -r "$CFG" ] || { say "config=$CFG can't be read"; exit 1; }
    write_status
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
    say "started Caddy $CADDY on $BIND:$PORT for: $(echo $HOSTS); services: $(printf '%s\n' "$SERVICES" | cut -f1 | tr '\n' ' ')"
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
    if [ $((now - LAST)) -ge "$RESCAN" ]; then
        LAST=$now
        if [ -n "$USERCFG" ]; then write_status
        else
            nh=$(hosts); ns=$(services)
            if [ "$nh" != "$HOSTS" ] || [ "$ns" != "$SERVICES" ]; then
                [ "$nh" != "$HOSTS" ] && say "addresses changed: $(echo $nh)"
                [ "$ns" != "$SERVICES" ] && say "services changed: $(printf '%s\n' "$ns" | cut -f1 | tr '\n' ' ')"
                HOSTS=$nh; SERVICES=$ns
                if configure && ./caddy reload --config "$CFG" --adapter caddyfile --address "unix/$D/admin.sock" >> "$LOG" 2>&1; then
                    say "Caddy reloaded"
                else
                    say "reload failed: starting Caddy again"
                    kill "$CADDY" 2>/dev/null
                fi
            else
                write_status
            fi
        fi
    fi
    sleep 2
done
say "MPC $MPC has exited"
stop
