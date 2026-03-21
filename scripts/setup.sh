#!/bin/bash
set -e

READREAD_DIR="$HOME/.readread"
PYTHON_DIR="$READREAD_DIR/python"
ENV_DIR="$READREAD_DIR/env"
MODEL_DIR="$READREAD_DIR/models"

echo "=== ReadRead Setup ==="
echo ""

# Create directories
mkdir -p "$READREAD_DIR" "$MODEL_DIR"

# ── Step 1: Standalone Python ────────────────────────────────────────
if [ ! -f "$PYTHON_DIR/bin/python3" ]; then
    echo "[1/4] Downloading standalone Python..."

    ARCH=$(uname -m)
    PY_VER="3.12.8"
    RELEASE="20241219"

    case $ARCH in
        arm64)
            URL="https://github.com/indygreg/python-build-standalone/releases/download/${RELEASE}/cpython-${PY_VER}+${RELEASE}-aarch64-apple-darwin-install_only.tar.gz"
            ;;
        x86_64)
            URL="https://github.com/indygreg/python-build-standalone/releases/download/${RELEASE}/cpython-${PY_VER}+${RELEASE}-x86_64-apple-darwin-install_only.tar.gz"
            ;;
        *)
            echo "ERROR: Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac

    TMP_TAR="$READREAD_DIR/python.tar.gz"
    curl -L --progress-bar -o "$TMP_TAR" "$URL"
    tar xzf "$TMP_TAR" -C "$READREAD_DIR/"
    rm -f "$TMP_TAR"

    echo "  Python installed: $PYTHON_DIR/bin/python3"
else
    echo "[1/4] Standalone Python already installed."
fi

# ── Step 2: Virtual environment ──────────────────────────────────────
if [ ! -d "$ENV_DIR" ]; then
    echo "[2/4] Creating virtual environment..."
    "$PYTHON_DIR/bin/python3" -m venv "$ENV_DIR"
    echo "  Venv created: $ENV_DIR"
else
    echo "[2/4] Virtual environment already exists."
fi

# ── Step 3: Python packages ─────────────────────────────────────────
echo "[3/4] Installing Python packages..."
"$ENV_DIR/bin/pip" install --quiet -U pip
"$ENV_DIR/bin/pip" install --quiet -U kokoro-onnx soundfile
echo "  Packages installed."

# ── Step 4: Model files ─────────────────────────────────────────────
NEED_DOWNLOAD=0

if [ ! -f "$MODEL_DIR/kokoro-v1.0.fp16.onnx" ] && \
   [ ! -f "$MODEL_DIR/kokoro-v1.0.onnx" ] && \
   [ ! -f "$MODEL_DIR/kokoro-v1.0.int8.onnx" ]; then
    NEED_DOWNLOAD=1
fi

if [ ! -f "$MODEL_DIR/voices-v1.0.bin" ]; then
    NEED_DOWNLOAD=1
fi

if [ "$NEED_DOWNLOAD" -eq 1 ]; then
    echo "[4/4] Downloading TTS model files..."

    if [ ! -f "$MODEL_DIR/kokoro-v1.0.fp16.onnx" ]; then
        echo "  Downloading kokoro-v1.0.fp16.onnx (~169 MB)..."
        curl -L --progress-bar \
            -o "$MODEL_DIR/kokoro-v1.0.fp16.onnx" \
            "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.fp16.onnx"
    fi

    if [ ! -f "$MODEL_DIR/voices-v1.0.bin" ]; then
        echo "  Downloading voices-v1.0.bin..."
        curl -L --progress-bar \
            -o "$MODEL_DIR/voices-v1.0.bin" \
            "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin"
    fi

    echo "  Model files downloaded."
else
    echo "[4/4] Model files already present."
fi

# ── Copy server script ──────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cp "$SCRIPT_DIR/../tts_server/tts_server.py" "$READREAD_DIR/tts_server.py"

echo ""
echo "=== Setup complete ==="
echo ""
echo "  Python:  $ENV_DIR/bin/python3"
echo "  Models:  $MODEL_DIR"
echo "  Server:  $READREAD_DIR/tts_server.py"
echo ""
echo "Build & run:"
echo "  swift build && swift run ReadRead"
