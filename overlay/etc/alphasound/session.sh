# Sourced from CGI scripts to require an authenticated session.
# Reads HTTP_COOKIE, looks up the token in $SESSION_DIR, checks expiry.
# If anything is wrong, prints HTTP 401 and exits — caller never returns.
#
# Sessions live in tmpfs so they don't survive reboot. The 30-day Max-Age
# on the cookie means the browser keeps trying with the old token after
# reboot and gets a 401, which the client-side JS handles by showing the
# login form again. Browsers / Apple Keychain still autofill, so it's
# typically a one-tap re-login.

SESSION_DIR=/tmp/alphasound-sessions

require_session() {
    local token expiry now
    token=$(printf '%s' "${HTTP_COOKIE:-}" | tr ';' '\n' \
        | grep -oE 'alphasound=[a-fA-F0-9]+' | head -1 | cut -d= -f2)
    if [ -z "$token" ] || [ ! -f "$SESSION_DIR/$token" ]; then
        printf 'Status: 401 Unauthorized\r\n'
        printf 'Content-Type: text/plain\r\n\r\n'
        printf 'login required\n'
        exit
    fi
    expiry=$(cat "$SESSION_DIR/$token" 2>/dev/null)
    now=$(date +%s)
    if [ -n "$expiry" ] && [ "$now" -gt "$expiry" ]; then
        rm -f "$SESSION_DIR/$token"
        printf 'Status: 401 Unauthorized\r\n'
        printf 'Content-Type: text/plain\r\n\r\n'
        printf 'session expired\n'
        exit
    fi
}
