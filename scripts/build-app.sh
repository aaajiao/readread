#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
CACHE_DIR="$BUILD_DIR/cache"
APP_DIR="$BUILD_DIR/ReadRead.app/Contents"

PY_VER="3.12.8"
PY_RELEASE="20241219"
ARCH=$(uname -m)

echo "=== Building ReadRead.app ==="
echo ""

mkdir -p "$CACHE_DIR" "$APP_DIR/MacOS" "$APP_DIR/Resources/models"

# ── Step 1: Swift binary ─────────────────────────────────────────────
echo "[1/5] Building Swift binary (release)..."
cd "$PROJECT_DIR"
swift build -c release 2>&1 | tail -1
cp .build/release/ReadRead "$APP_DIR/MacOS/ReadRead"
echo "  Done."

# ── Step 2: Info.plist ───────────────────────────────────────────────
echo "[2/5] Writing Info.plist..."
cat > "$APP_DIR/Info.plist" << 'PLIST'
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
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>ReadRead</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST
echo "  Done."

# ── Step 3: Standalone Python ────────────────────────────────────────
PYTHON_CACHE="$CACHE_DIR/python"

if [ ! -f "$PYTHON_CACHE/bin/python3" ]; then
    echo "[3/5] Downloading standalone Python ${PY_VER}..."

    case $ARCH in
        arm64)
            URL="https://github.com/indygreg/python-build-standalone/releases/download/${PY_RELEASE}/cpython-${PY_VER}+${PY_RELEASE}-aarch64-apple-darwin-install_only.tar.gz"
            ;;
        x86_64)
            URL="https://github.com/indygreg/python-build-standalone/releases/download/${PY_RELEASE}/cpython-${PY_VER}+${PY_RELEASE}-x86_64-apple-darwin-install_only.tar.gz"
            ;;
        *)
            echo "ERROR: Unsupported architecture: $ARCH"; exit 1 ;;
    esac

    TMP_TAR="$CACHE_DIR/python.tar.gz"
    curl -L --progress-bar -o "$TMP_TAR" "$URL"
    tar xzf "$TMP_TAR" -C "$CACHE_DIR/"
    rm -f "$TMP_TAR"
    echo "  Downloaded."
else
    echo "[3/5] Standalone Python cached."
fi

# Install packages into the standalone Python
if [ ! -d "$PYTHON_CACHE/lib/python3.12/site-packages/kokoro_onnx" ]; then
    echo "  Installing kokoro-onnx + misaki[zh,ja] + soundfile..."
    "$PYTHON_CACHE/bin/python3" -m pip install --quiet -U pip
    "$PYTHON_CACHE/bin/python3" -m pip install --quiet kokoro-onnx soundfile "misaki[zh,ja]"
    echo "  Packages installed."
else
    echo "  Packages already installed."
fi

# Copy Python into bundle (strip tests, __pycache__, etc. to save space)
echo "  Copying Python into app bundle..."
rm -rf "$APP_DIR/Resources/python"
mkdir -p "$APP_DIR/Resources/python"

# Copy bin
mkdir -p "$APP_DIR/Resources/python/bin"
cp "$PYTHON_CACHE/bin/python3" "$APP_DIR/Resources/python/bin/python3"
cp "$PYTHON_CACHE/bin/python3.12" "$APP_DIR/Resources/python/bin/python3.12" 2>/dev/null || true

# Copy lib (essential parts)
rsync -a \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    --exclude='test/' \
    --exclude='tests/' \
    --exclude='testing/' \
    --exclude='idle_test/' \
    --exclude='tkinter/' \
    --exclude='turtledemo/' \
    --exclude='ensurepip/' \
    --exclude='distutils/' \
    --exclude='pip/' \
    --exclude='pip-*/' \
    --exclude='setuptools/' \
    --exclude='setuptools-*/' \
    --exclude='_distutils_hack/' \
    --exclude='pkg_resources/' \
    "$PYTHON_CACHE/lib/" "$APP_DIR/Resources/python/lib/"

echo "  Done."

# ── Step 4: Model files ─────────────────────────────────────────────
MODEL_CACHE="$CACHE_DIR/models"
mkdir -p "$MODEL_CACHE"

if [ ! -f "$MODEL_CACHE/kokoro-v1.0.fp16.onnx" ]; then
    echo "[4/5] Downloading model: kokoro-v1.0.fp16.onnx (~169 MB)..."
    curl -L --progress-bar \
        -o "$MODEL_CACHE/kokoro-v1.0.fp16.onnx" \
        "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.fp16.onnx"
else
    echo "[4/5] Model file cached."
fi

if [ ! -f "$MODEL_CACHE/voices-v1.0.bin" ]; then
    echo "  Downloading voices-v1.0.bin..."
    curl -L --progress-bar \
        -o "$MODEL_CACHE/voices-v1.0.bin" \
        "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin"
fi

cp "$MODEL_CACHE/kokoro-v1.0.fp16.onnx" "$APP_DIR/Resources/models/"
cp "$MODEL_CACHE/voices-v1.0.bin" "$APP_DIR/Resources/models/"
echo "  Done."

# ── Step 5: TTS server script + sign ────────────────────────────────
echo "[5/5] Finalizing..."
cp "$PROJECT_DIR/tts_server/tts_server.py" "$APP_DIR/Resources/tts_server.py"

# Ad-hoc code sign
codesign --force --deep --sign - "$BUILD_DIR/ReadRead.app" 2>/dev/null

# Summary
APP_SIZE=$(du -sh "$BUILD_DIR/ReadRead.app" | cut -f1)
echo ""
echo "=== Build complete ==="
echo ""
echo "  App:  $BUILD_DIR/ReadRead.app ($APP_SIZE)"
echo ""
echo "  open $BUILD_DIR/ReadRead.app"
