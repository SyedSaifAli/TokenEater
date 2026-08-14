#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-Release}"
DERIVED_DATA_DIR="${DERIVED_DATA_DIR:-${PROJECT_DIR}/build}"
APP_PATH="${DERIVED_DATA_DIR}/Build/Products/${BUILD_CONFIGURATION}/TokenEater.app"

"${PROJECT_DIR}/build.sh"

echo "Launching ${APP_PATH}..."
open "$APP_PATH"
