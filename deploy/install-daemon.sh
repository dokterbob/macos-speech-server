#!/usr/bin/env bash
set -euo pipefail

LABEL="com.local.speech-server"
SERVICE_USER="_speech-server"
SERVICE_GROUP="_speech-server"
INSTALL_BIN="/usr/local/bin/speech-server"
CONFIG_DIR="/etc/speech-server"
CONFIG_FILE="${CONFIG_DIR}/speech-server.yaml"
LOG_DIR="/var/log/speech-server"
PLIST_DST="/Library/LaunchDaemons/${LABEL}.plist"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PLIST_SRC="${SCRIPT_DIR}/${LABEL}.plist"
SOURCE_CONFIG="${REPO_DIR}/speech-server.yaml"

binary_path=""
skip_model_copy="false"

usage() {
	cat <<'EOF'
Install macos-speech-server as a persistent LaunchDaemon.

Usage:
  sudo deploy/install-daemon.sh [--binary /path/to/speech-server] [--skip-model-copy]

Options:
  --binary PATH       Use an existing built binary instead of building.
  --skip-model-copy   Do not copy FluidAudio cache from invoking user to service user.
EOF
}

info() {
	printf '[info] %s\n' "$1"
}

warn() {
	printf '[warn] %s\n' "$1"
}

die() {
	printf '[error] %s\n' "$1" >&2
	exit 1
}

next_system_id() {
	local max_id
	max_id="$(dscl . -list /Users UniqueID | awk '$2 < 500 { print $2 }' | sort -n | tail -1)"
	if [[ -z "${max_id}" ]]; then
		echo "400"
	else
		echo "$((max_id + 1))"
	fi
}

create_service_group_if_needed() {
	if dscl . -read "/Groups/${SERVICE_GROUP}" >/dev/null 2>&1; then
		info "Group ${SERVICE_GROUP} already exists"
		return
	fi

	local gid
	gid="$(next_system_id)"
	info "Creating group ${SERVICE_GROUP} (gid ${gid})"
	dscl . -create "/Groups/${SERVICE_GROUP}"
	dscl . -create "/Groups/${SERVICE_GROUP}" PrimaryGroupID "${gid}"
}

create_service_user_if_needed() {
	if dscl . -read "/Users/${SERVICE_USER}" >/dev/null 2>&1; then
		info "User ${SERVICE_USER} already exists"
		return
	fi

	local uid gid home_dir
	uid="$(next_system_id)"
	gid="$(dscl . -read "/Groups/${SERVICE_GROUP}" PrimaryGroupID | awk '{print $2}')"
	home_dir="/Users/${SERVICE_USER}"

	info "Creating user ${SERVICE_USER} (uid ${uid}, gid ${gid})"
	dscl . -create "/Users/${SERVICE_USER}"
	dscl . -create "/Users/${SERVICE_USER}" UserShell /usr/bin/false
	dscl . -create "/Users/${SERVICE_USER}" RealName "speech-server service account"
	dscl . -create "/Users/${SERVICE_USER}" UniqueID "${uid}"
	dscl . -create "/Users/${SERVICE_USER}" PrimaryGroupID "${gid}"
	dscl . -create "/Users/${SERVICE_USER}" NFSHomeDirectory "${home_dir}"

	mkdir -p "${home_dir}"
	chown "${SERVICE_USER}:${SERVICE_GROUP}" "${home_dir}"
}

copy_model_cache_if_available() {
	if [[ "${skip_model_copy}" == "true" ]]; then
		info "Skipping model cache copy (--skip-model-copy)"
		return
	fi

	if [[ -z "${SUDO_USER:-}" || "${SUDO_USER}" == "root" ]]; then
		warn "Cannot detect non-root invoking user; skipping model cache copy"
		return
	fi

	local source_home source_cache dst_cache dst_parent
	source_home="$(dscl . -read "/Users/${SUDO_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
	if [[ -z "${source_home}" ]]; then
		warn "Cannot determine home directory for ${SUDO_USER}; skipping model cache copy"
		return
	fi

	source_cache="${source_home}/Library/Application Support/FluidAudio"
	dst_cache="/Users/${SERVICE_USER}/Library/Application Support/FluidAudio"
	dst_parent="/Users/${SERVICE_USER}/Library/Application Support"

	if [[ ! -d "${source_cache}" ]]; then
		info "No source model cache found at ${source_cache}; skipping copy"
		return
	fi

	info "Copying FluidAudio cache from ${source_cache} to ${dst_cache}"
	mkdir -p "${dst_parent}"
	ditto "${source_cache}" "${dst_cache}"
	chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "/Users/${SERVICE_USER}/Library"
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--binary)
		[[ $# -ge 2 ]] || die "--binary requires a path"
		binary_path="$2"
		shift 2
		;;
	--skip-model-copy)
		skip_model_copy="true"
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
[[ -f "${PLIST_SRC}" ]] || die "Missing plist template: ${PLIST_SRC}"
[[ -f "${SOURCE_CONFIG}" ]] || die "Missing source config file: ${SOURCE_CONFIG}"

if [[ -n "${binary_path}" ]]; then
	[[ -x "${binary_path}" ]] || die "Binary is not executable: ${binary_path}"
else
	info "Building release binary"
	swift build -c release --package-path "${REPO_DIR}"
	binary_path="${REPO_DIR}/.build/release/speech-server"
	[[ -x "${binary_path}" ]] || die "Build succeeded but binary not found: ${binary_path}"
fi

create_service_group_if_needed
create_service_user_if_needed

info "Installing binary to ${INSTALL_BIN}"
install -d /usr/local/bin
install -m 755 "${binary_path}" "${INSTALL_BIN}"

info "Preparing config and log directories"
install -d -m 755 "${CONFIG_DIR}" "${LOG_DIR}"
if [[ ! -f "${CONFIG_FILE}" ]]; then
	install -m 644 "${SOURCE_CONFIG}" "${CONFIG_FILE}"
	info "Installed default config at ${CONFIG_FILE}"
else
	info "Keeping existing config at ${CONFIG_FILE}"
fi

copy_model_cache_if_available

chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "${CONFIG_DIR}" "${LOG_DIR}" "/Users/${SERVICE_USER}"

if launchctl print "system/${LABEL}" >/dev/null 2>&1; then
	info "Stopping currently loaded daemon"
	launchctl bootout "system/${LABEL}" || true
fi

info "Installing launchd plist to ${PLIST_DST}"
install -m 644 "${PLIST_SRC}" "${PLIST_DST}"
chown root:wheel "${PLIST_DST}"

info "Loading daemon"
launchctl bootstrap system "${PLIST_DST}"
launchctl enable "system/${LABEL}"
launchctl kickstart -k "system/${LABEL}"

info "Install complete"
printf 'Label: %s\n' "${LABEL}"
printf 'Binary: %s\n' "${INSTALL_BIN}"
printf 'Config: %s\n' "${CONFIG_FILE}"
printf 'Logs: %s/output.log and %s/error.log\n' "${LOG_DIR}" "${LOG_DIR}"
printf 'Status: launchctl print system/%s\n' "${LABEL}"
