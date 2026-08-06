#!/bin/zsh
# Builds a Release copy of Parallelizer with local ad-hoc signing (no Apple
# developer account required) and installs it to /Applications.
set -euo pipefail

cd "$(dirname "$0")/.."

xcodebuild \
    -project Parallelizer.xcodeproj \
    -scheme Parallelizer \
    -configuration Release \
    -derivedDataPath build \
    build

rm -rf /Applications/Parallelizer.app
ditto build/Build/Products/Release/Parallelizer.app /Applications/Parallelizer.app

echo "Installed /Applications/Parallelizer.app"
