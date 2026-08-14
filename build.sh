#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-Release}"
DERIVED_DATA_DIR="${DERIVED_DATA_DIR:-${PROJECT_DIR}/build}"
PROJECT_FILE="${PROJECT_DIR}/TokenEater.xcodeproj"
WIDGET_PLIST="${PROJECT_DIR}/TokenEaterWidget/Info.plist"
APP_PATH="${DERIVED_DATA_DIR}/Build/Products/${BUILD_CONFIGURATION}/TokenEater.app"

cd "$PROJECT_DIR"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: XcodeGen is required. Install it with: brew install xcodegen" >&2
    exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "error: Xcode is required. Install Xcode and select its developer directory." >&2
    exit 1
fi

echo "Generating TokenEater.xcodeproj..."
xcodegen generate

# XcodeGen removes this key during generation, but WidgetKit needs it to
# discover the extension. Restore it before every build.
if plutil -extract NSExtension xml1 -o /dev/null "$WIDGET_PLIST" 2>/dev/null; then
    plutil -replace NSExtension \
        -json '{"NSExtensionPointIdentifier":"com.apple.widgetkit-extension"}' \
        "$WIDGET_PLIST"
else
    plutil -insert NSExtension \
        -json '{"NSExtensionPointIdentifier":"com.apple.widgetkit-extension"}' \
        "$WIDGET_PLIST"
fi

echo "Building TokenEater (${BUILD_CONFIGURATION})..."
xcodebuild \
    -project "$PROJECT_FILE" \
    -scheme TokenEaterApp \
    -configuration "$BUILD_CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    build

if [[ ! -d "$APP_PATH" ]]; then
    echo "error: build completed without producing ${APP_PATH}" >&2
    exit 1
fi

echo "Build succeeded: ${APP_PATH}"
