#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# Runs the project's checks and prints a summary table; exits 1 when any check failed.
#
#   scripts/check.sh [--fast] [--smoke]
#
#   1 shellcheck   shellcheck -x on scripts/**/*.sh and tools/**/*.sh (skipped when it is not installed)
#   2 locks        scripts/lock-deps.sh --check (needs uv and pypi.org)
#   3 asr-lock     tools/asr_eval/lock.sh --check (the same for the ASR evaluation tool's venv)
#   4 pytest       tts_server/tests with the dev environment's python; the model tests run when
#                  READREAD_MODELS_DIR is set or $READREAD_HOME/models holds the four Kokoro files
#                  (under a TMPDIR too deep for espeak-ng's 150-byte cache path, with a base temp dir in /tmp)
#   5 swift-build  swift build --build-tests -Xswiftc -warnings-as-errors; any "warning:" fails it
#   6 swift-test   swift test --skip-build (the build above)
#   7 build-app    --smoke only: scripts/build-app.sh, which ends with the smoke test
#
#   --fast   skip the model tests (pytest runs without READREAD_MODELS_DIR)
#   --smoke  add build-app (a release build of build/ReadRead.app, about 0.8 GB; READREAD_BUILD_CACHE applies)
#
# The READREAD_* overrides apply as everywhere: READREAD_HOME (default ~/.readread) is the dev environment,
# READREAD_MODELS_DIR the models for pytest, READREAD_BUILD_CACHE the build cache. READREAD_LOG_DIR,
# READREAD_CACHE_DIR, READREAD_USER_LEXICON, READREAD_POSITIONS_FILE and READREAD_HQ_HOME that are unset point
# into a temp dir for the run, so no check reaches the real ~/Library/{Logs,Caches,Application Support}/ReadRead.
# Each check's output goes to build/check/<check>.log; a failed check shows its last lines.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
REPO="$RR_REPO_DIR"
LOG_DIR="$REPO/build/check"

FAST=0
SMOKE=0
while [ $# -gt 0 ]; do
    case "$1" in
    --fast) FAST=1 ;;
    --smoke) SMOKE=1 ;;
    -h | --help)
        sed -n '3,24s/^# \{0,1\}//p' "$0"
        exit 0
        ;;
    *)
        printf 'check.sh: unknown argument: %s (try --help)\n' "$1" >&2
        exit 2
        ;;
    esac
    shift
done

if [ "${READREAD_HOME+set}" = set ] && [ -z "$READREAD_HOME" ]; then
    rr_die "READREAD_HOME is set but empty; unset it for ~/.readread, or give it a path"
fi
DEV_HOME="${READREAD_HOME:-${HOME:?}/.readread}"
# The checks run in the repo (run_check cds there): a relative path would name another place than the
# caller's, so every path override must be absolute (as setup.sh asks of READREAD_HOME).
for var in READREAD_HOME READREAD_MODELS_DIR READREAD_LOG_DIR READREAD_CACHE_DIR READREAD_USER_LEXICON \
    READREAD_POSITIONS_FILE READREAD_HQ_HOME; do
    case "${!var:-/}" in
    /*) ;;
    *) rr_die "$var must be an absolute path (got '${!var}')" ;;
    esac
done

# Unset runtime locations point into a temp dir (removed at exit).
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/rr-check.XXXXXX") || rr_die "cannot create a temp dir"
PYTEST_TMP=""
trap 'rm -rf "$SCRATCH" ${PYTEST_TMP:+"$PYTEST_TMP"}' EXIT
SCRATCH_VARS=""
default_path() { # <variable> <path in the temp dir>
    if [ -z "${!1:-}" ]; then
        export "$1=$SCRATCH/$2"
        SCRATCH_VARS="$SCRATCH_VARS $1"
    fi
}
default_path READREAD_LOG_DIR logs
default_path READREAD_CACHE_DIR cache
default_path READREAD_USER_LEXICON lexicon_zh.json
default_path READREAD_POSITIONS_FILE positions.json
default_path READREAD_HQ_HOME hq
mkdir -p "$LOG_DIR" || rr_die "cannot create $LOG_DIR"

# ── Results (bash 3.2: parallel indexed arrays) ──────────────────────
NAMES=()
RESULTS=()
TIMES=()
DETAILS=()
HEADED=""
header() { # <check> [command...]: the check's heading, printed once per check
    HEADED="$1"
    printf '\n==> %s' "$1"
    shift
    if [ $# -gt 0 ]; then
        printf ':'
        printf ' %s' "$@"
    fi
    printf '\n'
}
record() { # <check> <ok|FAIL|skip> <seconds or -> <detail>
    if [ "$HEADED" != "$1" ]; then header "$1"; fi
    NAMES+=("$1")
    RESULTS+=("$2")
    TIMES+=("$3")
    DETAILS+=("$4")
    printf '    %s %s\n' "$2" "$4"
}
duration() { # <seconds>: 75 -> 1m15s
    if [ "$1" = - ]; then
        echo -
    elif [ "$1" -ge 60 ]; then
        printf '%dm%02ds\n' $(($1 / 60)) $(($1 % 60))
    else
        printf '%ds\n' "$1"
    fi
}

# run_check <check> <command...>: runs the command in the repo with its output in build/check/<check>.log;
# sets STATUS, ELAPSED and LOG. A failure shows the log's last lines.
run_check() {
    local start
    LOG="$LOG_DIR/$1.log"
    header "$@"
    shift
    start=$SECONDS
    STATUS=0
    (cd "$REPO" && "$@") >"$LOG" 2>&1 || STATUS=$?
    ELAPSED=$((SECONDS - start))
    if [ "$STATUS" != 0 ]; then
        tail -n 25 "$LOG" | sed 's/^/    | /'
    fi
}
last_line() { grep -v '^[[:space:]]*$' "$1" | tail -n 1 | cut -c1-90; }

# ── The checks ───────────────────────────────────────────────────────
check_shellcheck() {
    local files=() f n
    if ! command -v shellcheck >/dev/null 2>&1; then
        record shellcheck skip - "shellcheck is not installed (brew install shellcheck)"
        return
    fi
    while IFS= read -r f; do files+=("$f"); done < <(cd "$REPO" && find scripts tools -name '*.sh' -type f | LC_ALL=C sort)
    run_check shellcheck shellcheck -x "${files[@]}"
    if [ "$STATUS" = 0 ]; then
        record shellcheck ok "$ELAPSED" "${#files[@]} files clean"
    else
        n=$(grep -c '^In .* line [0-9]*:' "$LOG" || true)
        record shellcheck FAIL "$ELAPSED" "$n findings in ${#files[@]} files"
    fi
}

check_lock() { # <check> <script>
    run_check "$1" "$2" --check
    if [ "$STATUS" = 0 ]; then
        record "$1" ok "$ELAPSED" "$(last_line "$LOG")"
    else
        record "$1" FAIL "$ELAPSED" "$( (grep -E 'DRIFT|ERROR|error' "$LOG" || last_line "$LOG") | head -n 1 | cut -c1-90)"
    fi
}

check_pytest() {
    local py="$DEV_HOME/env/bin/python3" models="" name summary tmp user args
    if [ ! -x "$py" ]; then
        record pytest FAIL - "no dev environment at $DEV_HOME (run ./scripts/setup.sh)"
        return
    fi
    if [ "$FAST" = 0 ]; then
        if [ -n "${READREAD_MODELS_DIR:-}" ]; then
            models="$READREAD_MODELS_DIR"
        else
            models="$DEV_HOME/models"
            for name in $(rr_model_names); do
                if [ ! -f "$models/$name" ]; then models=""; fi
            done
        fi
    fi
    args=(-B -m pytest -q -p no:cacheprovider)
    # The test servers' cache dirs are in pytest's temp dir, and a server refuses one whose espeak-ng-data
    # link would not fit espeak-ng's path buffer (150 bytes). The deepest is
    # <TMPDIR>/pytest-of-<user>/pytest-<n>/s<n>/cache/espeak-ng-data (conftest.py's server_dir), so under a
    # deeper TMPDIR (sandboxes) pytest gets a short base temp dir in /tmp, as smoke-test.sh does for its own.
    tmp=$(cd "${TMPDIR:-/tmp}" && pwd -P) || tmp="${TMPDIR:-/tmp}"
    user="${USER:-$(id -un)}"
    if [ $((${#tmp} + ${#user} + 48)) -gt 150 ] && PYTEST_TMP=$(mktemp -d /tmp/rr-pytest.XXXXXX); then
        args+=("--basetemp=$PYTEST_TMP")
    fi
    args+=(tts_server/tests)
    if [ -n "$models" ]; then
        run_check pytest env READREAD_MODELS_DIR="$models" "$py" "${args[@]}"
    else
        run_check pytest env -u READREAD_MODELS_DIR "$py" "${args[@]}"
    fi
    # No summary line (pytest could not start, or a conftest failed to import): the exit status instead.
    summary=$({ grep -E '(passed|failed|error|skipped).* in [0-9.]+s' "$LOG" || true; } | tail -n 1 |
        sed -E 's/=//g; s/ in [0-9.]+s.*//; s/^ *//')
    summary="${summary:-no pytest summary, exit $STATUS}"
    if [ -n "$models" ]; then
        summary="$summary; with models"
    elif [ "$FAST" = 1 ]; then
        summary="$summary; model tests skipped (--fast)"
    else
        summary="$summary; no models (set READREAD_MODELS_DIR)"
    fi
    if [ -n "$PYTEST_TMP" ]; then summary="$summary; base temp in /tmp"; fi
    if [ "$STATUS" = 0 ]; then record pytest ok "$ELAPSED" "$summary"; else record pytest FAIL "$ELAPSED" "$summary"; fi
}

BUILD_OK=0
check_swift_build() {
    local warnings
    if ! command -v swift >/dev/null 2>&1; then
        record swift-build FAIL - "swift is not installed (Xcode or the Command Line Tools)"
        return
    fi
    run_check swift-build swift build --build-tests -Xswiftc -warnings-as-errors
    warnings=$(grep -c 'warning:' "$LOG" || true)
    if [ "$STATUS" = 0 ] && [ "$warnings" = 0 ]; then
        BUILD_OK=1
        record swift-build ok "$ELAPSED" "0 warnings"
    elif [ "$STATUS" = 0 ]; then
        grep 'warning:' "$LOG" | head -n 10 | sed 's/^/    | /'
        record swift-build FAIL "$ELAPSED" "$warnings warnings"
    else
        record swift-build FAIL "$ELAPSED" "$(grep -c 'error:' "$LOG" || true) errors, $warnings warnings"
    fi
}

check_swift_test() {
    local summary
    if [ "$BUILD_OK" != 1 ]; then
        record swift-test skip - "the build failed"
        return
    fi
    run_check swift-test swift test --skip-build
    # XCTest's total: "Executed 384 tests, with 2 tests skipped and 0 failures (0 unexpected) in ..."; none
    # when the test process crashed.
    summary=$({ grep -E 'Executed [0-9]+ tests?, with' "$LOG" || true; } | tail -n 1 |
        sed -E 's/.*Executed ([0-9]+) tests?, with ([0-9]+) tests? skipped and ([0-9]+) failures? \(([0-9]+) unexpected\).*/\1 tests, \2 skipped, \3 failures (\4 unexpected)/')
    if [ "$STATUS" = 0 ]; then
        record swift-test ok "$ELAPSED" "${summary:-no XCTest summary}"
    else
        record swift-test FAIL "$ELAPSED" "${summary:-exit $STATUS}"
    fi
}

check_build_app() {
    if [ "$SMOKE" = 0 ]; then
        record build-app skip - "--smoke adds it"
        return
    fi
    run_check build-app ./scripts/build-app.sh
    if [ "$STATUS" = 0 ]; then
        record build-app ok "$ELAPSED" "$(grep '=== Build complete' "$LOG" | tail -n 1 | sed -E 's/=== Build complete: //; s/ ===$//; s#.*/build/#build/#')"
    else
        record build-app FAIL "$ELAPSED" "$( (grep -E '^ERROR|FAIL' "$LOG" || last_line "$LOG") | head -n 1 | cut -c1-90)"
    fi
}

echo "=== ReadRead checks ($REPO) ==="
echo "  dev environment: $DEV_HOME"
if [ -n "$SCRATCH_VARS" ]; then echo "  in a temp dir for this run:$SCRATCH_VARS"; fi
check_shellcheck
check_lock locks ./scripts/lock-deps.sh
check_lock asr-lock ./tools/asr_eval/lock.sh
check_pytest
check_swift_build
check_swift_test
check_build_app

# ── Summary ──────────────────────────────────────────────────────────
failed=0
echo ""
echo "=== Summary (logs in build/check/) ==="
printf '%-12s %-6s %7s  %s\n' check result time detail
i=0
while [ "$i" -lt "${#NAMES[@]}" ]; do
    printf '%-12s %-6s %7s  %s\n' "${NAMES[$i]}" "${RESULTS[$i]}" "$(duration "${TIMES[$i]}")" "${DETAILS[$i]}"
    if [ "${RESULTS[$i]}" = FAIL ]; then failed=$((failed + 1)); fi
    i=$((i + 1))
done
if [ "$failed" = 0 ]; then
    echo "check.sh: PASS"
else
    echo "check.sh: FAIL ($failed of ${#NAMES[@]} checks failed)"
    exit 1
fi
