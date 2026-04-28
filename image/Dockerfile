FROM debian:13-slim

ARG CONTAINER_GID=10000
ARG CONTAINER_UID=10000

ENV DEBIAN_FRONTEND="noninteractive"
ENV STEAM_APP_ID="2278520"
ENV HOME="/home/steam"
ENV ENSHROUDED_PATH="/home/steam/enshrouded"
ENV ENSHROUDED_CONFIG="${ENSHROUDED_PATH}/enshrouded_server.json"
ENV EXTERNAL_CONFIG="0"
ENV GE_PROTON_VERSION="10-32"
ENV GE_PROTON_URL="https://github.com/GloriousEggroll/proton-ge-custom/releases/download/GE-Proton${GE_PROTON_VERSION}/GE-Proton${GE_PROTON_VERSION}.tar.gz"
ENV GE_PROTON_SEED_ROOT="/usr/local/share/proton-seed"
ENV STEAMCMD_PATH="/home/steam/steamcmd"
ENV STEAM_SDK64_PATH="/home/steam/.steam/sdk64"
ENV STEAM_SDK32_PATH="/home/steam/.steam/sdk32"
ENV STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAMCMD_PATH"
ENV STEAM_COMPAT_DATA_PATH="${STEAMCMD_PATH}/steamapps/compatdata/${STEAM_APP_ID}"
ENV UMU_ID="0"
ENV AUTO_UPDATE_ON_BOOT="1"

RUN groupadd -g $CONTAINER_GID steam \
    && useradd -g $CONTAINER_GID -u $CONTAINER_UID -m steam \
    && dpkg --add-architecture i386 \
    && apt-get update \
    && apt-get install --no-install-recommends -y \
        busybox \
        procps \
        ca-certificates \
        winbind \
        dbus \
        libfreetype6 \
        curl \
        jq \
        unzip \
        locales \
        lib32gcc-s1 \
        python3 \
    && echo 'LANG="en_US.UTF-8"' > /etc/default/locale \
    && echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen \
    && locale-gen \
    && rm -f /etc/machine-id \
    && dbus-uuidgen --ensure=/etc/machine-id \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p "${GE_PROTON_SEED_ROOT}" \
    && echo "Baking GE-Proton${GE_PROTON_VERSION} into image seed cache..." \
    && curl -fsSL "${GE_PROTON_URL}" | tar zxf - -C "${GE_PROTON_SEED_ROOT}"

COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=755 ui/cgi-bin/upload.sh /usr/local/share/save-import-ui/cgi-bin/upload.sh
COPY --chmod=755 ui/cgi-bin/skip.sh /usr/local/share/save-import-ui/cgi-bin/skip.sh
COPY --chmod=755 ui/cgi-bin/update.sh /usr/local/share/save-import-ui/cgi-bin/update.sh
COPY --chmod=755 ui/cgi-bin/status.sh /usr/local/share/save-import-ui/cgi-bin/status.sh
COPY --chmod=755 ui/cgi-bin/download.sh /usr/local/share/save-import-ui/cgi-bin/download.sh
COPY ui/index.html /usr/local/share/save-import-ui/index.html
COPY enshrouded_server_example.json /usr/local/share/enshrouded_server_example.json

USER steam

RUN mkdir -p "$ENSHROUDED_PATH/savegame" "$ENSHROUDED_PATH/logs" \
    && mkdir -p "${STEAMCMD_PATH}/compatibilitytools.d" \
    && mkdir -p "${STEAMCMD_PATH}/steamapps/compatdata/${STEAM_APP_ID}" \
    && mkdir -p /home/steam/.steam

WORKDIR /home/steam
CMD ["/usr/local/bin/entrypoint.sh"]
