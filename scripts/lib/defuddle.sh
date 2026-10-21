# shellcheck shell=bash
# The Defuddle page reader (pinned in versions.sh as RR_DEFUDDLE_*): download, verify and install
# the files the app needs. Sourced after lib/common.sh by build-app.sh (into
# Contents/Resources/defuddle/) and setup.sh (into $READREAD_HOME/defuddle/). bash 3.2.

# rr_defuddle_tarball: prints the path of the verified npm tarball in the download cache
# (downloaded if needed; its sha256 and npm's sha512 integrity both checked).
rr_defuddle_tarball() {
    local tarball="$RR_CACHE_DIR/downloads/$RR_DEFUDDLE_TARBALL" integrity
    rr_provision "$RR_DEFUDDLE_TARBALL" "$RR_DEFUDDLE_URL" "$RR_DEFUDDLE_SIZE" "$RR_DEFUDDLE_SHA256" \
        "$RR_CACHE_DIR/downloads" >&2
    integrity="sha512-$(openssl dgst -sha512 -binary "$tarball" | base64)" || rr_die "cannot hash $tarball"
    [ "$integrity" = "$RR_DEFUDDLE_INTEGRITY" ] || rr_die "$tarball does not match npm's dist.integrity
  expected: $RR_DEFUDDLE_INTEGRITY
  got:      $integrity"
    printf '%s\n' "$tarball"
}

# rr_defuddle_installed <dir>: <dir> holds every pinned file with its size and sha256, and nothing else.
rr_defuddle_installed() {
    local dir=$1 path size sha name count=0
    [ -d "$dir" ] || return 1
    while read -r path size sha name; do
        [ -n "$path" ] || continue
        rr_file_ok "$dir/$name" "$size" "$sha" || return 1
        count=$((count + 1))
    done <<<"$RR_DEFUDDLE_FILES"
    [ "$(find "$dir" -mindepth 1 | wc -l | tr -d ' ')" = "$count" ]
}

# rr_install_defuddle <dir>: <dir> becomes exactly the pinned files, taken from the verified tarball
# and checked one by one (replaced atomically: built in <dir>.partial, then renamed).
rr_install_defuddle() {
    local dest=$1 tarball tmp path size sha name
    local members=()
    tarball=$(rr_defuddle_tarball) || rr_die "cannot provision $RR_DEFUDDLE_TARBALL"
    while read -r path size sha name; do
        if [ -n "$path" ]; then members+=("$path"); fi
    done <<<"$RR_DEFUDDLE_FILES"
    tmp="$dest.partial"
    rm -rf "$tmp" || rr_die "cannot remove $tmp"
    mkdir -p "$tmp/x" || rr_die "cannot create $tmp"
    tar -xzf "$tarball" -C "$tmp/x" "${members[@]}" || rr_die "cannot extract ${members[*]} from $tarball"
    while read -r path size sha name; do
        [ -n "$path" ] || continue
        rr_file_ok "$tmp/x/$path" "$size" "$sha" ||
            rr_die "$path in $RR_DEFUDDLE_TARBALL does not match its pin ($size bytes, sha256 $sha)"
        mv "$tmp/x/$path" "$tmp/$name" || rr_die "cannot move $path into $tmp"
    done <<<"$RR_DEFUDDLE_FILES"
    rm -rf "$tmp/x" || rr_die "cannot clean up $tmp/x"
    rm -rf "$dest" || rr_die "cannot remove the old $dest"
    mv "$tmp" "$dest" || rr_die "cannot move $tmp to $dest"
}
