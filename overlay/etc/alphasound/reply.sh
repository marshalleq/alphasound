# Shared CGI response + reboot helpers. Sourced from /var/www/cgi-bin/*
# alongside session.sh.

# Emit a plain-text CGI response and exit. Every mutating endpoint ends
# with reply(...) so the caller never has to think about Content-Type,
# newlines, or explicit exit.
reply() {
    printf 'Status: %s\r\nContent-Type: text/plain\r\n\r\n%s\n' "$1" "$2"
    exit
}

# Apply-and-reboot: every "change config, then reboot" endpoint funnels
# through here so we have a single definition of "how to reboot the
# device after a CGI". Two gotchas worth the shared helper:
#
#   1. `( sleep 1; reboot ) &` alone isn't enough under lighttpd — when
#      the CGI exits, lighttpd can clean up children in the same process
#      group, killing our pending reboot. setsid puts the reboot helper
#      in its own session so it survives CGI teardown.
#   2. The reboot needs to be scheduled BEFORE `reply` runs, because
#      reply calls `exit` — anything after it is unreachable.
reply_and_reboot() {
    setsid sh -c 'sleep 1; reboot' </dev/null >/dev/null 2>&1 &
    reply "200 OK" "$1"
}
