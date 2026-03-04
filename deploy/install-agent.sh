#!/usr/bin/env bash
set -euo pipefail

LABEL="com.local.speech-server"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PLIST_TEMPLATE="${SCRIPT_DIR}/${LABEL}.agent.plist"
PLIST_DST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
INSTALL_BIN="${HOME}/bin/speech-server"
CONFIG_DIR="${HOME}/.config/speech-server"
CONFIG_FILE="${CONFIG_DIR}/speech-server.yaml"
LOG_DIR="${HOME}/Library/Logs/speech-server"
SOURCE_CONFIG="${REPO_DIR}/speech-server.yaml"

binary_path=""

usage() {
	cat <<'EOF'
Install macos-speech-server as a per-user LaunchAgent.

Usage:
  deploy/install-agent.sh [--binary /path/to/speech-server]

Options:
  --binary PATH       Use an existing built binary instead of building.
EOF
}

info() {
	printf '[info] %s\n' "$1"
}

die() {
	printf '[error] %s\n' "$1" >&2
	exit 1
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--binary)
		[[ $# -ge 2 ]] || die "--binary requires a path"
		binary_path="$2"
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		die "Unknown option: $1"
		;;
	esac
done

[[ "${EUID}" -ne 0 ]] || die "Run as your normal user (do not use sudo)."
[[ -f "${PLIST_TEMPLATE}" ]] || die "Missing plist template: ${PLIST_TEMPLATE}"
[[ -f "${SOURCE_CONFIG}" ]] || die "Missing source config file: ${SOURCE_CONFIG}"

if [[ -n "${binary_path}" ]]; then
	[[ -x "${binary_path}" ]] || die "Binary is not executable: ${binary_path}"
else
	info "Building release binary"
	swift build -c release --package-path "${REPO_DIR}"
	binary_path="${REPO_DIR}/.build/release/speech-server"
	[[ -x "${binary_path}" ]] || die "Build succeeded but binary not found: ${binary_path}"
fi

info "Preparing user directories"
install -d -m 755 "${HOME}/bin" "${CONFIG_DIR}" "${HOME}/Library/LaunchAgents" "${LOG_DIR}"

info "Installing binary to ${INSTALL_BIN}"
install -m 755 "${binary_path}" "${INSTALL_BIN}"

if [[ ! -f "${CONFIG_FILE}" ]]; then
	install -m 644 "${SOURCE_CONFIG}" "${CONFIG_FILE}"
	info "Installed default config at ${CONFIG_FILE}"
else
	info "Keeping existing config at ${CONFIG_FILE}"
fi

home_escaped="${HOME//\//\\/}"
sed "s/__HOME__/${home_escaped}/g" "${PLIST_TEMPLATE}" >"${PLIST_DST}"
chmod 644 "${PLIST_DST}"

domain="gui/$(id -u)"
if launchctl print "${domain}/${LABEL}" >/dev/null 2>&1; then
	info "Stopping currently loaded LaunchAgent"
	launchctl bootout "${domain}/${LABEL}" || true
fi

info "Loading LaunchAgent"
launchctl bootstrap "${domain}" "${PLIST_DST}"
launchctl enable "${domain}/${LABEL}"
launchctl kickstart -k "${domain}/${LABEL}"

info "Install complete"
printf 'Label: %s\n' "${LABEL}"
printf 'Binary: %s\n' "${INSTALL_BIN}"
printf 'Config: %s\n' "${CONFIG_FILE}"
printf 'Logs: %s/output.log and %s/error.log\n' "${LOG_DIR}" "${LOG_DIR}"
printf 'Status: launchctl print %s/%s\n' "${domain}" "${LABEL}"
