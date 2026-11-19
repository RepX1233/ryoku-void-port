#!/usr/bin/env bash
# ============================================================================
# ryoku-void-update.sh — Actualización completa del port en Void Linux
# ----------------------------------------------------------------------------
# Secuencia (idempotente, todo dentro del flujo empaquetado .xbps):
#   1. snapshot pre   (sólo Btrfs + snapper, módulo opcional 2E)
#   2. --system       -> xbps-install -Su  (base del sistema, opcional)
#   3. git pull del monorepo + rebuild de TODOS los binarios Go/C/QML
#      + reempaquetado de ryoku-desktop + xbps-install -yR  (vía
#      ryoku-void-install --update, que unifica la jerarquía en /usr/bin)
#   4. --stack        -> rebuild-hypr-stack.sh all (rebuild del stack Hyprland
#                        con Clang; opcional, para cuando Void mueve Qt6/base)
#   5. snapshot post
#   6. ryoku materialize + ryoku reload
#
# Uso:
#   ryoku-void-update.sh                 # sólo Ryoku (payload + config)
#   sudo ryoku-void-update.sh --system   # además la base Void (con snapshots)
#   ryoku-void-update.sh --stack         # además reconstruye Hyprland/quickshell
#   ryoku-void-update.sh --skip-quickshell
#
# Sin TTY (botón Update del Hub): el port instala la regla sudoers acotada
# sudoers/ryoku-update -> /etc/sudoers.d/zz-ryoku-update que permite exactamente
# este script y los xbps-install listados allí, nada más.
# ============================================================================
set -euo pipefail

log()  { echo -e "\e[1;32m==>\e[0m $*"; }
warn() { echo -e "\e[1;33m!!\e[0m $*"; }
err()  { echo -e "\e[1;31mXX\e[0m $*" >&2; }

DO_SYSTEM=0 DO_STACK=0 SKIP_QS=0
ARGS=()
for a in "$@"; do
  case "$a" in
    --system) DO_SYSTEM=1 ;;
    --stack) DO_STACK=1 ;;
    --skip-quickshell) SKIP_QS=1 ;;
    --help|-h) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) err "argumento desconocido: $a (--help)"; exit 1 ;;
  esac
done

PORT_BIN=/usr/bin
INSTALLER=${RYOKU_INSTALLER:-$PORT_BIN/ryoku-void-install}
STACK_SCRIPT=${RYOKU_STACK_SCRIPT:-/usr/share/ryoku/port/rebuild-hypr-stack.sh}
SNAPSHOT=${RYOKU_SNAPSHOT:-$PORT_BIN/ryoku-void-snapshot}

# ¿somos root? (invocado vía sudoers o a mano con sudo)
am_root() { [ "$(id -u)" -eq 0 ]; }
# Ejecuta un paso privilegiado: ya root, o vía sudo (con la regla acotada).
as_root() { if am_root; then "$@"; else sudo "$@"; fi; }

# El usuario objetivo para los pasos que NO deben correr como root (xbps-src,
# git, go build): el dueño del home o SUDO_USER.
TARGET_USER=${SUDO_USER:-}
[ -n "$TARGET_USER" ] || TARGET_USER=$(id -un)
if [ "$TARGET_USER" = root ]; then
  TARGET_USER=$(logname 2>/dev/null || echo root)
fi

log "═══════════════════════════════════════════════════════════════════"
log " Ryoku Void update — usuario=$TARGET_USER root=$(am_root && echo sí || echo no)"
log "═══════════════════════════════════════════════════════════════════"

# --- 1. snapshot pre ---------------------------------------------------------
if [ -x "$SNAPSHOT" ]; then
  "$SNAPSHOT" pre || warn "snapshot pre falló o no aplica (¿Btrfs+snapper?)"
fi

# --- 2. base del sistema -----------------------------------------------------
if [ "$DO_SYSTEM" = 1 ]; then
  log "Actualizando base Void (xbps-install -Su)..."
  as_root env RYOKU_MANAGED_UPDATE=1 xbps-install -Su
fi

# --- 3. rebuild + reempaquetado ---------------------------------------------
# ryoku-void-install --update hace: git pull -> compilar TODOS los binarios
# (ryoku-shell, ryoku, ryoku-hub, ryogami, ryoku-livewall, ryogami-live,
# helpers Go y el plugin QML ryoku-blobs) -> payload FHS ->
# ./xbps-src pkg ryoku-desktop -> xbps-install -yR. Todo en /usr/bin.
[ -x "$INSTALLER" ] || { err "no encuentro $INSTALLER"; exit 1; }
log "Rebuild del payload y reempaquetado ryoku-desktop..."
INSTALL_ARGS=(--update --user="$TARGET_USER")
[ "$SKIP_QS" = 1 ] && INSTALL_ARGS+=(--skip-quickshell)
if am_root; then
  bash "$INSTALLER" "${INSTALL_ARGS[@]}"
else
  sudo bash "$INSTALLER" "${INSTALL_ARGS[@]}"
fi

# --- 4. stack Hyprland/quickshell (opcional) ---------------------------------
if [ "$DO_STACK" = 1 ]; then
  [ -x "$STACK_SCRIPT" ] || { err "no encuentro $STACK_SCRIPT"; exit 1; }
  log "Reconstruyendo el stack Hyprland con Clang..."
  # xbps-src exige usuario normal: si somos root, bajamos al usuario objetivo.
  if am_root; then
    su - "$TARGET_USER" -c "'$STACK_SCRIPT' all"
  else
    "$STACK_SCRIPT" all
  fi
fi

# --- 5. snapshot post --------------------------------------------------------
if [ -x "$SNAPSHOT" ]; then
  "$SNAPSHOT" post || warn "snapshot post falló o no aplica"
fi

# --- 6. materializar + recargar ----------------------------------------------
log "Materializando configuración (respeta ~/.config/ryoku/overrides)..."
if command -v ryoku >/dev/null 2>&1; then
  ryoku materialize || warn "ryoku materialize falló (¿sin sesión gráfica?)"
  ryoku reload || warn "ryoku reload falló (¿sin sesión gráfica?)"
fi

log "🎉 Ryoku actualizado. Versión: $(ryoku version 2>/dev/null || echo 'n/d')"
