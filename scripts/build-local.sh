#!/bin/bash
set -euo pipefail

# Build through Xcode so Sparkle and its installer services are embedded correctly.
project_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="${LAYBY_BUILD_DIR:-$project_root/build/local}"
app="$build_root/Layby.app"

xcodebuild \
    -project "$project_root/Layby.xcodeproj" \
    -scheme Layby \
    -configuration Release \
    -derivedDataPath "$build_root/DerivedData" \
    CONFIGURATION_BUILD_DIR="$build_root" \
    build

if [[ ! -d "$app" ]]; then
    printf '错误：Xcode 未生成预期应用：%s\n' "$app" >&2
    exit 1
fi

printf '%s\n' "$app"
