#!/bin/bash
# Build an arm64 macOS 15+ application. No signing credentials needed for local builds.
set -euo pipefail
cd "$(dirname "$0")/../.."
configuration="${CONFIGURATION:-release}"
version="${APP_VERSION:-0.0.0}"
build_number="${APP_BUILD:-1}"
output="$PWD/dist"
app="$output/Speech Server.app"
swift_args=(--disable-keychain)
if [[ "${SWIFT_BUILD_DISABLE_SANDBOX:-0}" == 1 ]]; then swift_args+=(--disable-sandbox); fi
swift build -c "$configuration" --arch arm64 --product speech-server "${swift_args[@]}"
swift build -c "$configuration" --arch arm64 --product speech-server-agent "${swift_args[@]}"
swift build --package-path App -c "$configuration" --arch arm64 "${swift_args[@]}"
server_bin=$(swift build -c "$configuration" --arch arm64 --show-bin-path)
app_bin=$(swift build --package-path App -c "$configuration" --arch arm64 --show-bin-path)
# Only remove our reproducible packaging output.
if [[ -e "$app" ]]; then /bin/rm -rf "$app"; fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$server_bin/speech-server" "$server_bin/speech-server-agent" "$app/Contents/MacOS/"
cp "$app_bin/SpeechServerApp" "$app/Contents/MacOS/"
cp App/Resources/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SpeechServerDistribution string homebrew" "$app/Contents/Info.plist"
build_id=$(shasum -a 256 "$server_bin/speech-server" "$server_bin/speech-server-agent" "$app_bin/SpeechServerApp" | awk '{print $1}' | shasum -a 256 | awk '{print $1}')
/usr/libexec/PlistBuddy -c "Add :SpeechServerBuildID string $build_id" "$app/Contents/Info.plist"
# Current dependency resources are privacy manifests, with no runtime Bundle.module reads.
# Package them under Resources as valid macOS bundles for signing.
shopt -s nullglob
for resource in "$server_bin"/*.bundle "$app_bin"/*.bundle; do
    name=$(basename "$resource")
    [[ "$name" == *Tests.bundle ]] && continue
    destination="$app/Contents/Resources/$name"
    mkdir -p "$destination/Contents/Resources"
    /usr/bin/python3 - "$resource" <<'PYCHECK'
import pathlib, sys
files = [p for p in pathlib.Path(sys.argv[1]).rglob("*") if p.is_file()]
if any(p.name != "PrivacyInfo.xcprivacy" for p in files):
    raise SystemExit("New runtime resources need explicit app-bundle lookup support: " + sys.argv[1])
PYCHECK
    ditto "$resource" "$destination/Contents/Resources"
    /usr/bin/python3 - "$destination" "$name" <<'PYINFO'
import pathlib, plistlib, sys
bundle = pathlib.Path(sys.argv[1])
identifier = "org.dokterbob.resources." + sys.argv[2].removesuffix(".bundle").replace("_", "-")
(bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
    "CFBundleIdentifier": identifier, "CFBundlePackageType": "BNDL", "CFBundleVersion": "1"
}))
PYINFO
    codesign --force --sign - "$destination"
done
# The source-built CLI keeps its original deployment target; the bundle requires macOS 15.
codesign --force --sign - "$app/Contents/MacOS/speech-server"
codesign --force --sign - "$app/Contents/MacOS/speech-server-agent"
codesign --force --sign - "$app/Contents/MacOS/SpeechServerApp"
codesign --force --sign - "$app"
"$app/Contents/MacOS/speech-server" config validate speech-server.yaml.example --json >/dev/null
plutil -lint "$app/Contents/Info.plist"
codesign --verify --deep --strict "$app"
printf 'Built %s\n' "$app"
