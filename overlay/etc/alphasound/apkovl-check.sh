# Sourced from upload/update-pull CGIs to refuse apkovls built against
# an incompatible Alpine major version. Modloop (kernel + modules) ships
# in the .img.xz and is pinned to a specific Alpine point release; an
# apkovl built against a different MAJOR version (e.g. 3.21 -> 3.22)
# brings a libc/openrc/utility set that won't talk to that modloop.
#
# Usage: check_apkovl_compat /path/to/uploaded.tar.gz
# On mismatch: print 400, exit. On compat: returns silently.

check_apkovl_compat() {
    local file=$1
    local current_full new_full current_major new_major

    current_full=$(cat /etc/alphasound-alpine-version 2>/dev/null)
    # Extract just the version file from the archive without unpacking
    # the whole thing. Both leading-./ and bare paths are tried because
    # tar listings vary by producer.
    new_full=$(tar -xzf "$file" -O ./etc/alphasound-alpine-version 2>/dev/null) \
        || new_full=$(tar -xzf "$file" -O etc/alphasound-alpine-version 2>/dev/null)

    if [ -z "$new_full" ]; then
        printf 'Status: 400 Bad Request\r\nContent-Type: text/plain\r\n\r\n'
        printf 'apkovl is missing /etc/alphasound-alpine-version — refusing to install something that may not be an Alphasound apkovl\n'
        exit
    fi

    # Compare major.minor (e.g. 3.21). Patch differences are fine.
    current_major=$(printf '%s' "$current_full" | cut -d. -f1-2)
    new_major=$(printf '%s' "$new_full" | cut -d. -f1-2)

    if [ "$current_major" != "$new_major" ]; then
        printf 'Status: 400 Bad Request\r\nContent-Type: text/plain\r\n\r\n'
        printf 'incompatible: this apkovl was built against Alpine %s\n' "$new_full"
        printf 'but the device is running modloop from Alpine %s.\n' "$current_full"
        printf 'Reflash the matching .img.xz instead of applying just the apkovl.\n'
        exit
    fi
}
