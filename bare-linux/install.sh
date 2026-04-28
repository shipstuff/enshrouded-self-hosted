#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_DIR="$(cd "${SCRIPT_DIR}/../image" && pwd)"

TARGET_USER="${ENSHROUDED_USER:-${SUDO_USER:-$(whoami)}}"
TARGET_GROUP="${ENSHROUDED_GROUP:-$(id -gn "${TARGET_USER}")}"
TARGET_HOME="${ENSHROUDED_HOME:-$(getent passwd "${TARGET_USER}" | cut -d: -f6)}"
SYSTEMD_SCOPE="${ENSHROUDED_SYSTEMD_SCOPE:-user}"

if [ -z "${TARGET_HOME}" ]; then
  echo "Failed to resolve home directory for user ${TARGET_USER}" >&2
  exit 1
fi

SERVICE_NAME="${ENSHROUDED_SERVICE_NAME:-enshrouded}"
if [ "${SYSTEMD_SCOPE}" = "user" ]; then
  SERVICE_PATH="${ENSHROUDED_SERVICE_PATH:-${TARGET_HOME}/.config/systemd/user/${SERVICE_NAME}.service}"
  ENV_FILE="${ENSHROUDED_ENV_FILE:-${TARGET_HOME}/.config/enshrouded/${SERVICE_NAME}.env}"
else
  SERVICE_PATH="${ENSHROUDED_SERVICE_PATH:-/etc/systemd/system/${SERVICE_NAME}.service}"
  ENV_FILE="${ENSHROUDED_ENV_FILE:-/etc/enshrouded/${SERVICE_NAME}.env}"
fi

BASE_DIR="${ENSHROUDED_BASE_DIR:-${TARGET_HOME}/enshrouded-data}"
ENSHROUDED_PATH_DEFAULT="${ENSHROUDED_PATH:-${BASE_DIR}/enshrouded}"
STEAMCMD_PATH_DEFAULT="${STEAMCMD_PATH:-${BASE_DIR}/steamcmd}"

SAVE_IMPORT_MODE="${SAVE_IMPORT_MODE:-0}"
SAVE_IMPORT_PORT="${SAVE_IMPORT_PORT:-8080}"
SAVE_IMPORT_BIND="${SAVE_IMPORT_BIND:-127.0.0.1}"
SAVE_IMPORT_TIMEOUT_SECONDS="${SAVE_IMPORT_TIMEOUT_SECONDS:-0}"
AUTO_UPDATE_ON_BOOT="${AUTO_UPDATE_ON_BOOT:-1}"

SUDO_BIN=""
if [ "$(id -u)" -ne 0 ]; then
  SUDO_BIN="sudo"
fi

run_root() {
  if [ -n "${SUDO_BIN}" ]; then
    "${SUDO_BIN}" "$@"
  else
    "$@"
  fi
}

if [ "${SYSTEMD_SCOPE}" = "user" ]; then
  mkdir -p "$(dirname "${SERVICE_PATH}")" "$(dirname "${ENV_FILE}")"
  mkdir -p "${BASE_DIR}" "${ENSHROUDED_PATH_DEFAULT}" "${STEAMCMD_PATH_DEFAULT}"
else
  run_root mkdir -p "$(dirname "${SERVICE_PATH}")" "$(dirname "${ENV_FILE}")"
  run_root install -d -o "${TARGET_USER}" -g "${TARGET_GROUP}" "${BASE_DIR}" "${ENSHROUDED_PATH_DEFAULT}" "${STEAMCMD_PATH_DEFAULT}"
fi

tmp_env="$(mktemp)"
cat > "${tmp_env}" <<EOF
HOME=${TARGET_HOME}
ENSHROUDED_PATH=${ENSHROUDED_PATH_DEFAULT}
STEAMCMD_PATH=${STEAMCMD_PATH_DEFAULT}
STEAM_SDK64_PATH=${TARGET_HOME}/.steam/sdk64
STEAM_SDK32_PATH=${TARGET_HOME}/.steam/sdk32
STEAM_COMPAT_CLIENT_INSTALL_PATH=${STEAMCMD_PATH_DEFAULT}
STEAM_COMPAT_DATA_PATH=${STEAMCMD_PATH_DEFAULT}/steamapps/compatdata/2278520
SAVE_IMPORT_MODE=${SAVE_IMPORT_MODE}
SAVE_IMPORT_PORT=${SAVE_IMPORT_PORT}
SAVE_IMPORT_BIND=${SAVE_IMPORT_BIND}
SAVE_IMPORT_TIMEOUT_SECONDS=${SAVE_IMPORT_TIMEOUT_SECONDS}
AUTO_UPDATE_ON_BOOT=${AUTO_UPDATE_ON_BOOT}
EOF
if [ "${SYSTEMD_SCOPE}" = "user" ]; then
  install -m 0644 "${tmp_env}" "${ENV_FILE}"
else
  run_root install -m 0644 "${tmp_env}" "${ENV_FILE}"
fi
rm -f "${tmp_env}"

tmp_service="$(mktemp)"
if [ "${SYSTEMD_SCOPE}" = "user" ]; then
  sed \
    -e "s|^WorkingDirectory=.*$|WorkingDirectory=${IMAGE_DIR}|g" \
    -e "s|^ExecStart=.*$|ExecStart=${IMAGE_DIR}/entrypoint.sh|g" \
    -e "s|^EnvironmentFile=.*$|EnvironmentFile=-${ENV_FILE}|g" \
    -e "/^User=/d" \
    -e "/^Group=/d" \
    "${SCRIPT_DIR}/enshrouded.service.example" > "${tmp_service}"
  install -m 0644 "${tmp_service}" "${SERVICE_PATH}"
else
  sed \
    -e "s|REPLACE_WITH_USER|${TARGET_USER}|g" \
    -e "s|^WorkingDirectory=.*$|WorkingDirectory=${IMAGE_DIR}|g" \
    -e "s|^ExecStart=.*$|ExecStart=${IMAGE_DIR}/entrypoint.sh|g" \
    -e "s|^EnvironmentFile=.*$|EnvironmentFile=-${ENV_FILE}|g" \
    "${SCRIPT_DIR}/enshrouded.service.example" > "${tmp_service}"
  run_root install -m 0644 "${tmp_service}" "${SERVICE_PATH}"
fi
rm -f "${tmp_service}"

if [ "${SYSTEMD_SCOPE}" = "user" ]; then
  systemctl --user daemon-reload
  systemctl --user enable --now "${SERVICE_NAME}"
else
  run_root systemctl daemon-reload
  run_root systemctl enable --now "${SERVICE_NAME}"
fi

echo "Installed ${SERVICE_NAME} service (${SYSTEMD_SCOPE} scope)."
echo "Service file: ${SERVICE_PATH}"
echo "Env file: ${ENV_FILE}"
if [ "${SYSTEMD_SCOPE}" = "user" ]; then
  echo "Check status: systemctl --user status ${SERVICE_NAME} --no-pager"
  echo "Warning: without lingering, user services usually stop on logout and may not auto-start after reboot until login."
  echo "To keep this service running across reboots/logouts, run once:"
  echo "  sudo loginctl enable-linger ${TARGET_USER}"
else
  echo "Check status: sudo systemctl status ${SERVICE_NAME} --no-pager"
fi
