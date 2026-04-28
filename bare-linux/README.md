# Bare Linux

Run Enshrouded directly on a spare Linux box without Docker or Kubernetes.

## Quick Run

```bash
cd ./image
./entrypoint.sh
```

Default paths resolve from the current user:
- `ENSHROUDED_PATH=$HOME/enshrouded`
- `STEAMCMD_PATH=$HOME/steamcmd`
- `SAVE_IMPORT_BIND=127.0.0.1`

## Install As A systemd Service

Recommended path:

```bash
./bare-linux/install.sh
```

The installer will:
- create `~/.config/systemd/user/enshrouded.service`
- create `~/.config/enshrouded/enshrouded.env`
- enable and start the service

Default mode is rootless `systemctl --user`.

## Reboot Behavior

To keep the user service running across reboot and logout, enable lingering once:

```bash
sudo loginctl enable-linger "$(whoami)"
```

If you skip lingering, the user service usually starts when your session starts.

## Optional Overrides

Set overrides before running the installer:

```bash
export ENSHROUDED_BASE_DIR=/srv/enshrouded
export SAVE_IMPORT_MODE=1
export SAVE_IMPORT_BIND=0.0.0.0
export AUTO_UPDATE_ON_BOOT=0
./bare-linux/install.sh
```

## Installer Env Vars

| Env var | Default | Purpose |
|---|---|---|
| `ENSHROUDED_SYSTEMD_SCOPE` | `user` | `user` or `system` install mode |
| `ENSHROUDED_SERVICE_NAME` | `enshrouded` | systemd unit name |
| `ENSHROUDED_USER` | current user | target owner for system-scope install |
| `ENSHROUDED_GROUP` | target user's primary group | target group for system-scope install |
| `ENSHROUDED_HOME` | target user's home dir | base home for derived paths |
| `ENSHROUDED_BASE_DIR` | `$HOME/enshrouded-data` | data root |
| `ENSHROUDED_PATH` | `$ENSHROUDED_BASE_DIR/enshrouded` | server install/save path |
| `STEAMCMD_PATH` | `$ENSHROUDED_BASE_DIR/steamcmd` | SteamCMD path |
| `ENSHROUDED_SERVICE_PATH` | scope-dependent default | service output path |
| `ENSHROUDED_ENV_FILE` | scope-dependent default | env-file output path |
| `SAVE_IMPORT_MODE` | `0` | startup save-import gate |
| `SAVE_IMPORT_PORT` | `8080` | save-import HTTP port |
| `SAVE_IMPORT_BIND` | `127.0.0.1` | save-import bind address |
| `SAVE_IMPORT_TIMEOUT_SECONDS` | `0` | save-import timeout |
| `AUTO_UPDATE_ON_BOOT` | `1` | run Steam update/validate during startup |

System-wide install:

```bash
export ENSHROUDED_SYSTEMD_SCOPE=system
./bare-linux/install.sh
```

Runtime game-server env vars such as `SERVER_NAME`, `PORT`, and `SERVER_SLOTS` are documented in the repo-root [`README.md`](/home/seslly/seslly-github/servertimeai/k8s/enshrouded_server/README.md).
