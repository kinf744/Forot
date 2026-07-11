#!/bin/bash
set -e

ASSETS_DIR="android/app/src/main/assets/xray"
mkdir -p "$ASSETS_DIR"

URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm32-v7a.zip"
echo "Downloading Xray for armeabi-v7a..."
wget -q "$URL" -O /tmp/xray.zip
unzip -o /tmp/xray.zip xray -d "$ASSETS_DIR/"
rm /tmp/xray.zip
ls -lh "$ASSETS_DIR/xray"
echo "Done"
