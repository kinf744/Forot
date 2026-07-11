#!/bin/bash
set -e

ASSETS_DIR="android/app/src/main/assets/xray"
mkdir -p "$ASSETS_DIR"

echo "Downloading Xray for armeabi-v7a..."
wget -q "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm32-v7a.zip" -O /tmp/xray.zip
unzip -o /tmp/xray.zip xray -d /tmp/
chmod +x /tmp/xray

# Strip and compress
arm-linux-gnueabihf-strip /tmp/xray 2>/dev/null || true
upx --lzma --best -o "$ASSETS_DIR/xray" /tmp/xray 2>/dev/null || cp /tmp/xray "$ASSETS_DIR/xray"

rm -f /tmp/xray.zip /tmp/xray
ls -lh "$ASSETS_DIR/xray"
echo "Done"
