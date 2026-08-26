#!/bin/bash

# Directory containing the deep frameworks
FRAMEWORKS_DIR="/Users/zainulnazir/flux-mac-app/flux/flux/LocalPackages/LocalMPVKit/Frameworks"
# Directory to output XCFrameworks
OUTPUT_DIR="/Users/zainulnazir/flux-mac-app/flux/flux/LocalPackages/LocalMPVKit/XCFrameworks"

mkdir -p "$OUTPUT_DIR"

echo "Converting frameworks to XCFrameworks..."

find "$FRAMEWORKS_DIR" -name "*.framework" -type d -maxdepth 1 | while read framework_path; do
    framework_name=$(basename "$framework_path")
    name="${framework_name%.*}"
    output_path="$OUTPUT_DIR/$name.xcframework"
    
    echo "Creating $name.xcframework..."
    
    # Remove existing if any
    rm -rf "$output_path"
    
    # Create XCFramework
    xcodebuild -create-xcframework \
        -framework "$framework_path" \
        -output "$output_path"
        
    if [ $? -eq 0 ]; then
        echo "Successfully created $name.xcframework"
    else
        echo "Failed to create $name.xcframework"
        exit 1
    fi
done

echo "All XCFrameworks created successfully!"
