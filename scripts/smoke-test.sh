#!/bin/bash
# Smoke-tests a built ReadRead.app without touching the user's data and without launching the GUI.
#
#   scripts/smoke-test.sh build/ReadRead.app
#
#   (defuddle) Resources/defuddle/ holds exactly the pinned Defuddle files (scripts/lib/versions.sh,
#       RR_DEFUDDLE_FILES: defuddle.full.js and LICENSE), each with its pinned size and sha256.
#   (a) Bundled server: Resources/python/bin/python3 -I -B Resources/tts_server/tts_server.py
#       --models-dir Resources/models --preload zh,en prints READY within 120 s; GET /health is 200
#       with the token and 401 without; POST /synthesize (format json, as the app asks) for zh
#       (zf_001) and en (af_heart) gives a 24 kHz WAV, silent false, a duration within 0.8-1.4x of
#       a known-good build's, and a timed token (end > start) for every word of the text: the en
#       text has a word no lexicon knows, which only the espeak-ng fallback reads. Closing its
#       stdin makes it exit within 5 s, and its stderr has no line that means broken espeak-ng
#       data ("Can't read dictionary file", "words count mismatch").
#   (b) Contents/MacOS/ReadRead --self-test exits 0: the bundled Defuddle reads a page held in
#       memory in an offscreen web view (no network) into the expected document, and through the
#       app's own lifecycle code it starts the bundled server, checks that every app voice
#       (Voice.all) is in GET /voices, synthesizes zh, en-US and en-GB, plays a fixture document
#       offline, and stops the server. Its report must name the bundle's own
#       Resources/defuddle/defuddle.full.js as the page reader. A binary without a self-test mode
#       is FAILed without being run: it would start the menu bar app instead.
#   (c) The bundle is unchanged by (a) and (b): same files, sizes and mtimes (no runtime .pyc).
#   (d) (a) again from a copy of the app, named ReadRead.app whatever <app> is called, whose bundle
#       path is >= 160 characters (espeak-ng keeps its data path in a 160-byte buffer; long paths
#       happen, e.g. under App Translocation).
#   (e) codesign --verify --strict --deep.
#   (f) v0.4.0 UI: the Info.plist has development region en, localizations [en, zh-Hans], one
#       Services item (readAloud, plain text + URL, an NSRequiredContext so it is shown) and document
#       types that are all Viewer / Alternate (never the default app); zh-Hans.lproj holds UTF-8,
#       lint-clean Localizable.strings and ServicesMenu.strings (the Services title translated); the
#       binary has the readAloud:userData:error: selector the Services entry names. ATS: local
#       networking and NSAllowsArbitraryLoadsInWebContent (the page reader opens http:// pages), no
#       NSAllowsArbitraryLoads.
#
# Cache, logs, user lexicon and TMPDIR point into a temp dir (READREAD_CACHE_DIR, READREAD_LOG_DIR,
# READREAD_USER_LEXICON, READREAD_HOME), which is deleted at exit unless a step failed.
# READREAD_SMOKE_ASSUME_SELF_TEST=1 skips the self-test-mode detection in (b); set it only for a
# binary known to support --self-test. Exit status: 0 if every step passed, else 1.
set -euo pipefail

if [ $# -ne 1 ] || [ ! -d "$1/Contents" ]; then
    echo "usage: $0 <path/to/ReadRead.app>" >&2
    exit 2
fi
APP="$(cd "$1" && pwd)"
READY_TIMEOUT=120
SELFTEST_TIMEOUT=300
EXIT_TIMEOUT=5
ZH_TEXT="你好，这是一段中文语音合成测试。"
# "blorptastic" is in no lexicon, so misaki's espeak fallback (espeak-ng and its data path) must run.
EN_TEXT="This short speech synthesis test says blorptastic."
# Seconds of audio a known-good build makes of each text (measured 2026-10-20: 3.325 s, 2.890 s), and
# the band around them a build may land in. Words the front end drops make the audio shorter.
ZH_EXPECTED_S=3.32
EN_EXPECTED_S=2.89
DURATION_MIN=0.8
DURATION_MAX=1.4
# Server stderr lines that mean the espeak-ng fallback is broken (its data is missing or unreadable);
# Sources/ReadRead/SelfTest.swift (logMarkers) looks for the same ones.
ESPEAK_ERRORS=("Can't read dictionary file" "words count mismatch")

new_tmp_root() { # <parent>: a fresh rrsmoke.XXXXXX dir, printed with symlinks resolved
    local dir
    dir=$(mktemp -d "${1%/}/rrsmoke.XXXXXX") || return 1
    (cd "$dir" && pwd -P)
}
TMP_ROOT=$(new_tmp_root "${TMPDIR:-/tmp}")
# Each step's cache dir is <root>/<step>/cache, and the server refuses a cache dir whose
# espeak-ng-data link would not fit espeak-ng's path buffer (150 bytes). A deep TMPDIR (sandboxes,
# CI) would make every step fail for that reason alone, so fall back to /tmp.
CACHE_PROBE="$TMP_ROOT/d/cache/espeak-ng-data"
if [ "$(printf '%s' "$CACHE_PROBE" | wc -c)" -gt 150 ]; then
    rmdir "$TMP_ROOT"
    TMP_ROOT=$(new_tmp_root /tmp)
fi
FAILURES=0
SRV_PID=""
CHILD_PID=""
RESULTS=""

cleanup() {
    for pid in $SRV_PID $CHILD_PID; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null || true
            sleep 1
            kill -KILL "$pid" 2>/dev/null || true
        fi
    done
    if [ "$FAILURES" = 0 ]; then
        rm -rf "$TMP_ROOT"
    else
        rm -rf "$TMP_ROOT/long" # the long-path app copy
        echo "Logs kept in $TMP_ROOT"
    fi
}
trap cleanup EXIT

pass() {
    RESULTS="$RESULTS
PASS ($1) $2"
    echo "PASS ($1) $2"
}
fail() {
    FAILURES=$((FAILURES + 1))
    RESULTS="$RESULTS
FAIL ($1) $2"
    echo "FAIL ($1) $2"
}
tail_file() { # <file> <label>
    if [ -s "$1" ]; then
        echo "      --- last lines of $2 ---"
        tail -n 25 "$1" | sed 's/^/      /'
    fi
}

now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'; }

# Isolated runtime locations for the server and the app (never the user's real ones).
env_for() { # <dir>: prints KEY=VALUE lines for env(1)
    mkdir -p "$1/cache" "$1/logs" "$1/support" "$1/home" "$1/tmp"
    printf '%s\n' "READREAD_CACHE_DIR=$1/cache" "READREAD_LOG_DIR=$1/logs" \
        "READREAD_USER_LEXICON=$1/support/lexicon_zh.json" "READREAD_HOME=$1/home" "TMPDIR=$1/tmp"
}

# A 64-hex-char token, like the app generates.
new_token() { od -An -N32 -tx1 /dev/urandom | tr -d ' \n'; }

json_get() { plutil -extract "$2" raw -o - "$1" 2>/dev/null || true; }

http_status() { # <out_file> <curl args...>: prints the HTTP status (000 on connection failure)
    local out=$1
    shift
    curl -sS --noproxy '*' --max-time 120 -o "$out" -w '%{http_code}' "$@" 2>>"$TMP_ROOT/curl.err" || echo 000
}

# perl -e "$SYNTH_CHECK_PL" -- <response.json> <text> <expected_s> <min> <max> <wav_out>: checks a
# format-json /synthesize response and writes its audio to <wav_out>. Prints a summary and exits 0,
# or prints the problems and exits 1. (/usr/bin/perl and its core JSON::PP ship with macOS.)
SYNTH_CHECK_PL=$(
    cat <<'PERL'
use strict; use warnings;
use Encode qw(decode); use JSON::PP; use MIME::Base64;
binmode STDOUT, ":encoding(UTF-8)";
my ($file, $text, $expected, $lo, $hi, $wav_out) = @ARGV;
$text = decode("UTF-8", $text);
open(my $in, "<:raw", $file) or do { print "cannot read $file\n"; exit 1 };
my $raw = do { local $/; <$in> };
my $r = eval { JSON::PP->new->utf8->decode($raw) };
if (ref $r ne "HASH") { print "the body is not a JSON object: ", substr($raw, 0, 200), "\n"; exit 1 }
my @problems;
my $d = (defined $r->{duration} && !ref $r->{duration}) ? $r->{duration} : -1;
my $bytes = decode_base64(defined $r->{audio} && !ref $r->{audio} ? $r->{audio} : "");
if (open(my $out, ">:raw", $wav_out)) { print $out $bytes; close $out }
my ($wav_s, $rate);
if (substr($bytes, 0, 4) eq "RIFF" && substr($bytes, 8, 4) eq "WAVE") {
    my ($pos, $channels, $bits) = (12);
    while ($pos + 8 <= length $bytes) {
        my ($id, $size) = unpack("a4 V", substr($bytes, $pos, 8));
        if ($id eq "fmt " && $size >= 16) {
            ($channels, $rate, $bits) = (unpack("v v V V v v", substr($bytes, $pos + 8, 16)))[1, 2, 5];
        } elsif ($id eq "data" && $rate && $channels && $bits) {
            $wav_s = $size / ($rate * $channels * $bits / 8);
            last;
        }
        $pos += 8 + $size + ($size % 2);
    }
}
if (!defined $wav_s) { push @problems, "the audio is not a PCM WAV" }
elsif (abs($wav_s - $d) > 0.01) { push @problems, sprintf("the WAV holds %.3f s, the duration says %.3f s", $wav_s, $d) }
push @problems, "the WAV is not 24 kHz" if defined $wav_s && $rate != 24000;
push @problems, "sample_rate is not 24000" unless ($r->{sample_rate} // 0) == 24000;
push @problems, "silent is not false" if !exists $r->{silent} || $r->{silent};
push @problems, sprintf("%.3f s of audio, outside %.2f-%.2f s (%sx-%sx a known-good %.2f s)",
    $d, $lo * $expected, $hi * $expected, $lo, $hi, $expected) unless $d >= $lo * $expected && $d <= $hi * $expected;
my @timed = grep {
    ref $_ eq "HASH" && defined $_->{text} && ($_->{start} // -1) >= 0 && ($_->{end} // -1) > $_->{start}
        && $_->{end} <= $d + 0.05
} @{ ref $r->{tokens} eq "ARRAY" ? $r->{tokens} : [] };
my $covered = join "", map { $_->{text} } @timed;
# Latin words and ideographs (not \p{Han}: its script extensions take in 。 and ，).
my @untimed = grep { index($covered, $_) < 0 } ($text =~ /([A-Za-z]+|\p{Ideographic})/g);
push @problems, "words with no timed token: @untimed" if @untimed;
if (@problems) { print join("; ", @problems), "\n"; exit 1 }
printf "%.3f s of audio (known-good %.2f s), %d timed tokens cover every word\n", $d, $expected, scalar @timed;
PERL
)

# ── Server checks, used by (a) and (d) ───────────────────────────────
# server_checks <step> <app> <workdir>: returns 0 when every check passed.
server_checks() {
    local step=$1 app=$2 dir=$3
    local res="$app/Contents/Resources" token port pid line status code elapsed_ms t0 envs
    mkdir -p "$dir"
    envs=$(env_for "$dir")
    token=$(new_token)
    rm -f "$dir/stdin"
    mkfifo "$dir/stdin"
    # The server's stdin is a FIFO held open on fd 3: closing fd 3 is the parent going away.
    # shellcheck disable=SC2086 # $envs is one KEY=VALUE per line, split on newlines only
    (
        IFS=$'\n'
        exec env $envs READREAD_TOKEN="$token" ORT_DISABLE_TELEMETRY=1 PYTHONDONTWRITEBYTECODE=1 \
            PYTHONIOENCODING=utf-8 "$res/python/bin/python3" -I -B "$res/tts_server/tts_server.py" \
            --models-dir "$res/models" --preload zh,en <"$dir/stdin" >"$dir/stdout" 2>"$dir/stderr"
    ) &
    SRV_PID=$!
    exec 3>"$dir/stdin"
    t0=$(now_ms)

    # READY within the timeout.
    while :; do
        if [ -s "$dir/stdout" ] && [ "$(wc -l <"$dir/stdout")" -ge 1 ]; then break; fi
        if ! kill -0 "$SRV_PID" 2>/dev/null; then
            fail "$step" "server exited before printing READY"
            tail_file "$dir/stderr" "server stderr"
            exec 3>&-
            return 1
        fi
        if [ $(($(now_ms) - t0)) -gt $((READY_TIMEOUT * 1000)) ]; then
            fail "$step" "no READY line within ${READY_TIMEOUT} s"
            tail_file "$dir/stderr" "server stderr"
            exec 3>&-
            return 1
        fi
        sleep 0.2
    done
    line=$(head -n 1 "$dir/stdout")
    case "$line" in
    "READY "*) ;;
    *)
        fail "$step" "first stdout line is not READY: $line"
        tail_file "$dir/stderr" "server stderr"
        exec 3>&-
        return 1
        ;;
    esac
    printf '%s' "${line#READY }" >"$dir/ready.json"
    port=$(json_get "$dir/ready.json" port)
    pid=$(json_get "$dir/ready.json" pid)
    if [ -z "$port" ] || [ "$(json_get "$dir/ready.json" api)" != 2 ] || [ "$pid" != "$SRV_PID" ]; then
        fail "$step" "malformed READY line (want port, api 2, pid $SRV_PID): $line"
        exec 3>&-
        return 1
    fi
    pass "$step" "READY after $(($(now_ms) - t0)) ms: $line"

    local ok=1
    local base="http://127.0.0.1:$port"
    code=$(http_status "$dir/health.json" -H "Authorization: Bearer $token" "$base/health")
    if [ "$code" = 200 ] && [ "$(json_get "$dir/health.json" status)" = ok ]; then
        pass "$step" "/health 200 with token (python $(json_get "$dir/health.json" versions.python), kokoro_onnx $(json_get "$dir/health.json" versions.kokoro_onnx), onnxruntime $(json_get "$dir/health.json" versions.onnxruntime), misaki $(json_get "$dir/health.json" versions.misaki))"
    else
        fail "$step" "/health with token: HTTP $code, body: $(head -c 300 "$dir/health.json" 2>/dev/null)"
        ok=0
    fi
    code=$(http_status "$dir/noauth.json" "$base/health")
    local code_bad
    code_bad=$(http_status "$dir/badauth.json" -H "Authorization: Bearer $(new_token)" "$base/health")
    if [ "$code" = 401 ] && [ "$code_bad" = 401 ]; then
        pass "$step" "/health 401 without a token and with a wrong token"
    else
        fail "$step" "/health without token: HTTP $code, wrong token: HTTP $code_bad (want 401)"
        ok=0
    fi

    local lang voice text expected summary
    for lang in zh en; do
        if [ "$lang" = zh ]; then
            voice=zf_001 text=$ZH_TEXT expected=$ZH_EXPECTED_S
        else
            voice=af_heart text=$EN_TEXT expected=$EN_EXPECTED_S
        fi
        printf '{"text":"%s","voice":"%s","lang":"%s","format":"json","request_id":"smoke-%s"}' \
            "$text" "$voice" "$lang" "$lang" >"$dir/req-$lang.json"
        t0=$(now_ms)
        code=$(http_status "$dir/out-$lang.json" -X POST -H "Authorization: Bearer $token" \
            -H 'Content-Type: application/json' --data-binary "@$dir/req-$lang.json" "$base/synthesize")
        elapsed_ms=$(($(now_ms) - t0))
        if [ "$code" != 200 ]; then
            fail "$step" "POST /synthesize $lang ($voice): HTTP $code, body: $(head -c 300 "$dir/out-$lang.json" 2>/dev/null)"
            ok=0
            continue
        fi
        if summary=$(perl -e "$SYNTH_CHECK_PL" -- "$dir/out-$lang.json" "$text" "$expected" \
            "$DURATION_MIN" "$DURATION_MAX" "$dir/out-$lang.wav"); then
            pass "$step" "POST /synthesize $lang ($voice) in ${elapsed_ms} ms: $summary"
        else
            fail "$step" "POST /synthesize $lang ($voice): ${summary:-the response could not be checked (perl failed)}"
            ok=0
        fi
    done

    # Parent-death watchdog: EOF on stdin must end the server.
    exec 3>&-
    t0=$(now_ms)
    while kill -0 "$SRV_PID" 2>/dev/null && [ $(($(now_ms) - t0)) -lt $((EXIT_TIMEOUT * 1000)) ]; do
        sleep 0.1
    done
    if kill -0 "$SRV_PID" 2>/dev/null; then
        fail "$step" "server still running ${EXIT_TIMEOUT} s after its stdin was closed"
        kill -KILL "$SRV_PID" 2>/dev/null || true
        ok=0
    else
        status=0
        wait "$SRV_PID" || status=$?
        if [ "$status" = 0 ]; then
            pass "$step" "server exited $(($(now_ms) - t0)) ms after stdin EOF (status 0)"
        else
            fail "$step" "server exited with status $status after stdin EOF (want 0)"
            ok=0
        fi
    fi
    SRV_PID=""
    if grep -F -e "${ESPEAK_ERRORS[0]}" -e "${ESPEAK_ERRORS[1]}" "$dir/stderr" >"$dir/espeak-errors.txt"; then
        fail "$step" "server stderr shows broken espeak-ng data:"
        sed -n '1,5s/^/      /p' "$dir/espeak-errors.txt"
        ok=0
    else
        pass "$step" "server stderr: no espeak-ng data errors"
    fi
    if [ "$(wc -l <"$dir/stdout")" -ne 1 ]; then
        fail "$step" "stdout carried more than the READY line:"
        sed -n '1,5s/^/      /p' "$dir/stdout"
        ok=0
    fi
    if [ "$ok" != 1 ]; then tail_file "$dir/stderr" "server stderr"; fi
    [ "$ok" = 1 ]
}

snapshot() { # <app> <out>: every path with size and mtime (ns)
    find "$1" -print0 | xargs -0 stat -f '%N|%z|%Fm' | LC_ALL=C sort >"$2"
}

echo "=== Smoke test: $APP ==="
snapshot "$APP" "$TMP_ROOT/before.txt"

# ── (defuddle) bundled Defuddle page reader ──────────────────────────
# Contents/Resources/defuddle/ holds exactly the pinned Defuddle files (scripts/lib/versions.sh,
# RR_DEFUDDLE_FILES), each with its size and sha256, and nothing else: the app injects
# defuddle.full.js into an offscreen web view to read pages on this Mac.
echo "-- (defuddle) bundled Defuddle page reader"
# shellcheck source-path=SCRIPTDIR source=lib/versions.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/versions.sh"
DEFUDDLE_DIR="$APP/Contents/Resources/defuddle"
defuddle_ok=1
defuddle_count=0
while read -r _ size sha name; do
    [ -n "$name" ] || continue
    defuddle_count=$((defuddle_count + 1))
    if [ ! -f "$DEFUDDLE_DIR/$name" ]; then
        fail defuddle "missing $DEFUDDLE_DIR/$name"
        defuddle_ok=0
        continue
    fi
    got_sha=$(shasum -a 256 "$DEFUDDLE_DIR/$name" | awk '{print $1}')
    got_size=$(stat -f %z "$DEFUDDLE_DIR/$name")
    if [ "$got_sha" != "$sha" ] || [ "$got_size" != "$size" ]; then
        fail defuddle "$name: $got_size bytes, sha256 $got_sha (pinned: $size bytes, sha256 $sha)"
        defuddle_ok=0
    fi
done <<<"$RR_DEFUDDLE_FILES"
defuddle_found=$(find "$DEFUDDLE_DIR" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
if [ "$defuddle_ok" = 1 ] && [ "$defuddle_found" != "$defuddle_count" ]; then
    fail defuddle "$DEFUDDLE_DIR holds $defuddle_found entries, the pin lists $defuddle_count"
    defuddle_ok=0
fi
if [ "$defuddle_ok" = 1 ]; then
    pass defuddle "Defuddle $RR_DEFUDDLE_VERSION: $defuddle_count files match their pinned sha256 ($(awk 'NF == 4 {printf "%s %s ", $4, substr($3, 1, 12)}' <<<"$RR_DEFUDDLE_FILES"))"
fi
# ── end of the Defuddle check ────────────────────────────────────────

# ── (a) bundled server ───────────────────────────────────────────────
echo "-- (a) bundled TTS server"
server_checks a "$APP" "$TMP_ROOT/a" || true

# ── (b) --self-test ──────────────────────────────────────────────────
echo "-- (b) ReadRead --self-test"
BIN="$APP/Contents/MacOS/ReadRead"
strings -a "$BIN" >"$TMP_ROOT/bin-strings.txt" 2>/dev/null || true
if [ "${READREAD_SMOKE_ASSUME_SELF_TEST:-0}" != 1 ] && ! grep -Eqi 'self[-_]?test' "$TMP_ROOT/bin-strings.txt"; then
    fail b "$BIN has no --self-test mode (no self-test symbol in the binary). Not running it: without that mode it would launch the menu bar app. Rebuild from Sources with --self-test support."
else
    mkdir -p "$TMP_ROOT/b"
    envs=$(env_for "$TMP_ROOT/b")
    t0=$(now_ms)
    # shellcheck disable=SC2086 # $envs is one KEY=VALUE per line, split on newlines only
    (
        IFS=$'\n'
        exec env $envs "$BIN" --self-test </dev/null >"$TMP_ROOT/b/stdout" 2>"$TMP_ROOT/b/stderr"
    ) &
    CHILD_PID=$!
    while kill -0 "$CHILD_PID" 2>/dev/null && [ $(($(now_ms) - t0)) -lt $((SELFTEST_TIMEOUT * 1000)) ]; do
        sleep 0.5
    done
    if kill -0 "$CHILD_PID" 2>/dev/null; then
        kill -TERM "$CHILD_PID" 2>/dev/null || true
        sleep 2
        kill -KILL "$CHILD_PID" 2>/dev/null || true
        fail b "--self-test did not finish within ${SELFTEST_TIMEOUT} s (killed)"
        tail_file "$TMP_ROOT/b/stderr" "self-test stderr"
    else
        status=0
        wait "$CHILD_PID" || status=$?
        report=$(tail -n 1 "$TMP_ROOT/b/stdout" 2>/dev/null || true)
        if [ "$status" = 0 ]; then
            pass b "--self-test exited 0 after $(($(now_ms) - t0)) ms: $report"
        else
            fail b "--self-test exited $status: $report"
            tail_file "$TMP_ROOT/b/stderr" "self-test stderr"
            tail_file "$TMP_ROOT/b/logs/tts-server.log" "tts-server.log"
        fi
        # The page reader: the bundle's own Defuddle (not a dev copy) read the self test's page.
        printf '%s\n' "$report" >"$TMP_ROOT/b/report.json"
        reader=$(json_get "$TMP_ROOT/b/report.json" extraction.script)
        reader_dir=$(cd "$(dirname "${reader:-/nonexistent/x}")" 2>/dev/null && pwd -P || true)
        if [ "$(json_get "$TMP_ROOT/b/report.json" extraction.ok)" = true ] &&
            [ "$(basename "${reader:-x}")" = defuddle.full.js ] &&
            [ "$reader_dir" = "$(cd "$APP/Contents/Resources/defuddle" 2>/dev/null && pwd -P)" ]; then
            pass b "page reader: the bundled Defuddle read the self test's page on this Mac in $(json_get "$TMP_ROOT/b/report.json" extraction.ms) ms ($(json_get "$TMP_ROOT/b/report.json" extraction.units) units)"
        else
            fail b "page reader: ok=$(json_get "$TMP_ROOT/b/report.json" extraction.ok), script=${reader:-none}, error: $(json_get "$TMP_ROOT/b/report.json" extraction.error)"
        fi
    fi
    CHILD_PID=""
fi

# ── (c) bundle immutability ──────────────────────────────────────────
echo "-- (c) bundle unchanged by (a) and (b)"
snapshot "$APP" "$TMP_ROOT/after.txt"
if diff "$TMP_ROOT/before.txt" "$TMP_ROOT/after.txt" >"$TMP_ROOT/bundle.diff"; then
    pass c "no file in the bundle was added, removed or modified ($(wc -l <"$TMP_ROOT/before.txt" | tr -d ' ') paths)"
else
    fail c "the bundle changed at runtime ($(grep -c '^[<>]' "$TMP_ROOT/bundle.diff") diff lines):"
    grep '^[<>]' "$TMP_ROOT/bundle.diff" | sed -n '1,20s/^/      /p'
fi

# ── (d) long bundle path ─────────────────────────────────────────────
echo "-- (d) bundled server from a long bundle path"
LONG_PARENT="$TMP_ROOT/long"
LONG_NAME="ReadRead.app" # the copy's name, whatever $APP is called
while [ $((${#LONG_PARENT} + 1 + ${#LONG_NAME})) -lt 160 ]; do LONG_PARENT="$LONG_PARENT/long-path-check"; done
mkdir -p "$LONG_PARENT"
LONG_APP="$LONG_PARENT/$LONG_NAME"
ditto --clone "$APP" "$LONG_APP"
ESPEAK_DATA="$LONG_APP/Contents/Resources/python/lib/python3.12/site-packages/espeakng_loader/espeak-ng-data"
echo "  bundle path: ${#LONG_APP} chars; its espeak-ng-data path: ${#ESPEAK_DATA} chars"
server_checks d "$LONG_APP" "$TMP_ROOT/d" || true
rm -rf "$TMP_ROOT/long"

# ── (e) signature ────────────────────────────────────────────────────
echo "-- (e) code signature"
if codesign --verify --strict --deep "$APP" 2>"$TMP_ROOT/codesign.txt"; then
    pass e "codesign --verify --strict --deep: valid"
else
    fail e "codesign --verify --strict --deep: $(tr '\n' ' ' <"$TMP_ROOT/codesign.txt")"
fi

# ── (f) v0.4.0 UI (P5): Info.plist keys, localizations, Services ─────
echo "-- (f) localizations, Services and document types"
# perl -e "$PLIST_CHECK_PL" < <Info.plist as JSON>: prints a summary and exits 0, or the problems and 1.
PLIST_CHECK_PL=$(
    cat <<'PERL'
use strict; use warnings; use JSON::PP;
local $/;
my $p = decode_json(<STDIN>);
my @problems;
sub want { my ($ok, $message) = @_; push @problems, $message unless $ok; }
want(($p->{CFBundleDevelopmentRegion} // '') eq 'en', 'CFBundleDevelopmentRegion is not en');
my @languages = @{ $p->{CFBundleLocalizations} // [] };
want(join(',', sort @languages) eq 'en,zh-Hans', "CFBundleLocalizations is [@languages], not [en zh-Hans]");
my @services = @{ $p->{NSServices} // [] };
want(@services == 1, scalar(@services) . ' NSServices entries, not 1');
if (my $s = $services[0]) {
    want(($s->{NSMessage} // '') eq 'readAloud', 'NSMessage is not readAloud');
    want(($s->{NSPortName} // '') eq 'ReadRead', 'NSPortName is not ReadRead');
    want((($s->{NSMenuItem} // {})->{default} // '') eq 'Read Aloud with ReadRead', 'the Services title is not "Read Aloud with ReadRead"');
    my %send = map { $_ => 1 } @{ $s->{NSSendTypes} // [] };
    want($send{'public.utf8-plain-text'} && $send{'public.url'}, 'NSSendTypes lack public.utf8-plain-text or public.url');
    want(ref($s->{NSRequiredContext}) eq 'HASH', 'no NSRequiredContext dictionary: the item would not be shown');
}
my (@ids, %seen);
for my $t (@{ $p->{CFBundleDocumentTypes} // [] }) {
    my @types = @{ $t->{LSItemContentTypes} // [] };
    want(@types > 0, 'a document type without LSItemContentTypes');
    push @ids, @types;
    $seen{$_}++ for @types;
    want(($t->{LSHandlerRank} // '') eq 'Alternate', "rank of @types is " . ($t->{LSHandlerRank} // 'unset') . ', not Alternate');
    want(($t->{CFBundleTypeRole} // '') eq 'Viewer', "role of @types is not Viewer");
}
want($seen{'public.plain-text'} && $seen{'net.daringfireball.markdown'}, 'plain text or Markdown is not a document type');
my $ats = $p->{NSAppTransportSecurity} // {};
want($ats->{NSAllowsLocalNetworking} && $ats->{NSAllowsArbitraryLoadsInWebContent} && !exists $ats->{NSAllowsArbitraryLoads},
    'ATS is not local networking + web content only (the page reader needs http:// pages, URLSession keeps ATS)');
want(!grep({ $seen{$_} > 1 } keys %seen), 'an identifier is declared twice');
if (@problems) { print join('; ', @problems), "\n"; exit 1; }
printf "region en, localizations [%s], Services item readAloud (plain text + URL), %d document types, all Viewer/Alternate, ATS exempts only the web view\n",
    join(' ', @languages), scalar(@ids);
PERL
)
if plist_summary=$(plutil -convert json -o - "$APP/Contents/Info.plist" 2>&1 | perl -e "$PLIST_CHECK_PL" 2>&1); then
    pass f "Info.plist: $plist_summary"
else
    fail f "Info.plist: $plist_summary"
fi
LPROJ="$APP/Contents/Resources/zh-Hans.lproj"
lproj_problems=""
for table in Localizable ServicesMenu; do
    file="$LPROJ/$table.strings"
    if [ ! -f "$file" ]; then
        lproj_problems="$lproj_problems no $table.strings;"
    elif ! plutil -lint "$file" >/dev/null 2>&1; then
        lproj_problems="$lproj_problems $table.strings fails plutil -lint;"
    elif ! iconv -f UTF-8 -t UTF-8 "$file" >/dev/null 2>&1; then
        lproj_problems="$lproj_problems $table.strings is not UTF-8;"
    fi
done
zh_entries=$(plutil -convert json -o - "$LPROJ/Localizable.strings" 2>/dev/null |
    perl -MJSON::PP -0777 -ne 'print scalar keys %{ decode_json($_) }' 2>/dev/null || echo 0)
[ "${zh_entries:-0}" -gt 0 ] || lproj_problems="$lproj_problems Localizable.strings has no entries;"
zh_title=$(plutil -extract "Read Aloud with ReadRead" raw -o - "$LPROJ/ServicesMenu.strings" 2>/dev/null || true)
[ "$zh_title" = "用 ReadRead 朗读" ] || lproj_problems="$lproj_problems the zh-Hans Services title is \"$zh_title\", not \"用 ReadRead 朗读\";"
[ -s "$TMP_ROOT/bin-strings.txt" ] || strings -a "$BIN" >"$TMP_ROOT/bin-strings.txt" 2>/dev/null || true
grep -q 'readAloud:userData:error:' "$TMP_ROOT/bin-strings.txt" ||
    lproj_problems="$lproj_problems the binary has no readAloud:userData:error: method;"
if [ -z "$lproj_problems" ]; then
    pass f "zh-Hans.lproj: Localizable.strings ($zh_entries entries) and ServicesMenu.strings (\"$zh_title\") lint clean, UTF-8; the binary answers readAloud:userData:error:"
else
    fail f "zh-Hans.lproj / Services:$lproj_problems"
fi
# ── end (f) ──────────────────────────────────────────────────────────

echo ""
echo "=== Smoke test summary ==="
printf '%s\n' "$RESULTS" | sed '/^$/d'
if [ "$FAILURES" != 0 ]; then
    echo "SMOKE TEST FAILED: $FAILURES failing check(s)"
    exit 1
fi
echo "SMOKE TEST PASSED"
