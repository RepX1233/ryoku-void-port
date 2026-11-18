#!/usr/bin/env bash
# ============================================================================
# ryoku-void-snapshot.sh — Snapshots Btrfs antes/después de actualizar (2E)
# ----------------------------------------------------------------------------
# Módulo OPCIONAL: sólo actúa si la raíz es Btrfs y existe snapper con su
# config (preferible `ryoku`, si no `root`). En cualquier otro caso sale 0 con
# un aviso, para que los llamadores (ryoku-void-update.sh) no fallen.
#
# Uso:
#   ryoku-void-snapshot.sh pre            # snapshot PRE de una actualización
#   ryoku-void-snapshot.sh post           # snapshot POST enlazado al PRE
#   ryoku-void-snapshot.sh status         # ¿está el módulo disponible?
#   ryoku-void-snapshot.sh list [N]       # últimos N snapshots (default 10)
#
# Integración con boot-guard (runit/system/ryoku-boot-guard): el servicio
# revierte al último snapshot de un sólo uso si la sesión gráfica no arranca
# dos veces seguidas (opt-in vía /etc/ryoku/boot-guard.conf).
#
# En Void no hay hooks de transacción de xbps: por eso TODO update que toque
# paquetes debe pasar por aquí (o por `ryoku update`, que en Void lo hace).
# ============================================================================
set -euo pipefail

log()  { echo -e "\e[1;32m==>\e[0m $*"; }
warn() { echo -e "\e[1;33m!!\e[0m $*"; }
err()  { echo -e "\e[1;31mXX\e[0m $*" >&2; }

STATE_DIR=${RYOKU_SNAPSHOT_STATE:-/var/lib/ryoku-void}
PRE_FILE="$STATE_DIR/snapshot-pre"

root_fstype() { findmnt -no FSTYPE / 2>/dev/null || echo unknown; }

# Config de snapper a usar: ryoku si existe, si no root.
snapper_config() {
  if [ -r /etc/snapper/configs/ryoku.conf ]; then echo ryoku
  elif [ -r /etc/snapper/configs/root.conf ]; then echo root
  else echo ""; fi
}

available() {
  [ "$(root_fstype)" = btrfs ] || return 1
  command -v snapper >/dev/null 2>&1 || return 1
  [ -n "$(snapper_config)" ] || return 1
  return 0
}

need_root() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

do_status() {
  if available; then
    log "disponible: raíz btrfs + snapper (config: $(snapper_config))"
    return 0
  fi
  log "NO disponible: raíz=$(root_fstype), snapper=$(command -v snapper || echo no), config=$(snapper_config || echo no)"
  return 0
}

do_pre() {
  if ! available; then
    warn "sin Btrfs+snapper: no se toma snapshot (correcto en no-btrfs)"
    return 0
  fi
  local cfg desc num
  cfg=$(snapper_config)
  desc="ryoku-pre-$(date +%Y%m%d-%H%M%S)"
  log "snapshot PRE (config $cfg): $desc"
  num=$(need_root snapper -c "$cfg" create -t pre -d "$desc" --print-number 2>/dev/null | tr -cd '0-9') || {
    # Sin --print-number (snapper viejo): creamos simple y no enlazamos.
    warn "snapper no devolvió número; snapshot simple creado"
    need_root snapper -c "$cfg" create -d "$desc" >/dev/null 2>&1 || \
      warn "falló crear snapshot (¿permisos?)"
    return 0
  }
  [ -n "$num" ] || { warn "número de snapshot vacío"; return 0; }
  need_root mkdir -p "$STATE_DIR"
  printf '%s\n' "$num" | need_root tee "$PRE_FILE" >/dev/null
  log "  -> snapshot #$num (se enlaza en 'post')"
}

do_post() {
  if ! available; then
    warn "sin Btrfs+snapper: no se toma snapshot post"
    return 0
  fi
  local cfg desc pre
  cfg=$(snapper_config)
  desc="ryoku-post-$(date +%Y%m%d-%H%M%S)"
  pre=$(cat "$PRE_FILE" 2>/dev/null || echo "")
  if [ -n "$pre" ]; then
    log "snapshot POST enlazado al PRE #$pre (config $cfg)"
    if need_root snapper -c "$cfg" create -t post --pre-number "$pre" -d "$desc" >/dev/null 2>&1; then
      need_root rm -f "$PRE_FILE"
      return 0
    fi
    warn "no se pudo enlazar post/pre; creo snapshot simple"
  fi
  log "snapshot POST simple (config $cfg): $desc"
  need_root snapper -c "$cfg" create -d "$desc" >/dev/null 2>&1 || warn "falló crear snapshot"
}

do_list() {
  if ! available; then
    warn "sin Btrfs+snapper"
    return 0
  fi
  need_root snapper -c "$(snapper_config)" list -n "${1:-10}"
}

case "${1:-}" in
  pre)    do_pre ;;
  post)   do_post ;;
  status) do_status ;;
  list)   do_list "${2:-10}" ;;
  --help|-h|help)
    sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *)
    err "subcomando desconocido: ${1:-} (usa: pre|post|status|list|help)"
    exit 1
    ;;
esac
