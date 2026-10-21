#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# Builds build/ReadRead.app: the self-contained, ad-hoc signed menu bar app (Apple Silicon, macOS 26+).
#
#   ./scripts/build-app.sh
#
# Steps: Swift release build → bundled CPython + the hashed lock (cached by lock hash) → TTS server →
# models (sha256-verified) → precompiled bytecode → inside-out ad-hoc signing → codesign verify →
# scripts/smoke-test.sh → size summary → install. Any failure stops the build with a non-zero exit
# status.
#
# The bundle is built, signed and smoke-tested in build/.staging/ReadRead.app, and replaces
# build/ReadRead.app only after every check and the smoke test passed. A failed build (at any step,
# preflight included) leaves the previous build/ReadRead.app as it was, says so, and keeps what it
# built as build/ReadRead.app.failed for inspection (not a .app, so Finder will not launch it).
# For a personal-use app, this build plus its smoke test is the release gate: there is no release
# script, zip step or CI.
#
# Cache: build/cache/{downloads,models,runtime/<key>,pip}. The runtime key hashes the Python release
# and tts_server/requirements.lock, so editing the lock rebuilds the runtime; a cached runtime is
# reused only while every file still matches the sha256 manifest written when it was built. Deleting
# build/cache forces fresh, sha256-verified downloads.
#
# Environment overrides:
#   READREAD_SWIFT_BINARY=<path>     Package this prebuilt ReadRead executable instead of running
#                                    `swift build -c release` (for testing the packaging while
#                                    Sources/ is mid-edit). It gets the same checks as a fresh build.
#   READREAD_TTS_SERVER_DIR=<dir>    Bundle the server from <dir> instead of <repo>/tts_server
#                                    (testing only; needs tts_server.py and readread_tts/).
#   READREAD_BUILD_CACHE=<dir>       Cache root (default <repo>/build/cache).
#   READREAD_MODELS_SEED=<dir[:dir]> Directories holding verified model copies to seed the cache from.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

BUILD_DIR="$RR_REPO_DIR/build"
FINAL_APP="$BUILD_DIR/ReadRead.app"
FAILED_APP="$BUILD_DIR/ReadRead.app.failed"
# The bundle keeps its real name while it is staged (smoke-test.sh copies it under that name).
STAGE_DIR="$BUILD_DIR/.staging"
APP="$STAGE_DIR/ReadRead.app"
CONTENTS="$APP/Contents"
RES="$CONTENTS/Resources"
SERVER_SRC="${READREAD_TTS_SERVER_DIR:-$RR_REPO_DIR/tts_server}"
ICON_SRC="$RR_REPO_DIR/Sources/ReadRead/Resources"
ICONS="AppIcon.icns menubar-icon.png menubar-icon@2x.png"
MODEL_CACHE="$RR_CACHE_DIR/models"
SIZE_TARGET=800000000 # bytes (0.8 GB)
START_TIME=$(date +%s)

xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# On any failure: keep the staged bundle as ReadRead.app.failed, put a previous build/ReadRead.app
# back if the install step was interrupted between its two renames, and say what is where.
on_exit() {
    local status=$? previous="$STAGE_DIR/previous-ReadRead.app"
    if [ "$status" != 0 ]; then
        printf '\nBUILD FAILED (exit %s) in step %s\n' "$status" "${RR_STEP_LABEL:-before the first step}" >&2
        if [ -d "$previous" ] && [ ! -e "$FINAL_APP" ]; then mv "$previous" "$FINAL_APP" || true; fi
        if [ -d "$APP" ]; then
            rm -rf "$FAILED_APP"
            if mv "$APP" "$FAILED_APP"; then
                printf '  what this build made is kept for inspection as %s\n' "$FAILED_APP" >&2
            fi
        fi
        if [ -d "$FINAL_APP" ]; then
            printf '  %s was NOT replaced: it is still the previous build (%s)\n' "$FINAL_APP" \
                "$(plutil -extract ReadReadGitDescribe raw -o - "$FINAL_APP/Contents/Info.plist" 2>/dev/null || echo "unknown version")" >&2
        else
            printf '  there is no %s\n' "$FINAL_APP" >&2
        fi
    fi
    rm -rf "$STAGE_DIR"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "=== Building ReadRead.app ==="

# ── 1. Preflight ─────────────────────────────────────────────────────
rr_step 1/10 "Preflight"
rr_require_apple_silicon
rr_require_cmds git curl tar codesign plutil file xattr strings
if [ -z "${READREAD_SWIFT_BINARY:-}" ]; then rr_require_cmds swift; fi
[ -f "$RR_LOCK_FILE" ] || rr_die "missing $RR_LOCK_FILE (run ./scripts/lock-deps.sh)"
rr_check_lock_current "$RR_REPO_DIR/tts_server/requirements.in" "$RR_LOCK_FILE"
[ -f "$SERVER_SRC/tts_server.py" ] || rr_die "missing $SERVER_SRC/tts_server.py"
[ -d "$SERVER_SRC/readread_tts" ] || rr_die "missing $SERVER_SRC/readread_tts/ (the v2 server package)"
for icon in $ICONS; do
    [ -f "$ICON_SRC/$icon" ] || rr_die "missing icon $ICON_SRC/$icon"
done

VERSION_TAG=$(git -C "$RR_REPO_DIR" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null) ||
    rr_die "no v<x.y.z> git tag is reachable from HEAD"
SHORT_VERSION=$(printf '%s' "$VERSION_TAG" | sed -n 's/^v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
[ -n "$SHORT_VERSION" ] || rr_die "latest tag $VERSION_TAG is not v<x.y.z>"
BUILD_NUMBER=$(git -C "$RR_REPO_DIR" rev-list --count HEAD)
GIT_DESCRIBE=$(git -C "$RR_REPO_DIR" describe --tags --always --dirty)
# --dirty ignores untracked files, but SwiftPM compiles every file in Sources/ and the bundle takes
# all of readread_tts/: an untracked file there makes this build dirty as well.
UNTRACKED=$(git -C "$RR_REPO_DIR" status --porcelain --untracked-files=all -- Sources tts_server Package.swift scripts |
    sed -n 's/^?? //p')
if [ -n "$UNTRACKED" ]; then
    case "$GIT_DESCRIBE" in *-dirty) ;; *) GIT_DESCRIBE="$GIT_DESCRIBE-dirty" ;; esac
    rr_warn "untracked files are built into this bundle ($(printf '%s\n' "$UNTRACKED" | wc -l | tr -d ' '), e.g. $(printf '%s\n' "$UNTRACKED" | sed -n '1,3p' | tr '\n' ' '))"
fi
rr_note "version $SHORT_VERSION (build $BUILD_NUMBER, $GIT_DESCRIBE)"

# A fresh staging dir (cp into an existing bundle nests); build/ReadRead.app stays until the install.
rm -rf "$STAGE_DIR" || rr_die "cannot remove $STAGE_DIR"
mkdir -p "$STAGE_DIR" || rr_die "cannot create $STAGE_DIR"

# ── 2. Swift binary ──────────────────────────────────────────────────
rr_step 2/10 "Swift binary"
if [ -n "${READREAD_SWIFT_BINARY:-}" ]; then
    BIN="$READREAD_SWIFT_BINARY"
    rr_note "using prebuilt binary (READREAD_SWIFT_BINARY): $BIN"
else
    (cd "$RR_REPO_DIR" && swift build -c release --product ReadRead)
    BIN="$(cd "$RR_REPO_DIR" && swift build -c release --show-bin-path)/ReadRead"
fi
[ -f "$BIN" ] && [ -x "$BIN" ] || rr_die "Swift binary not found or not executable: $BIN"
BIN_TYPE=$(file -b "$BIN")
case "$BIN_TYPE" in
*"Mach-O 64-bit executable arm64"*) ;;
*) rr_die "$BIN is not an arm64 Mach-O executable: $BIN_TYPE" ;;
esac
# SwiftPM's resource accessor (Bundle.module) looks for ReadRead_ReadRead.bundle and falls back to
# this machine's .build path, so it fatalErrors on any other Mac (audit R5-01). The app must load
# its icons from Bundle.main; this bundle ships no ReadRead_ReadRead.bundle.
# (strings goes to a file first: `strings | grep -q` can lose the match to SIGPIPE under pipefail.)
BIN_STRINGS="$STAGE_DIR/swift-binary-strings.txt"
strings -a "$BIN" >"$BIN_STRINGS" || rr_die "strings failed on $BIN"
if grep -F -q -e 'ReadRead_ReadRead.bundle' -e "$RR_REPO_DIR/.build" "$BIN_STRINGS"; then
    rm -f "$BIN_STRINGS"
    rr_die "$BIN references SwiftPM's resource bundle (ReadRead_ReadRead.bundle / .build path).
  Bundle.module crashes outside this checkout; load resources from Bundle.main instead."
fi
rm -f "$BIN_STRINGS"
rr_note "ok: $BIN_TYPE"

# ── 3. Python runtime (cached by Python release + lock hash) ─────────
rr_step 3/10 "Python runtime"
TARBALL=$(rr_python_tarball)
LOCK_SHA=$(rr_sha256 "$RR_LOCK_FILE")
RUNTIME_KEY=$(rr_sha256_string "python=$RR_PY_VERSION+$RR_PY_RELEASE/$RR_PY_SHA256 lock=$LOCK_SHA sdist=$RR_SDIST_PACKAGES recipe=$RR_RUNTIME_RECIPE" | cut -c1-16)
RUNTIME="$RR_CACHE_DIR/runtime/$RUNTIME_KEY"
# A cached runtime is reused only while every file matches the manifest written when it was built.
if [ -f "$RUNTIME/.complete" ]; then
    if [ ! -f "$RUNTIME/.manifest" ]; then
        rr_warn "cached runtime $RUNTIME_KEY has no manifest (built by an older build-app.sh): rebuilding it"
        rm -rf "$RUNTIME"
    elif ! rr_tree_manifest "$RUNTIME/python" >"$STAGE_DIR/runtime-manifest.txt"; then
        rr_warn "cannot hash cached runtime $RUNTIME_KEY: rebuilding it"
        rm -rf "$RUNTIME"
    elif ! cmp -s "$RUNTIME/.manifest" "$STAGE_DIR/runtime-manifest.txt"; then
        rr_warn "cached runtime $RUNTIME_KEY changed since it was built; rebuilding it. First differences:"
        { diff "$RUNTIME/.manifest" "$STAGE_DIR/runtime-manifest.txt" || true; } |
            sed -n 's/^\([<>]\) [0-9a-f]* *\(.*\)/    \1 \2/p' | sed -n '1,8p' >&2
        rm -rf "$RUNTIME"
    fi
fi
if [ -f "$RUNTIME/.complete" ]; then
    rr_note "cached runtime $RUNTIME_KEY (CPython $RR_PY_VERSION, lock ${LOCK_SHA:0:12}), every file matches its manifest"
else
    rr_note "building runtime $RUNTIME_KEY (CPython $RR_PY_VERSION, lock ${LOCK_SHA:0:12})"
    rm -rf "$RUNTIME" "$RUNTIME.partial"
    mkdir -p "$RUNTIME.partial"
    rr_extract_python "$TARBALL" "$RUNTIME.partial/python"
    rr_install_lock "$RUNTIME.partial/python/bin/python3" "$RR_LOCK_FILE" --no-compile
    rr_check_runtime_imports "$RUNTIME.partial/python/bin/python3"
    rr_tree_manifest "$RUNTIME.partial/python" >"$RUNTIME.partial/.manifest" || rr_die "cannot hash the new runtime"
    printf 'python=%s+%s\nlock_sha256=%s\nbuilt=%s\n' "$RR_PY_VERSION" "$RR_PY_RELEASE" "$LOCK_SHA" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$RUNTIME.partial/.complete"
    mv "$RUNTIME.partial" "$RUNTIME"
    # Runtimes for other lock versions are dead weight now.
    for old in "$RR_CACHE_DIR"/runtime/*; do
        if [ "$old" != "$RUNTIME" ]; then rm -rf "$old"; fi
    done
fi
if [ -d "$RR_CACHE_DIR/python" ]; then
    rr_note "note: $RR_CACHE_DIR/python is the pre-lock runtime of older builds; nothing uses it now (safe to delete)"
fi

# ── 4. Models ────────────────────────────────────────────────────────
rr_step 4/10 "Models"
rr_provision_models "$MODEL_CACHE"

# ── 5. Assemble the bundle ───────────────────────────────────────────
rr_step 5/10 "Assembling the bundle in $APP"
mkdir -p "$CONTENTS/MacOS" "$RES"
cp "$BIN" "$CONTENTS/MacOS/ReadRead"
chmod 755 "$CONTENTS/MacOS/ReadRead"

cat >"$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>ReadRead</string>
    <key>CFBundleDisplayName</key>
    <string>ReadRead</string>
    <key>CFBundleIdentifier</key>
    <string>com.readread.app</string>
    <key>CFBundleShortVersionString</key>
    <string>$(xml_escape "$SHORT_VERSION")</string>
    <key>CFBundleVersion</key>
    <string>$(xml_escape "$BUILD_NUMBER")</string>
    <key>ReadReadGitDescribe</key>
    <string>$(xml_escape "$GIT_DESCRIBE")</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>ReadRead</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>$RR_MIN_MACOS</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
        <!-- The page reader's web view (LocalExtractor) opens http:// pages as a browser does;
             without this, ATS refuses them (NSURLErrorDomain -1022) and they go to defuddle.md.
             URLSession (defuddle.md, the TTS server on 127.0.0.1) stays under ATS. -->
        <key>NSAllowsArbitraryLoadsInWebContent</key>
        <true/>
    </dict>
    <!-- v0.4.0 UI (P5): localizations, the Services item, the document types. -->
    <!-- English is the development language; zh-Hans.lproj holds the translations (see the copy step below). -->
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>zh-Hans</string>
    </array>
    <!-- Services: AppDelegate.readAloud(_:userData:error:) reads the selected text or link aloud.
         NSRequiredContext is an empty dictionary (no filtering): without the key the system registers
         the service but does not show it in the Services menu. zh-Hans.lproj/ServicesMenu.strings
         translates the title. -->
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key>
            <dict>
                <key>default</key>
                <string>Read Aloud with ReadRead</string>
            </dict>
            <key>NSMessage</key>
            <string>readAloud</string>
            <key>NSPortName</key>
            <string>ReadRead</string>
            <key>NSSendTypes</key>
            <array>
                <string>public.utf8-plain-text</string>
                <string>public.url</string>
            </array>
            <key>NSRequiredContext</key>
            <dict/>
        </dict>
    </array>
    <!-- One entry per ReadableFileType identifier (InfoPlistTests keeps them equal), rank Alternate:
         ReadRead is listed under Open With and never becomes the default app. -->
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Plain Text</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array><string>public.plain-text</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Markdown</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array><string>net.daringfireball.markdown</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>HTML</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array><string>public.html</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Rich Text</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array><string>public.rtf</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Rich Text with Attachments</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array><string>com.apple.rtfd</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Word Document</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array><string>org.openxmlformats.wordprocessingml.document</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Word 97-2004 Document</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array><string>com.microsoft.word.doc</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>OpenDocument Text</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array><string>org.oasis-open.opendocument.text</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>PDF Document</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array><string>com.adobe.pdf</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>EPUB Book</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array><string>org.idpf.epub-container</string></array>
        </dict>
    </array>
    <!-- end v0.4.0 UI (P5) -->
</dict>
</plist>
PLIST
plutil -lint "$CONTENTS/Info.plist" >/dev/null
rr_note "Info.plist: $SHORT_VERSION ($BUILD_NUMBER), $GIT_DESCRIBE, macOS >= $RR_MIN_MACOS"

for icon in $ICONS; do
    cp "$ICON_SRC/$icon" "$RES/$icon"
done

# ── v0.4.0 UI (P5): localizations ───────────────────────────────────
# Sources/ReadRead/Resources/<language>.lproj/*.strings → Contents/Resources/<language>.lproj/, where
# Bundle.main finds them (no SwiftPM resources). English needs no folder: it is the development
# language, so a lookup that finds nothing shows the key. Each file must lint as a property list.
LPROJ_SRC="$RR_REPO_DIR/Sources/ReadRead/Resources"
[ -f "$LPROJ_SRC/zh-Hans.lproj/Localizable.strings" ] ||
    rr_die "missing $LPROJ_SRC/zh-Hans.lproj/Localizable.strings (the Chinese UI strings)"
LPROJ_COPIED=""
for lproj in "$LPROJ_SRC"/*.lproj; do
    [ -d "$lproj" ] || continue
    lproj_name=$(basename "$lproj")
    mkdir -p "$RES/$lproj_name"
    for strings in "$lproj"/*.strings; do
        [ -f "$strings" ] || continue
        plutil -lint "$strings" >/dev/null || rr_die "$strings is not a valid strings file (plutil -lint)"
        cp "$strings" "$RES/$lproj_name/"
        LPROJ_COPIED="$LPROJ_COPIED $lproj_name/$(basename "$strings")"
    done
done
rr_note "localizations:$LPROJ_COPIED"
# ── end v0.4.0 UI (P5) ───────────────────────────────────────────────

# Python: the statically linked interpreter plus lib/python3.12 (libpython3.12.dylib, Tcl/Tk,
# headers and the pip-generated bin/ scripts are not needed to run the server).
PYDST="$RES/python"
mkdir -p "$PYDST/bin" "$PYDST/lib"
cp -c "$RUNTIME/python/bin/python3.12" "$PYDST/bin/python3.12" 2>/dev/null ||
    cp "$RUNTIME/python/bin/python3.12" "$PYDST/bin/python3.12"
ln -s python3.12 "$PYDST/bin/python3"
cp -cR "$RUNTIME/python/lib/python3.12" "$PYDST/lib/" 2>/dev/null ||
    cp -R "$RUNTIME/python/lib/python3.12" "$PYDST/lib/"
STDLIB="$PYDST/lib/python3.12"
SITE="$STDLIB/site-packages"
# Contract exclusions: packaging tools, Tk/IDLE/turtle demos, test suites, sympy/mpmath (declared
# by onnxruntime, never imported at runtime), stale bytecode (recompiled below) and Finder files.
rm -rf "$STDLIB/ensurepip" "$STDLIB/idlelib" "$STDLIB/tkinter" "$STDLIB/turtledemo" \
    "$STDLIB"/lib-dynload/_tkinter.*.so
rm -rf "$SITE"/pip "$SITE"/pip-*.dist-info "$SITE"/setuptools "$SITE"/setuptools-*.dist-info \
    "$SITE"/_distutils_hack "$SITE"/distutils-precedence.pth "$SITE"/pkg_resources \
    "$SITE"/sympy "$SITE"/sympy-*.dist-info "$SITE"/isympy.py "$SITE"/mpmath "$SITE"/mpmath-*.dist-info
find "$PYDST" -type d \( -name test -o -name tests -o -name __pycache__ \) -prune -exec rm -rf {} +
find "$PYDST" -type f \( -name .DS_Store -o -name '*.pyc' -o -name '*.pyo' \) -delete
# Dead weight no code path can load (keeps the bundle under the 0.8 GB target):
# - onnxruntime's C API library (the Python binding embeds ORT and never links or opens it);
# - jieba's paddle-only LAC model (paddle is not installed);
# - misaki's other languages and their data (misaki.zh, misaki.en and misaki.espeak import none of
#   them; misaki.ja would need pyopenjtalk, also absent);
# - espeak-ng dictionaries other than en_dict: espeak only ever reads English (misaki's en-us/en-gb
#   fallback for out-of-vocabulary words, also inside Chinese text). phondata, phonindex, phontab,
#   intonations, lang/ and voices/ stay.
MISAKI_UNUSED="ja.py cutlet.py num2kana.py ko.py he.py vi.py g2pkc vi_cleaner data/ja_words.txt
data/vi_acronyms.json data/vi_symbols.json data/vi_teencode.json"
ESPEAK_DATA="$SITE/espeakng_loader/espeak-ng-data"
rm -rf "$SITE"/onnxruntime/capi/libonnxruntime.*.dylib "$SITE"/jieba/lac_small
for p in $MISAKI_UNUSED; do rm -rf "${SITE:?}/misaki/$p"; done
[ -f "$ESPEAK_DATA/en_dict" ] || rr_die "no en_dict in $ESPEAK_DATA (did the espeakng-loader layout change?)"
find "$ESPEAK_DATA" -maxdepth 1 -type f -name '*_dict' ! -name en_dict -delete
# Folders that sloppy wheels leave at the top of site-packages: duplicate sources and tests under
# build/ (cn2an, proces), screenshots and examples (cn2an: src/, example/), docs (phonemizer: docs/).
# They would also shadow `import build` etc. Each is removed only if its RECORD owners are those wheels.
STRAY_DIRS="build src example docs"
STRAY_OWNERS="cn2an proces phonemizer"
for stray in $STRAY_DIRS; do
    [ -e "$SITE/$stray" ] || continue
    owners=$(grep -l -e "^$stray/" "$SITE"/*.dist-info/RECORD | sed 's|.*/\([^/]*\)-[^-/]*\.dist-info/RECORD$|\1|' | sort -u || true)
    [ -n "$owners" ] || rr_die "$SITE/$stray is in no RECORD: check what installed it before bundling or deleting it"
    for owner in $owners; do
        case " $STRAY_OWNERS " in
        *" $owner "*) ;;
        *) rr_die "$SITE/$stray holds files of $owner, not only of the wheels known to leave stray folders ($STRAY_OWNERS): check it before bundling or deleting it" ;;
        esac
    done
    rm -rf "${SITE:?}/$stray"
done
rr_note "python: CPython $RR_PY_VERSION + $(find "$SITE" -maxdepth 1 -name '*.dist-info' | wc -l | tr -d ' ') distributions"

# TTS server: tts_server.py + readread_tts/ (with lexicon_zh.json), no tests.
mkdir -p "$RES/tts_server"
cp "$SERVER_SRC/tts_server.py" "$RES/tts_server/tts_server.py"
cp -R "$SERVER_SRC/readread_tts" "$RES/tts_server/readread_tts"
find "$RES/tts_server" -type d \( -name tests -o -name test -o -name __pycache__ -o -name .pytest_cache \) \
    -prune -exec rm -rf {} +
find "$RES/tts_server" -type f \( -name .DS_Store -o -name '*.pyc' -o -name 'test_*.py' -o -name conftest.py \) -delete
rr_note "tts_server: $(find "$RES/tts_server" -type f | wc -l | tr -d ' ') files from $SERVER_SRC"

mkdir -p "$RES/models"
for name in $(rr_model_names); do
    rr_clone_file "$MODEL_CACHE/$name" "$RES/models/$name" >/dev/null
done
rr_note "models: $(rr_model_names | tr '\n' ' ')"

# ── Defuddle page reader (download, verify, copy) ────────────────────
# The pinned npm build (scripts/lib/versions.sh, RR_DEFUDDLE_*) the app injects into an offscreen
# web view to read pages on this Mac: the tarball is cached in build/cache/downloads (sha256 and npm's
# sha512 integrity checked), and Contents/Resources/defuddle/ gets exactly defuddle.full.js and
# LICENSE, each checked against its pinned sha256. smoke-test.sh checks them again in the bundle.
rr_require_cmds openssl
# shellcheck source=lib/defuddle.sh
. "$SCRIPT_DIR/lib/defuddle.sh"
rr_install_defuddle "$RES/defuddle"
rr_defuddle_installed "$RES/defuddle" || rr_die "$RES/defuddle does not hold exactly the pinned Defuddle files"
rr_note "defuddle: $RR_DEFUDDLE_VERSION ($(cd "$RES/defuddle" && find . -type f | sed 's|^\./||' | sort | tr '\n' ' '))"
# ── end of the Defuddle block ────────────────────────────────────────

# ── 6. Precompile bytecode with the bundled interpreter ──────────────
# unchecked-hash .pyc files stay valid whatever the mtimes (zip/copy), and the server runs with -B,
# so nothing is ever written into the signed bundle at runtime.
rr_step 6/10 "Precompiling bytecode"
# compileall -j 0 needs process pools, which some sandboxes forbid (sysconf SC_SEM_NSEMS_MAX).
JOBS=1
if "$PYDST/bin/python3" -I -B -c 'import os; os.sysconf("SC_SEM_NSEMS_MAX")' 2>/dev/null; then JOBS=0; fi
# -B: the modules compileall imports itself would otherwise get timestamp .pyc files first, which
# compileall then skips as up to date; -f rewrites everything in unchecked-hash mode regardless.
"$PYDST/bin/python3" -I -B -W ignore -m compileall -f -q -j "$JOBS" --invalidation-mode unchecked-hash \
    "$STDLIB" "$RES/tts_server"
rr_note "$(find "$RES" -name '*.pyc' | wc -l | tr -d ' ') .pyc files (unchecked-hash)"

# ── 7. Bundle checks ─────────────────────────────────────────────────
rr_step 7/10 "Checking bundle contents"
problems=$(
    find "$APP" -name 'ReadRead_ReadRead.bundle' -o -name '.DS_Store' -o -name '*.app' ! -path "$APP"
    for p in pip setuptools pkg_resources _distutils_hack sympy mpmath; do
        if [ -e "$SITE/$p" ]; then echo "$SITE/$p"; fi
    done
    for d in ensurepip idlelib tkinter turtledemo; do
        if [ -e "$STDLIB/$d" ]; then echo "$STDLIB/$d"; fi
    done
    for p in $STRAY_DIRS; do
        if [ -e "$SITE/$p" ]; then echo "$SITE/$p"; fi
    done
    for p in $MISAKI_UNUSED; do
        if [ -e "$SITE/misaki/$p" ]; then echo "$SITE/misaki/$p"; fi
    done
    find "$ESPEAK_DATA" -maxdepth 1 -name '*_dict' ! -name en_dict
    find "$RES/tts_server" -name 'test*' -o -name 'conftest.py'
    find "$CONTENTS" -mindepth 1 -maxdepth 1 ! -name MacOS ! -name Resources ! -name Info.plist
)
[ -z "$problems" ] || rr_die "unexpected files in the bundle:
$problems"
for f in en_dict phondata phonindex phontab intonations; do
    [ -f "$ESPEAK_DATA/$f" ] || rr_die "espeak-ng data is incomplete: no $ESPEAK_DATA/$f"
done
# Every top-level site-packages entry belongs to an installed distribution (its RECORD lists it);
# besides those only CPython's README.txt and the __pycache__ that step 6 made for top-level modules.
"$PYDST/bin/python3" -I -B -c '
import csv, pathlib, sys
site = pathlib.Path(sys.argv[1])
owned = {"README.txt", "__pycache__"}
for record in site.glob("*.dist-info/RECORD"):
    with record.open(newline="", encoding="utf-8") as f:
        owned.update(row[0].split("/", 1)[0] for row in csv.reader(f) if row and not row[0].startswith(".."))
loose = sorted(p.name for p in site.iterdir() if p.name not in owned and not p.name.endswith(".dist-info"))
if loose:
    sys.exit("site-packages entries no installed distribution owns: %s" % loose)
' "$SITE" || rr_die "site-packages check failed"
# Every .py needs its unchecked-hash .pyc (PEP 552 flags == 1), or Python would try to write one.
"$PYDST/bin/python3" -I -B -c '
import importlib.util, pathlib, sys
missing, wrong = [], []
for root in sys.argv[1:]:
    for py in pathlib.Path(root).rglob("*.py"):
        pyc = pathlib.Path(importlib.util.cache_from_source(str(py)))
        if not pyc.is_file():
            missing.append(str(py))
        elif int.from_bytes(pyc.read_bytes()[4:8], "little") != 1:
            wrong.append(str(pyc))
for label, items in (("no .pyc", missing), ("not unchecked-hash", wrong)):
    if items:
        sys.exit("%d sources %s, e.g. %s" % (len(items), label, items[:3]))
' "$STDLIB" "$RES/tts_server" || rr_die "bytecode check failed"
rr_check_runtime_imports "$PYDST/bin/python3"
rr_note "ok: no SwiftPM resource bundle, no Finder files, no excluded packages or stray folders, English-only espeak data, all .py precompiled"

# ── 8. Ad-hoc signing, inside out (no --deep) ────────────────────────
rr_step 8/10 "Signing (ad-hoc, inside out)"
xattr -cr "$APP"
MACHO_LIST="$STAGE_DIR/macho-files.txt"
find "$RES" -type f ! -name '*.py' ! -name '*.pyc' ! -name '*.json' -print0 |
    xargs -0 file --mime-type | sed -n 's/: *application\/x-mach-binary$//p' >"$MACHO_LIST"
[ -s "$MACHO_LIST" ] || rr_die "found no Mach-O files under $RES (expected the interpreter and extensions)"
SIGN_LOG="$STAGE_DIR/codesign.log"
if ! tr '\n' '\0' <"$MACHO_LIST" | xargs -0 codesign --force --sign - 2>"$SIGN_LOG"; then
    cat "$SIGN_LOG" >&2
    rr_die "codesign failed on a nested Mach-O file"
fi
rr_note "signed $(wc -l <"$MACHO_LIST" | tr -d ' ') Mach-O files under Contents/Resources"
codesign --force --sign - "$APP"
rm -f "$MACHO_LIST" "$SIGN_LOG"
rr_note "signed $APP"

# ── 9. Verify the signature ──────────────────────────────────────────
rr_step 9/10 "Verifying signature"
codesign --verify --strict --deep --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | grep -E '^(Identifier|Format|Signature|CodeDirectory)' | sed 's/^/  /'

# ── 10. Smoke test ───────────────────────────────────────────────────
rr_step 10/10 "Smoke test"
SMOKE_STATUS=0
"$SCRIPT_DIR/smoke-test.sh" "$APP" || SMOKE_STATUS=$?

# ── Size summary ─────────────────────────────────────────────────────
echo ""
echo "=== Size summary (logical bytes, MB = 10^6) ==="
TOTAL=$(rr_tree_bytes "$APP")
PY_TOTAL=$(rr_tree_bytes "$PYDST")
SITE_TOTAL=$(rr_tree_bytes "$SITE")
MODELS_TOTAL=$(rr_tree_bytes "$RES/models")
PYC_TOTAL=$(find "$APP" -name '*.pyc' -print0 | xargs -0 stat -f %z | awk '{s += $1} END {printf "%d", s}')
row() { printf '  %-44s %9s MB\n' "$1" "$(rr_mb "$2")"; }
row "ReadRead.app total" "$TOTAL"
row "Contents/MacOS/ReadRead" "$(rr_size "$CONTENTS/MacOS/ReadRead")"
row "Resources/python (runtime total)" "$PY_TOTAL"
row "  bin/python3.12 (static interpreter)" "$(rr_size "$PYDST/bin/python3.12")"
row "  stdlib (lib/python3.12 minus site-packages)" "$((PY_TOTAL - SITE_TOTAL - $(rr_size "$PYDST/bin/python3.12")))"
row "  site-packages" "$SITE_TOTAL"
row "  of which .pyc (whole bundle)" "$PYC_TOTAL"
row "Resources/tts_server" "$(rr_tree_bytes "$RES/tts_server")"
row "Resources/models" "$MODELS_TOTAL"
for name in $(rr_model_names); do
    row "  $name" "$(rr_size "$RES/models/$name")"
done
echo "  Top 10 site-packages entries:"
for entry in "$SITE"/*; do
    if [ -d "$entry" ]; then
        printf '%s %s\n' "$(rr_tree_bytes "$entry")" "$(basename "$entry")"
    fi
done | sort -rn | sed -n '1,10p' | while read -r bytes name; do
    printf '    %-42s %9s MB\n' "$name" "$(rr_mb "$bytes")"
done
if [ "$TOTAL" -gt "$SIZE_TARGET" ]; then
    rr_warn "bundle is $(rr_mb "$TOTAL") MB, over the $(rr_mb "$SIZE_TARGET") MB target"
else
    rr_note "within the $(rr_mb "$SIZE_TARGET") MB target"
fi
echo "  build time: $(($(date +%s) - START_TIME)) s"

if [ "$SMOKE_STATUS" != 0 ]; then
    rr_die "smoke test FAILED (exit $SMOKE_STATUS): the bundle is not fit to use or ship"
fi

# ── Install: replace build/ReadRead.app (two renames; on_exit undoes a half-done swap) ──
RR_STEP_LABEL="install"
echo ""
PREVIOUS="$STAGE_DIR/previous-ReadRead.app"
if [ -e "$FINAL_APP" ]; then mv "$FINAL_APP" "$PREVIOUS" || rr_die "cannot move the previous $FINAL_APP aside"; fi
mv "$APP" "$FINAL_APP" || rr_die "cannot move the new bundle to $FINAL_APP"
rm -rf "$FAILED_APP" # an earlier failed build's bundle is out of date now
echo "=== Build complete: $FINAL_APP ($SHORT_VERSION, $GIT_DESCRIBE) ==="
