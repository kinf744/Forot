#!/bin/bash
set -e

JNILIBS_DIR="android/app/src/main/jniLibs"
declare -A PLATFORMS
PLATFORMS["arm64-v8a"]="Xray-android-arm64-v8a"
PLATFORMS["x86_64"]="Xray-android-amd64"

for ABI in "${!PLATFORMS[@]}"; do
    ZIP_NAME="${PLATFORMS[$ABI]}"
    URL="https://github.com/XTLS/Xray-core/releases/latest/download/${ZIP_NAME}.zip"
    echo "Downloading $ZIP_NAME for $ABI..."
    
    mkdir -p "$JNILIBS_DIR/$ABI"
    wget -q "$URL" -O "/tmp/xray-$ABI.zip"
    unzip -o "/tmp/xray-$ABI.zip" xray -d "$JNILIBS_DIR/$ABI/"
    mv "$JNILIBS_DIR/$ABI/xray" "$JNILIBS_DIR/$ABI/libxray.so"
    rm "/tmp/xray-$ABI.zip"
    echo "Done: $ABI"
done

echo "All Xray binaries placed in $JNILIBS_DIR"
ls -la "$JNILIBS_DIR"/*/libxray.so
