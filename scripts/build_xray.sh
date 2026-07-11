#!/bin/bash
# Helper script to download Xray binaries for all supported ABIs
set -e

XRAY_VERSION=${1:-latest}
ASSETS_DIR="android/app/src/main/assets/xray"

declare -A PLATFORMS
PLATFORMS["arm64-v8a"]="Xray-android-arm64-v8a"
PLATFORMS["armeabi-v7a"]="Xray-android-arm32-v7a"
PLATFORMS["x86_64"]="Xray-android-x86_64"

for ABI in "${!PLATFORMS[@]}"; do
    ZIP_NAME="${PLATFORMS[$ABI]}"
    URL="https://github.com/XTLS/Xray-core/releases/${XRAY_VERSION}/download/${ZIP_NAME}.zip"
    
    echo "Downloading $ZIP_NAME for $ABI..."
    mkdir -p "$ASSETS_DIR/$ABI"
    
    if [[ "$XRAY_VERSION" == "latest" ]]; then
        URL="https://github.com/XTLS/Xray-core/releases/latest/download/${ZIP_NAME}.zip"
    fi
    
    wget -q "$URL" -O "/tmp/${ZIP_NAME}.zip"
    unzip -o "/tmp/${ZIP_NAME}.zip" -d "$ASSETS_DIR/$ABI/"
    rm "/tmp/${ZIP_NAME}.zip"
    echo "Done: $ABI"
done

echo "All Xray binaries downloaded to $ASSETS_DIR"
ls -la "$ASSETS_DIR"/*/
