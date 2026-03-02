#!/usr/bin/env bash
set -euo pipefail

LABEL="com.local.speech-server"
PLIST_DST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
INSTALL_BIN="${HOME}/bin/speech-server"
CONFIG_DIR="${HOME}/.config/speech-server"
LOG_DIR="${HOME}/Library/Logs/speech-server"

purge="false"

usage() {
	cat <<'EOF'
Uninstall macos-speech-server LaunchAgent.

Usage:
  deploy/uninstall-agent.sh [--purge]

Options:
  --purge   Also remove user config and logs.
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
	--purge)
		purge="true"
		shift
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

domain="gui/$(id -u)"
if launchctl print "${domain}/${LABEL}" >/dev/null 2>&1; then
	info "Stopping LaunchAgent"
	launchctl bootout "${domain}/${LABEL}" || true
fi

if [[ -f "${PLIST_DST}" ]]; then
	info "Removing ${PLIST_DST}"
	rm -f "${PLIST_DST}"
fi

if [[ -f "${INSTALL_BIN}" ]]; then
	info "Removing ${INSTALL_BIN}"
	rm -f "${INSTALL_BIN}"
fi

if [[ "${purge}" == "true" ]]; then
	info "Purging ${CONFIG_DIR} and ${LOG_DIR}"
	rm -rf "${CONFIG_DIR}" "${LOG_DIR}"
	info "Kept ${HOME}/Library/Application Support/FluidAudio (shared cache)"
else
	info "Keeping ${CONFIG_DIR} and ${LOG_DIR}"
	info "Re-run with --purge to remove them"
fi

info "Uninstall complete"
