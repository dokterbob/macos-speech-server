#!/bin/bash
# Optional source-preview archive. Public binary distribution uses the tap's bottle pipeline.
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${APP_VERSION:?Set the version used when building the app}"
app="$PWD/dist/Speech Server.app"
[[ -d "$app" ]] || { echo 'Run scripts/app/build.sh first.' >&2; exit 1; }
[[ "$APP_VERSION" == "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" ]]
codesign --verify --deep --strict "$app"
archive="$PWD/dist/Speech-Server-$APP_VERSION.zip"
ditto -c -k --keepParent "$app" "$archive"
shasum -a 256 "$archive"
printf 'Created an unnotarized source-preview archive. Publish the Homebrew formula and bottles for normal installation.\n'
