#!/usr/bin/env bash
# systemctl → runit shim inteligente para Void Linux (port Ryoku)
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

case "$action" in
  reboot) exec reboot ;;
  poweroff|shutdown) exec poweroff ;;
  halt) exec halt ;;

  is-active|is-enabled|status)
    if (( user_mode )); then
      # servicio de usuario: detectar proceso vivo
      pgrep -f "$svc" >/dev/null && exit 0 || exit 3
    fi
    # servicio de sistema: runit
    # sv status puede dar 'access denied' al usuario normal; el symlink en
    # /var/service es la fuente de verdad de habilitación de runit.
    if [ -L "/var/service/$svc" ]; then exit 0; fi
    if [ -d "/etc/sv/$svc" ]; then sv status "$svc" >/dev/null 2>&1 && exit 0; fi
    exit 3
    ;;

  stop)
    if (( user_mode )); then pkill -f "$svc" 2>/dev/null; exit 0; fi
    if [ -d "/etc/sv/$svc" ]; then sv stop "$svc" >/dev/null 2>&1; fi
    exit 0
    ;;

  start|restart|try-restart|reload)
    if (( user_mode )); then
      # daemon-reload y restarts de usuario: el lanzamiento real lo hace
      # deploy.sh/autostart con setsid; salir con error activa su fallback.
      exit 1
    fi
    if [ -d "/etc/sv/$svc" ]; then sv "$action" "$svc" >/dev/null 2>&1 || true; fi
    exit 0
    ;;

  daemon-reload|reset-failed|enable|disable|mask|unmask|set-environment|show|cat)
    # sin-op compatible: el ecosistema runit no los necesita
    (( user_mode )) && exit 1 || exit 0
    ;;

  *) exit 0 ;;
esac
