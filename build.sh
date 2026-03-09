#!/bin/bash
set -e

# Local build script for Alphasound image using pi-gen in Docker
# Requires Docker to be installed and running

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIGEN_DIR="$SCRIPT_DIR/.pi-gen"
DEPLOY_DIR="$SCRIPT_DIR/deploy"

echo "=== Alphasound Image Builder ==="
echo ""

# Clone or update pi-gen
if [ -d "$PIGEN_DIR" ]; then
    echo "Updating pi-gen..."
    cd "$PIGEN_DIR"
    git pull
    cd "$SCRIPT_DIR"
else
    echo "Cloning pi-gen..."
    git clone --depth 1 -b arm64 https://github.com/RPi-Distro/pi-gen.git "$PIGEN_DIR"
fi

# Write pi-gen config
cat > "$PIGEN_DIR/config" << 'EOF'
IMG_NAME=alphasound
RELEASE=trixie
TARGET_HOSTNAME=alphasound
FIRST_USER_NAME=alphasound
FIRST_USER_PASSWD=alphasound
ENABLE_SSH=1
LOCALE_DEFAULT=en_US.UTF-8
KEYBOARD_KEYMAP=us
KEYBOARD_LAYOUT="English (US)"
DEPLOY_ZIP=0
DEPLOY_COMPRESSION=none
EOF

# Skip stages 2-5 (we build on stage1 minimal)
touch "$PIGEN_DIR/stage2/SKIP" "$PIGEN_DIR/stage3/SKIP" "$PIGEN_DIR/stage4/SKIP" "$PIGEN_DIR/stage5/SKIP"
touch "$PIGEN_DIR/stage2/SKIP_IMAGES" "$PIGEN_DIR/stage3/SKIP_IMAGES" "$PIGEN_DIR/stage4/SKIP_IMAGES" "$PIGEN_DIR/stage5/SKIP_IMAGES"

# Remove any previous custom stage link
rm -f "$PIGEN_DIR/stage-alphasound"

# Symlink our custom stage into pi-gen
ln -sf "$SCRIPT_DIR/stage-alphasound" "$PIGEN_DIR/stage-alphasound"

# Build with Docker
echo ""
echo "Starting pi-gen Docker build..."
echo "This will take a while (30-60 minutes on first run)."
echo ""

cd "$PIGEN_DIR"
./build-docker.sh

# Copy and compress output
mkdir -p "$DEPLOY_DIR"
for img in "$PIGEN_DIR/deploy/"*.img; do
    echo "Compressing $(basename "$img")..."
    xz -9 -T0 "$img"
    cp "${img}.xz" "$DEPLOY_DIR/"
done

echo ""
echo "=== Build complete ==="
echo "Image(s) in: $DEPLOY_DIR/"
ls -lh "$DEPLOY_DIR/"
