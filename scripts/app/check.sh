#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
swift format lint --strict --recursive Sources/ Tests/ Management/Sources/ Management/Tests/ App/Sources/
swift test --package-path Management --disable-keychain
swift build --package-path App --disable-keychain
CONFIGURATION=debug scripts/app/build.sh
codesign --verify --deep --strict 'dist/Speech Server.app'
