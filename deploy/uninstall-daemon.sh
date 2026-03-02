#!/usr/bin/env bash
set -euo pipefail

LABEL="com.local.speech-server"
SERVICE_USER="_speech-server"
SERVICE_GROUP="_speech-server"
INSTALL_BIN="/usr/local/bin/speech-server"
CONFIG_DIR="/etc/speech-server"
LOG_DIR="/var/log/speech-server"
PLIST_DST="/Library/LaunchDaemons/${LABEL}.plist"
SERVICE_HOME="/Users/${SERVICE_USER}"
MODEL_CACHE="${SERVICE_HOME}/Library/Application Support/FluidAudio"

purge="false"

usage() {
	cat <<'EOF'
Uninstall macos-speech-server LaunchDaemon.

Usage:
  sudo deploy/uninstall-daemon.sh [--purge]

Options:
  --purge   Also remove config, logs, model cache, and the _speech-server user/group.
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

[[ "${EUID}" -eq 0 ]] || die "Run as root (sudo)."

if launchctl print "system/${LABEL}" >/dev/null 2>&1; then
	info "Stopping daemon"
	launchctl bootout "system/${LABEL}" || true
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
	info "Purging config, logs, and model cache"
	rm -rf "${CONFIG_DIR}" "${LOG_DIR}" "${MODEL_CACHE}"

	if dscl . -read "/Users/${SERVICE_USER}" >/dev/null 2>&1; then
		info "Removing user ${SERVICE_USER}"
		dscl . -delete "/Users/${SERVICE_USER}" || true
	fi
	if dscl . -read "/Groups/${SERVICE_GROUP}" >/dev/null 2>&1; then
		info "Removing group ${SERVICE_GROUP}"
		dscl . -delete "/Groups/${SERVICE_GROUP}" || true
	fi
	rm -rf "${SERVICE_HOME}"
else
	info "Keeping ${CONFIG_DIR}, ${LOG_DIR}, and ${SERVICE_HOME}"
	info "Re-run with --purge to remove all service data"
fi

info "Uninstall complete"
