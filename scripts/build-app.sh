#!/bin/sh
# Build for a physical iPhone. No simulator runtime is required.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../app" && pwd)
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
build_dir="${BUILD_DIR:-$project_dir/../../work/DeviceBuild}"
if [ ! -d "$DEVELOPER_DIR" ]; then
    echo 'Install Xcode with iOS platform support first.' >&2
    exit 1
fi
if [ -n "${TEAM_ID:-}" ]; then
    destination='generic/platform=iOS'
    if [ -n "${DEVICE_ID:-}" ]; then destination="id=$DEVICE_ID"; fi
    xcodebuild -project "$project_dir/NutritionTracker.xcodeproj" \
        -scheme NutritionTracker -configuration Debug \
        -destination "$destination" \
        -derivedDataPath "$build_dir" \
        DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic \
        -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
else
    xcodebuild -project "$project_dir/NutritionTracker.xcodeproj" \
        -scheme NutritionTracker -configuration Debug \
        -destination 'generic/platform=iOS' -derivedDataPath "$build_dir" \
        CODE_SIGNING_ALLOWED=NO build
fi
