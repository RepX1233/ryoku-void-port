#!/usr/bin/env bash
# =============================================================================
# systemctl-shim.sh — Traductor inteligente systemd -> runit para Ryoku en Void
# Intercepta llamadas de Ryoku a systemctl y las mapea a comandos nativos de Void.
# Instalación: sudo ln -sf $(pwd)/systemctl-shim.sh /usr/local/bin/systemctl
# =============================================================================
set -euo pipefail

action="${1:-}"
shift || true

case "$action" in
  --user)
    user_action="${1:-}"
    shift || true
    unit="${1:-}"
    service_name="${unit%.service}"
    
    case "$user_action" in
      is-active)
        # Verifica si el servicio de Ryoku está corriendo en segundo plano
        pgrep -f "$service_name" >/dev/null && exit 0 || exit 3
        ;;
      stop)
        pkill -f "$service_name" || true
        exit 0
        ;;
      restart|start)
        # Lanza servicios críticos de Ryoku con setsid
        if [ "$service_name" = "voxtype" ]; then
          setsid voxtype daemon >/dev/null 2>&1 &
        fi
        exit 0
        ;;
      *) exit 0 ;;
    esac
    ;;
    
  is-active)
    unit="${1:-}"
    service_name="${unit%.service}"
    # Mapeo a runit de Void
    if [ -L "/var/service/$service_name" ] && sv status "$service_name" >/dev/null 2>&1; then
      exit 0
    else
      exit 3
    fi
    ;;
    
  restart|stop|start)
    unit="${1:-}"
    service_name="${unit%.service}"
    if [ -d "/etc/sv/$service_name" ]; then
      sudo sv "$action" "$service_name" || true
    fi
    exit 0
    ;;
    
  reboot) exec reboot ;;
  poweroff|shutdown) exec poweroff ;;
  *) exit 0 ;;
esac
