#!/bin/bash
set -euo pipefail

timestamp() {
  date +"%Y-%m-%d %H:%M:%S,%3N"
}

: "${STEAM_APP_ID:=2278520}"
: "${ENSHROUDED_PATH:=${HOME}/enshrouded}"
: "${ENSHROUDED_CONFIG:=${ENSHROUDED_PATH}/enshrouded_server.json}"
: "${GE_PROTON_VERSION:=10-32}"
: "${GE_PROTON_URL:=https://github.com/GloriousEggroll/proton-ge-custom/releases/download/GE-Proton${GE_PROTON_VERSION}/GE-Proton${GE_PROTON_VERSION}.tar.gz}"
: "${GE_PROTON_SEED_ROOT:=/usr/local/share/proton-seed}"
: "${STEAMCMD_PATH:=${HOME}/steamcmd}"
: "${STEAM_SDK64_PATH:=${HOME}/.steam/sdk64}"
: "${STEAM_SDK32_PATH:=${HOME}/.steam/sdk32}"
: "${STEAM_COMPAT_CLIENT_INSTALL_PATH:=${STEAMCMD_PATH}}"
: "${STEAM_COMPAT_DATA_PATH:=${STEAMCMD_PATH}/steamapps/compatdata/${STEAM_APP_ID}}"
: "${AUTO_UPDATE_ON_BOOT:=1}"

normalize_bool() {
  local name="$1"
  local value="$2"
  case "${value}" in
    1|true|TRUE|True|yes|YES|Yes|on|ON|On)
      printf '1'
      ;;
    0|false|FALSE|False|no|NO|No|off|OFF|Off)
      printf '0'
      ;;
    *)
      echo "$(timestamp) ERROR: ${name} must be 1/0, true/false, yes/no, or on/off; got '${value}'" >&2
      exit 1
      ;;
  esac
}

RUN_STEAM_UPDATE="$(normalize_bool AUTO_UPDATE_ON_BOOT "${AUTO_UPDATE_ON_BOOT}")"

# Set when we request graceful shutdown so the port-check loop exits cleanly (exit 0).
GRACEFUL_SHUTDOWN=0
shutdown() {
  echo "$(timestamp) INFO: Received SIGTERM, shutting down gracefully"
  GRACEFUL_SHUTDOWN=1
  # SIGINT (2) so the Windows server gets a Ctrl+C-style request; it runs its destruction steps.
  pkill -2 -f '[e]nshrouded_server.exe' || true
  # Give the server time to finish destruction (save, disconnect Steam, etc.).
  local wait_sec=0
  local max_wait="${TERMINATION_GRACE_SECONDS:-60}"
  while [ "$wait_sec" -lt "$max_wait" ]; do
    pgrep -f '[e]nshrouded_server.exe' >/dev/null 2>&1 || break
    sleep 2
    wait_sec=$((wait_sec + 2))
  done
}
trap shutdown TERM

init_steamcmd() {
  mkdir -p "${STEAMCMD_PATH}" "${STEAMCMD_PATH}/compatibilitytools.d" "${STEAMCMD_PATH}/steamapps/compatdata" /home/steam/.steam

  if [ ! -x "${STEAMCMD_PATH}/steamcmd.sh" ]; then
    echo "$(timestamp) INFO: Installing SteamCMD runtime..."
    curl -sqL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz | tar zxf - -C "${STEAMCMD_PATH}"
    chmod +x "${STEAMCMD_PATH}/steamcmd.sh"
  fi

  rm -rf "${STEAM_SDK64_PATH}" "${STEAM_SDK32_PATH}"
  ln -snf "${STEAMCMD_PATH}/linux64" "${STEAM_SDK64_PATH}"
  ln -snf "${STEAMCMD_PATH}/linux32" "${STEAM_SDK32_PATH}"
  ln -snf "${STEAM_SDK64_PATH}/steamclient.so" "${STEAM_SDK64_PATH}/steamservice.so"
  ln -snf "${STEAM_SDK32_PATH}/steamclient.so" "${STEAM_SDK32_PATH}/steamservice.so"
}

init_proton() {
  local proton_dir="${STEAMCMD_PATH}/compatibilitytools.d/GE-Proton${GE_PROTON_VERSION}"
  local seed_dir="${GE_PROTON_SEED_ROOT}/GE-Proton${GE_PROTON_VERSION}"
  if [ ! -x "${proton_dir}/proton" ]; then
    mkdir -p "${STEAMCMD_PATH}/compatibilitytools.d"
    if [ -x "${seed_dir}/proton" ]; then
      echo "$(timestamp) INFO: Seeding GE-Proton ${GE_PROTON_VERSION} from image cache..."
      cp -a "${seed_dir}" "${proton_dir}"
      return 0
    fi

    echo "$(timestamp) INFO: Installing GE-Proton ${GE_PROTON_VERSION} runtime from release URL..."
    mkdir -p "${STEAMCMD_PATH}/compatibilitytools.d"
    curl -sqL "${GE_PROTON_URL}" | tar zxf - -C "${STEAMCMD_PATH}/compatibilitytools.d/"
  fi
}

validate_managed_config_template() {
  local template_path="$1"
  if [ ! -f "${template_path}" ]; then
    echo "$(timestamp) ERROR: Managed config template not found at ${template_path}"
    exit 1
  fi
  if ! jq -e 'type == "object" and ((.userGroups? // []) | type == "array")' "${template_path}" >/dev/null 2>&1; then
    echo "$(timestamp) ERROR: Managed config template at ${template_path} must be a JSON object with userGroups as an array"
    exit 1
  fi
}

validate_managed_password_map() {
  local password_path="$1"
  if [ ! -f "${password_path}" ]; then
    echo "$(timestamp) ERROR: Managed config password map not found at ${password_path}"
    exit 1
  fi
  if ! jq -e 'type == "object" and all(to_entries[]?; (.value | type) == "string")' "${password_path}" >/dev/null 2>&1; then
    echo "$(timestamp) ERROR: Managed config password map at ${password_path} must be a JSON object of {groupName: password}"
    exit 1
  fi
}

render_managed_config() {
  : "${ENSHROUDED_MANAGED_CONFIG_TEMPLATE:=}"
  : "${ENSHROUDED_MANAGED_CONFIG_PASSWORDS:=}"

  if [ -z "${ENSHROUDED_MANAGED_CONFIG_TEMPLATE}" ]; then
    echo "$(timestamp) ERROR: CONFIG_MODE=managed requires ENSHROUDED_MANAGED_CONFIG_TEMPLATE"
    exit 1
  fi

  validate_managed_config_template "${ENSHROUDED_MANAGED_CONFIG_TEMPLATE}"

  local password_map_file ignored_inline_passwords
  password_map_file="$(mktemp)"
  printf '{}\n' > "${password_map_file}"

  if [ -n "${ENSHROUDED_MANAGED_CONFIG_PASSWORDS}" ]; then
    validate_managed_password_map "${ENSHROUDED_MANAGED_CONFIG_PASSWORDS}"
    cp "${ENSHROUDED_MANAGED_CONFIG_PASSWORDS}" "${password_map_file}"
  fi

  ignored_inline_passwords="$(jq '[.userGroups[]? | select((.password // "") != "")] | length' "${ENSHROUDED_MANAGED_CONFIG_TEMPLATE}")"
  if [ "${ignored_inline_passwords}" -gt 0 ]; then
    echo "$(timestamp) WARNING: Ignoring ${ignored_inline_passwords} inline userGroups.password value(s) from managed config template; provide passwords via JSON secret map"
  fi

  echo "$(timestamp) INFO: Rendering managed config to ${ENSHROUDED_CONFIG}"
  jq \
    --slurpfile passwords "${password_map_file}" \
    '
      .userGroups = ((.userGroups // []) | map(
        if has("name") then
          .password = ($passwords[0][.name] // "")
        else
          .
        end
      ))
    ' \
    "${ENSHROUDED_MANAGED_CONFIG_TEMPLATE}" > "${ENSHROUDED_CONFIG}.tmp" && mv "${ENSHROUDED_CONFIG}.tmp" "${ENSHROUDED_CONFIG}"

  rm -f "${password_map_file}"
}

run_save_import_ui() {
  : "${SAVE_IMPORT_MODE:=0}"
  : "${SAVE_IMPORT_PORT:=8080}"
  : "${SAVE_IMPORT_BIND:=127.0.0.1}"
  : "${SAVE_IMPORT_TIMEOUT_SECONDS:=0}"

  if [ "$SAVE_IMPORT_MODE" != "1" ]; then
    echo "$(timestamp) INFO: SAVE_IMPORT_MODE=0, skipping save import UI"
    return 0
  fi

  local webroot="/tmp/save-import/www"
  local state_dir="/tmp/save-import/state"
  local marker_file="${state_dir}/result"
  local httpd_pid=0
  local start_ts now_ts elapsed action

  mkdir -p "${webroot}/cgi-bin" "${state_dir}"
  cp /usr/local/share/save-import-ui/index.html "${webroot}/index.html"
  cp /usr/local/share/save-import-ui/cgi-bin/upload.sh "${webroot}/cgi-bin/upload.sh"
  cp /usr/local/share/save-import-ui/cgi-bin/skip.sh "${webroot}/cgi-bin/skip.sh"
  cp /usr/local/share/save-import-ui/cgi-bin/update.sh "${webroot}/cgi-bin/update.sh"
  cp /usr/local/share/save-import-ui/cgi-bin/status.sh "${webroot}/cgi-bin/status.sh"
  cp /usr/local/share/save-import-ui/cgi-bin/download.sh "${webroot}/cgi-bin/download.sh"
  chmod 755 "${webroot}/cgi-bin/upload.sh" "${webroot}/cgi-bin/skip.sh" "${webroot}/cgi-bin/update.sh" "${webroot}/cgi-bin/status.sh" "${webroot}/cgi-bin/download.sh"

  export SAVE_IMPORT_STATE_DIR="${state_dir}"
  export SAVE_IMPORT_MARKER_FILE="${marker_file}"

  echo "$(timestamp) INFO: Save import mode enabled; serving UI on :${SAVE_IMPORT_PORT}"
  echo "$(timestamp) INFO: Port-forward example: kubectl -n games port-forward pod/enshrouded-0 ${SAVE_IMPORT_PORT}:${SAVE_IMPORT_PORT}"

  busybox httpd -f -p "${SAVE_IMPORT_BIND}:${SAVE_IMPORT_PORT}" -h "${webroot}" &
  httpd_pid=$!

  start_ts=$(date +%s)
  while true; do
    if [ "$GRACEFUL_SHUTDOWN" -eq 1 ]; then
      kill "$httpd_pid" 2>/dev/null || true
      return 0
    fi

    if [ -f "${marker_file}" ]; then
      action="$(cat "${marker_file}" || true)"
      kill "$httpd_pid" 2>/dev/null || true
      if [ "$action" = "uploaded" ]; then
        echo "$(timestamp) INFO: Save upload complete; continuing startup"
        return 0
      fi
      if [ "$action" = "skip" ]; then
        echo "$(timestamp) INFO: Save upload skipped; continuing startup"
        SAVE_IMPORT_ACTION="skip"
        return 0
      fi
      if [ "$action" = "update" ]; then
        echo "$(timestamp) INFO: Update requested from startup UI; continuing startup"
        SAVE_IMPORT_ACTION="update"
        return 0
      fi
      echo "$(timestamp) ERROR: Unexpected save import action '${action}'"
      return 1
    fi

    if [ "${SAVE_IMPORT_TIMEOUT_SECONDS}" -gt 0 ]; then
      now_ts=$(date +%s)
      elapsed=$((now_ts - start_ts))
      if [ "${elapsed}" -ge "${SAVE_IMPORT_TIMEOUT_SECONDS}" ]; then
        echo "$(timestamp) INFO: Save import timeout reached (${SAVE_IMPORT_TIMEOUT_SECONDS}s); continuing startup"
        kill "$httpd_pid" 2>/dev/null || true
        return 0
      fi
    fi

    sleep 1
  done
}

EXTERNAL_CONFIG="${EXTERNAL_CONFIG:-0}"
CONFIG_MODE="${ENSHROUDED_CONFIG_MODE:-}"
: "${SERVER_NAME:=Enshrouded Server}"
: "${PORT:=15637}"
: "${SERVER_SLOTS:=16}"
: "${SERVER_IP:=0.0.0.0}"
: "${VOICE_CHAT_MODE:=Proximity}"
: "${ENABLE_VOICE_CHAT:=false}"
: "${ENABLE_TEXT_CHAT:=false}"
: "${GAME_SETTINGS_PRESET:=Default}"

if [ -z "${CONFIG_MODE}" ]; then
  if [ "$EXTERNAL_CONFIG" -eq 1 ]; then
    CONFIG_MODE="external"
  else
    CONFIG_MODE="env"
  fi
fi

case "${CONFIG_MODE}" in
  env)
    EXTERNAL_CONFIG=0
    ;;
  managed)
    EXTERNAL_CONFIG=0
    ;;
  external|mutable)
    EXTERNAL_CONFIG=1
    CONFIG_MODE="mutable"
    ;;
  *)
    echo "$(timestamp) ERROR: Unsupported ENSHROUDED_CONFIG_MODE=${CONFIG_MODE}; expected env, managed, or mutable"
    exit 1
    ;;
esac

if [ "${CONFIG_MODE}" = "mutable" ]; then
  if [ ! -f "$ENSHROUDED_CONFIG" ]; then
    echo "$(timestamp) ERROR: Mutable config mode requires existing config at $ENSHROUDED_CONFIG"
    exit 1
  fi
fi

mkdir -p "$ENSHROUDED_PATH/savegame" "$ENSHROUDED_PATH/logs"
mkdir -p "$STEAM_COMPAT_DATA_PATH" "$STEAM_COMPAT_DATA_PATH/pfx"

init_steamcmd
init_proton

# SteamCMD may mutate compatdata paths; ensure Proton lock dir exists right before launch.
mkdir -p "$STEAM_COMPAT_DATA_PATH" "$STEAM_COMPAT_DATA_PATH/pfx"

SAVE_IMPORT_ACTION=""
run_save_import_ui

if [ "$SAVE_IMPORT_ACTION" = "update" ]; then
  RUN_STEAM_UPDATE=1
fi

if [ "$RUN_STEAM_UPDATE" = "1" ]; then
  echo "$(timestamp) INFO: Running Steam update check before launch"
  "${STEAMCMD_PATH}/steamcmd.sh" \
    +@sSteamCmdForcePlatformType windows \
    +force_install_dir "$ENSHROUDED_PATH" \
    +login anonymous \
    +app_update "$STEAM_APP_ID" validate \
    +quit
else
  echo "$(timestamp) INFO: Skipping Steam update check (RUN_STEAM_UPDATE=0)"
fi

# Config lives in data path (ENSHROUDED_PATH) so it persists across reboots.
if [ "${CONFIG_MODE}" = "managed" ]; then
  render_managed_config
elif [ "$EXTERNAL_CONFIG" -eq 0 ]; then
  if [ ! -f "$ENSHROUDED_CONFIG" ]; then
    echo "$(timestamp) INFO: No config found, copying example to $ENSHROUDED_CONFIG"
    cp /usr/local/share/enshrouded_server_example.json "$ENSHROUDED_CONFIG"
  fi
  echo "$(timestamp) INFO: Applying env overrides to config"
  jq \
    --arg name "$SERVER_NAME" \
    --arg ip "$SERVER_IP" \
    --argjson queryPort "$PORT" \
    --argjson slotCount "$SERVER_SLOTS" \
    --arg voiceChatMode "$VOICE_CHAT_MODE" \
    --arg enableVoiceChat "$ENABLE_VOICE_CHAT" \
    --arg enableTextChat "$ENABLE_TEXT_CHAT" \
    --arg gameSettingsPreset "$GAME_SETTINGS_PRESET" \
    '.name = $name | .ip = $ip | .queryPort = $queryPort | .slotCount = $slotCount | .voiceChatMode = $voiceChatMode | .enableVoiceChat = ($enableVoiceChat == "true") | .enableTextChat = ($enableTextChat == "true") | .gameSettingsPreset = $gameSettingsPreset' \
    "$ENSHROUDED_CONFIG" > "${ENSHROUDED_CONFIG}.tmp" && mv "${ENSHROUDED_CONFIG}.tmp" "$ENSHROUDED_CONFIG"
fi

echo "$(timestamp) INFO: Startup config $(jq -c \
  --arg configMode "$CONFIG_MODE" \
  --arg externalConfig "$EXTERNAL_CONFIG" \
  --arg runSteamUpdate "$RUN_STEAM_UPDATE" \
  --arg saveImportMode "$SAVE_IMPORT_MODE" \
  --arg saveImportBind "$SAVE_IMPORT_BIND" \
  --arg saveImportPort "$SAVE_IMPORT_PORT" \
  --arg saveImportTimeoutSeconds "$SAVE_IMPORT_TIMEOUT_SECONDS" \
  --arg configPath "$ENSHROUDED_CONFIG" \
  '{
    process: "enshrouded-server",
    runtime: {
      configMode: $configMode,
      externalConfig: ($externalConfig == "1"),
      runSteamUpdate: ($runSteamUpdate == "1"),
      saveImportMode: ($saveImportMode == "1"),
      saveImportBind: $saveImportBind,
      saveImportPort: ($saveImportPort | tonumber),
      saveImportTimeoutSeconds: ($saveImportTimeoutSeconds | tonumber),
      configPath: $configPath
    },
    config: (
      . | .userGroups |= map(
        if has("password") then
          .password = (if (.password // "") == "" then "" else "<redacted>" end)
        else
          .
        end
      )
    )
  }' "$ENSHROUDED_CONFIG")"

: > "$ENSHROUDED_PATH/logs/enshrouded_server.log"
ln -sf /proc/1/fd/1 "$ENSHROUDED_PATH/logs/enshrouded_server.log"

# Use query port from config as readiness/liveness source of truth.
QUERY_PORT=$(jq -r '.queryPort' "$ENSHROUDED_CONFIG")
QUERY_PORT_HEX=$(printf '%04X' "$QUERY_PORT")

export WINEDEBUG="${WINEDEBUG:--all}"
# Doing just proton run exits and causes crash loops, keep on waitforexitandrun
echo "$(timestamp) INFO: Launching Enshrouded server via Proton waitforexitandrun to keep server process lifecycle attached to initialize and bind UDP"
"${STEAMCMD_PATH}/compatibilitytools.d/GE-Proton${GE_PROTON_VERSION}/proton" waitforexitandrun "$ENSHROUDED_PATH/enshrouded_server.exe" &

# Wait for server UDP bind so early Proton wrapper exits don't kill container prematurely.
echo "$(timestamp) INFO: Waiting for server UDP port ${QUERY_PORT}"
STARTUP_TIMEOUT_SECONDS=${STARTUP_TIMEOUT_SECONDS:-600}
WAIT_SECS=0
while true; do
  if awk '{print $2}' /proc/net/udp | grep -q ":${QUERY_PORT_HEX}$"; then
    echo "$(timestamp) INFO: Server is listening on UDP ${QUERY_PORT}"
    break
  fi
  WAIT_SECS=$((WAIT_SECS + 3))
  if [ $((WAIT_SECS % 60)) -eq 0 ]; then
    echo "$(timestamp) INFO: Still waiting for UDP ${QUERY_PORT} (waited=${WAIT_SECS}s)"
  fi
  if [ "$WAIT_SECS" -ge "$STARTUP_TIMEOUT_SECONDS" ]; then
    echo "$(timestamp) ERROR: Timed out waiting for UDP ${QUERY_PORT} after ${WAIT_SECS}s"
    exit 1
  fi
  sleep 3
done

# Keep container up while server keeps UDP port bound.
while awk '{print $2}' /proc/net/udp | grep -q ":${QUERY_PORT_HEX}$"; do
  sleep 3
done

if [ "$GRACEFUL_SHUTDOWN" -eq 1 ]; then
  echo "$(timestamp) INFO: Server stopped (graceful shutdown)"
  exit 0
fi
echo "$(timestamp) ERROR: Server UDP ${QUERY_PORT} disappeared"
exit 1
