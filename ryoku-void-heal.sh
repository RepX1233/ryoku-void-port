#!/usr/bin/env bash
# ============================================================================
# ryoku-void-heal.sh — Autoreparación del port Ryoku en Void Linux
# ----------------------------------------------------------------------------
# Lo que REALMENTE se rompe cuando Void actualiza librerías son los binarios
# DINÁMICOS (C++/Qt6), no los binarios Go: ryoku-shell/ryoku/ryoku-hub/...
# se compilan con CGO_ENABLED=0 (estáticos), así que `ldd` nunca va a
# reportar nada en ellos — comprobarlos con ldd es una falsa alarma.
#
# Este script verifica entonces:
#   1. /usr/lib/qt6/qml/Ryoku/**.so   (plugin QML Ryoku.Blobs y cía)
#   2. /usr/bin/quickshell            (Qt6 dinámico)
#   3. /usr/bin/Hyprland              (C++/aquamarine dinámico)
#   4. existencia de los binarios estáticos del payload (sin ldd)
#
# Y repara según el fallo:
#   * .so de QML rotos     -> ryoku-void-install --rebuild-blobs
#   * quickshell/Hyprland  -> rebuild-hypr-stack.sh all
#   * payload ausente      -> ryoku-void-install --update
#   * al final             -> ryoku materialize + ryoku reload
#
# Uso:  ryoku-void-heal.sh [--force]     (--force: repara aunque no haya fallos)
# Requiere: usuario normal con sudo (los pasos de paquete piden contraseña).
# ============================================================================
set -euo pipefail

log()  { echo -e "\e[1;32m==>\e[0m $*"; }
warn() { echo -e "\e[1;33m!!\e[0m $*"; }
err()  { echo -e "\e[1;31mXX\e[0m $*" >&2; }

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

QML_DIR=${RYOKU_QML_DIR:-/usr/lib/qt6/qml/Ryoku}
QUICKSHELL=${QUICKSHELL:-/usr/bin/quickshell}
HYPRLAND_BIN=${HYPRLAND_BIN:-/usr/bin/Hyprland}
INSTALLER=${RYOKU_INSTALLER:-/usr/bin/ryoku-void-install}
STACK_SCRIPT=${RYOKU_STACK_SCRIPT:-rebuild-hypr-stack.sh}
# Binarios estáticos del payload (CGO_ENABLED=0): sólo existencia.
STATIC_BINS=(ryoku-shell ryoku ryoku-hub ryogami ryoku-livewall ryogami-live)

# --- helpers -----------------------------------------------------------------
# ldd_broken <fichero> -> 0 si tiene "not found" en sus dependencias dinámicas.
ldd_broken() {
  local f=$1
  [ -e "$f" ] || return 1
  # Un ELF estático/improbable: ldd lo dice y no es un fallo.
  ldd "$f" 2>/dev/null | grep -q 'not found'
}

broken_list=()
missing_list=()

log "Auditoría de integridad (sólo lectura)"

# 1) plugins QML dinámicos
if [ -d "$QML_DIR" ]; then
  while IFS= read -r so; do
    if ldd_broken "$so"; then
      broken_list+=("$so")
      warn "dependencias rotas en $so"
      ldd "$so" 2>/dev/null | grep 'not found' | sed 's/^/      /' || true
    fi
  done < <(find "$QML_DIR" -name '*.so' -type f 2>/dev/null)
else
  warn "no existe $QML_DIR (¿instalaste ryoku-desktop?)"
fi

# 2) quickshell y Hyprland (los .so que Void rompe al actualizar Qt6/base)
for f in "$QUICKSHELL" "$HYPRLAND_BIN"; do
  if [ ! -e "$f" ]; then
    missing_list+=("$f")
    warn "ausente: $f"
  elif ldd_broken "$f"; then
    broken_list+=("$f")
    warn "dependencias rotas en $f"
    ldd "$f" 2>/dev/null | grep 'not found' | sed 's/^/      /' || true
  fi
done

# 3) binarios estáticos: existencia y ejecutabilidad (NO ldd)
for b in "${STATIC_BINS[@]}"; do
  p="$(command -v "$b" 2>/dev/null || true)"
  if [ -z "$p" ] || [ ! -x "$p" ]; then
    missing_list+=("$b")
    warn "binario estático ausente: $b"
  fi
done

# --- decisión de reparación --------------------------------------------------
need_blobs=0 need_stack=0 need_payload=0
for f in "${broken_list[@]+"${broken_list[@]}"}"; do
  case $f in
    *.so) need_blobs=1 ;;
    "$QUICKSHELL"|"$HYPRLAND_BIN") need_stack=1 ;;
  esac
done
for f in "${missing_list[@]+"${missing_list[@]}"}"; do
  case $f in
    "$QUICKSHELL"|"$HYPRLAND_BIN") need_stack=1 ;;
    *) need_payload=1 ;;
  esac
done

if [ "$FORCE" = 0 ] && [ "$need_blobs$need_stack$need_payload" = "000" ]; then
  log "✓ Todo en verde: sin .so rotos ni binarios ausentes. (Ninguna acción.)"
  exit 0
fi

# --- reparación --------------------------------------------------------------
# Orden: primero lo más barato (blobs), luego el stack, luego el payload.
if [ "$need_blobs" = 1 ]; then
  log "Recompilando el plugin QML (ryoku-blobs) contra el Qt6 instalado..."
  if [ -x "$INSTALLER" ]; then
    sudo "$INSTALLER" --rebuild-blobs
  else
    err "no encuentro $INSTALLER; ejecuta: sudo bash ryoku-void-install.sh --rebuild-blobs"
    exit 1
  fi
fi

if [ "$need_stack" = 1 ]; then
  log "Reconstruyendo quickshell/Hyprland vía rebuild-hypr-stack.sh..."
  script=$STACK_SCRIPT
  if [ ! -x "$script" ] && [ -x "/usr/share/ryoku/port/$STACK_SCRIPT" ]; then
    script="/usr/share/ryoku/port/$STACK_SCRIPT"
  fi
  [ -x "$script" ] || { err "no encuentro rebuild-hypr-stack.sh"; exit 1; }
  # rebuild-hypr-stack.sh pide sudo para instalar (pide contraseña a mano).
  "$script" all
fi

if [ "$need_payload" = 1 ]; then
  log "Payload ausente/incompleto: rebuild completo + empaquetado..."
  [ -x "$INSTALLER" ] || { err "no encuentro $INSTALLER"; exit 1; }
  sudo "$INSTALLER" --update
fi

# --- post-reparación ---------------------------------------------------------
log "Rematerializando configuración..."
if command -v ryoku >/dev/null 2>&1; then
  ryoku materialize || warn "ryoku materialize falló (¿sin sesión?)"
  ryoku reload || warn "ryoku reload falló (¿sin sesión?)"
fi

log "🎉 Reparación terminada. Si la sesión no responde, cierra y vuelve a entrar."
