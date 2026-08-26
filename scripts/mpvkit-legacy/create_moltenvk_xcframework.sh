#!/bin/bash

MOLTENVK_LIB="/opt/homebrew/Cellar/molten-vk/1.4.0/lib/libMoltenVK.dylib"
MOLTENVK_HEADERS="/opt/homebrew/Cellar/molten-vk/1.4.0/include/MoltenVK"
OUTPUT_DIR="/Users/zainulnazir/flux-mac-app/flux/flux/LocalPackages/LocalMPVKit/XCFrameworks"

mkdir -p "$OUTPUT_DIR"

echo "Creating MoltenVK.xcframework..."

rm -rf "$OUTPUT_DIR/MoltenVK.xcframework"

xcodebuild -create-xcframework \
    -library "$MOLTENVK_LIB" \
    -headers "$MOLTENVK_HEADERS" \
    -output "$OUTPUT_DIR/MoltenVK.xcframework"

if [ $? -eq 0 ]; then
    echo "Successfully created MoltenVK.xcframework"
else
    echo "Failed to create MoltenVK.xcframework"
    exit 1
fi
