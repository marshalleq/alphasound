#!/bin/sh
# Runs inside an alpine:<branch> container started by smoke-test.sh.
# The apkovl ships etc, usr, var and root; the container supplies /lib,
# /bin and /sbin, which on the device come from the initramfs and modloop.
# Every check stops the test on failure.
set -eu

: "${VARIANT:?VARIANT must be set}"
APKOVL="/deploy/alphasound-${VARIANT}.apkovl.tar.gz"

fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "ok: $*"; }

# Docker bind-mounts these three into every container; they cannot be replaced.
tar xzf "$APKOVL" -C / --exclude=etc/hosts --exclude=etc/hostname --exclude=etc/resolv.conf
pass "unpacked $APKOVL"

# --- Version stamps used by the web UI and the update compatibility check
for f in /etc/alphasound-version /etc/alphasound-alpine-version /etc/alphasound-build-time; do
    [ -s "$f" ] || fail "$f is missing or empty"
done
pass "version stamps present ($(cat /etc/alphasound-version), Alpine $(cat /etc/alphasound-alpine-version))"

# --- Every runlevel entry points at an init script that exists, and every
# service binary named by an init script is present and fully linked.
for link in /etc/runlevels/*/*; do
    svc=$(basename "$link")
    [ -f "/etc/init.d/$svc" ] || fail "runlevel entry $link has no /etc/init.d/$svc"
    # Read the service's command= the way openrc-run would, in a subshell.
    # shellcheck disable=SC1090,SC2034
    cmd=$( (RC_SVCNAME=$svc; command=""; . "/etc/init.d/$svc" >/dev/null 2>&1; echo "$command") || true)
    if [ -n "$cmd" ]; then
        [ -x "$cmd" ] || fail "service $svc: $cmd is not an executable file"
        ldd "$cmd" >/dev/null 2>&1 || fail "service $svc: $cmd has missing shared libraries: $(ldd "$cmd" 2>&1 | grep -i error)"
        pass "service $svc: $cmd links"
    fi
done

# --- Shell syntax of every script we ship
for f in /etc/local.d/*.start /etc/init.d/alphasound-* /etc/alphasound/*.sh /var/www/cgi-bin/* /usr/local/bin/alphasound-checkpoint; do
    sh -n "$f" || fail "shell syntax error in $f"
done
pass "shell syntax of shipped scripts"

# --- Core programs start and accept their configuration
shairport-sync -V >/dev/null || fail "shairport-sync -V"
pass "shairport-sync $(shairport-sync -V 2>&1 | head -1)"
# wpa_supplicant, busybox, musl and openrc live in /sbin, /bin and /lib,
# which the device takes from the boot media rather than the apkovl, so
# they are not tested here.
for bin in hostapd dnsmasq lighttpd jq; do
    path=$(command -v "$bin") || fail "$bin not installed"
    ldd "$path" >/dev/null 2>&1 || fail "$bin has missing shared libraries"
done
pass "hostapd, dnsmasq, lighttpd and jq present and linked"
dnsmasq --test >/dev/null 2>&1 || fail "dnsmasq rejects its configuration: $(dnsmasq --test 2>&1)"
pass "dnsmasq configuration"
lighttpd -tt -f /etc/lighttpd/lighttpd.conf || fail "lighttpd rejects its configuration"
pass "lighttpd configuration"
ssh-keygen -A >/dev/null
/usr/sbin/sshd -t || fail "sshd rejects its configuration"
pass "sshd configuration"

# --- Variant-specific contents
if [ "$VARIANT" = home ]; then
    python3 -c 'import PIL, numpy, gpiod' || fail "display stack: python imports"
    python3 -m py_compile /usr/local/bin/alphasound-display.py || fail "alphasound-display.py does not compile"
    ldd /usr/local/bin/alphasound-splash >/dev/null 2>&1 || fail "alphasound-splash missing or not linked"
    [ -s /usr/share/alphasound-splash/splash.raw ] || fail "splash image missing"
    pass "home: display stack, splash binary and image"
else
    for f in /usr/local/bin/alphasound-display.py /usr/local/bin/alphasound-splash /etc/init.d/alphasound-roon /var/www/cgi-bin/install-roon; do
        [ ! -e "$f" ] || fail "car variant still ships $f"
    done
    [ ! -e /usr/bin/python3 ] || fail "car variant ships python3"
    pass "car: display, splash, Roon and Python stripped"
fi

# --- Web UI: serves the page, refuses unauthenticated calls, logs in
mkdir -p /media/mmcblk0p1 /var/log
sed 's/^ALPHASOUND_ROOT_PASSWORD=.*/ALPHASOUND_ROOT_PASSWORD=smoke-test-pw/' /defaults/alphasound.txt > /media/mmcblk0p1/alphasound.txt
lighttpd -f /etc/lighttpd/lighttpd.conf || fail "lighttpd did not start"
sleep 1

# http EXPECTED_CODE URL [wget options...]: prints response headers.
http() {
    want=$1; url=$2; shift 2
    out=$(wget -S -q -O /tmp/body "$@" "$url" 2>&1 || true)
    echo "$out" | grep -q "HTTP/1.[01] $want" || fail "$url: expected HTTP $want, got: $(echo "$out" | grep -m1 HTTP/)"
    echo "$out"
}

http 200 http://127.0.0.1/ >/dev/null
grep -q '<title>Alphasound</title>' /tmp/body || fail "index page does not look like the Alphasound UI"
pass "web UI serves the index page"

http 401 http://127.0.0.1/cgi-bin/status >/dev/null
pass "status refuses a request without a session"

http 401 http://127.0.0.1/cgi-bin/login --post-data 'password=wrong' >/dev/null
pass "login refuses a wrong password"

headers=$(http 200 http://127.0.0.1/cgi-bin/login --post-data 'password=smoke-test-pw')
token=$(echo "$headers" | sed -n 's/.*Set-Cookie: alphasound=\([0-9a-f]*\);.*/\1/p')
[ -n "$token" ] || fail "login did not set a session cookie"
pass "login accepts the configured password and sets a session cookie"

http 200 http://127.0.0.1/cgi-bin/status --header "Cookie: alphasound=$token" >/dev/null
jq -e . /tmp/body >/dev/null || fail "status did not return JSON: $(head -c 300 /tmp/body)"
pass "status returns JSON with a valid session"

echo "Smoke test passed for the $VARIANT variant."
