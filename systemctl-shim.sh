#!/usr/bin/env bash
# =============================================================================
# systemctl-shim.sh — MODO LEGADO OPCIONAL (port Ryoku en Void)
# ----------------------------------------------------------------------------
# DESACTIVADO POR DEFECTO: este port ya no instala un systemctl falso global.
# La detección y el control nativos de runit viven en el monorepo vía
# patches/0001-void-runit-init.patch (cli/internal/sys/runit.go: `sv` con
# SVDIR=$XDG_RUNTIME_DIR/service, sin sudo, y UnitEnabled() que jamás invoca
# systemctl).
#
# Sólo se instala en /usr/local/bin/systemctl si pasas
#     sudo ryoku-void-install.sh --with-systemctl-shim
# a aplicaciones externas antiguas (Electron, portales, scripts de terceros)
# que exigen systemctl para arrancar.
#
# Nota de seguridad: un shim global engaña al ecosistema creyendo que systemd
# está activo; es la razón por la que ahora es opt-in y no por defecto.
# =============================================================================
set -uo pipefail

# Desglose de argumentos: ignora --user/--no-ask-password/--quiet/--now
user_mode=0
args=()
for a in "$@"; do
  case "$a" in
    --user) user_mode=1 ;;
    --*) ;;
    *) args+=("$a") ;;
  esac
done
action="${args[0]:-}"
unit="${args[1]:-}"
svc="${unit%.service}"

# Servicios de usuario: dir que supervisa turnstile (misma resolución que
# cli/internal/sys/runit.go), sin sudo.
user_svdir() {
  if [ -n "${SVDIR:-}" ]; then printf '%s' "$SVDIR"; return; fi
  if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -e "$XDG_RUNTIME_DIR/service" ]; then
    printf '%s' "$XDG_RUNTIME_DIR/service"; return
  fi
  printf '%s' "${HOME:-/nonexistent}/.config/service"
}

case "$action" in
  reboot) exec reboot ;;
  poweroff|shutdown) exec poweroff ;;
  halt) exec halt ;;

  is-active|is-enabled|status)
    if (( user_mode )); then
      # Fuente de verdad: la supervisión de runsv (sv status), no pgrep:
      # un proceso homónimo no implica que el servicio esté en marcha.
      d=$(user_svdir)
      if [ -d "$d/$svc" ] && SVDIR="$d" sv status "$svc" 2>/dev/null | grep -q '^run:'; then
        exit 0
      fi
      exit 3
    fi
    # Servicio de sistema: el symlink en /var/service es la fuente de verdad
    # de habilitación de runit (sv status puede dar 'access denied' sin root).
    if [ -L "/var/service/$svc" ]; then exit 0; fi
    if [ -d "/etc/sv/$svc" ]; then sv status "$svc" >/dev/null 2>&1 && exit 0; fi
    exit 3
    ;;

  stop)
    if (( user_mode )); then
      d=$(user_svdir); [ -d "$d/$svc" ] && SVDIR="$d" sv down "$svc" 2>/dev/null
      exit 0
    fi
    if [ -d "/etc/sv/$svc" ]; then sv down "$svc" >/dev/null 2>&1; fi
    exit 0
    ;;

  start|restart|try-restart|reload)
    if (( user_mode )); then
      d=$(user_svdir)
      if [ -d "$d/$svc" ]; then
        case $action in
          start) SVDIR="$d" sv up "$svc" 2>/dev/null ;;
          *) SVDIR="$d" sv restart "$svc" 2>/dev/null ;;
        esac
        exit 0
      fi
      # Sin servicio de usuario: salir con error activa el fallback real
      # (setsid) que usan deploy/autostart.
      exit 1
    fi
    if [ -d "/etc/sv/$svc" ]; then
      # Mapeo systemctl -> verbos de sv (start no es un verbo de sv).
      case $action in
        start) sv up "$svc" >/dev/null 2>&1 ;;
        reload) sv hup "$svc" >/dev/null 2>&1 ;;
        try-restart) sv check "$svc" >/dev/null 2>&1 ;;
        *) sv restart "$svc" >/dev/null 2>&1 ;;
      esac || true
    fi
    exit 0
    ;;

  daemon-reload|reset-failed|enable|disable|mask|unmask|set-environment|show|cat)
    # sin-op compatible: el ecosistema runit no los necesita
    (( user_mode )) && exit 1 || exit 0
    ;;

  *) exit 0 ;;
esac
