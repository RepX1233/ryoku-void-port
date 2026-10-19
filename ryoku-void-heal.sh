#!/usr/bin/env bash
# =============================================================================
# ryoku-void-heal.sh — Script de autoreparación y salud para Ryoku en Void Linux
# Detecta librerías dinámicas rotas tras actualizaciones de xbps, recompila
# los daemons en Go y rematerializa la configuración.
# Uso: ./ryoku-void-heal.sh [--force]
# =============================================================================
set -euo pipefail

log() { echo -e "\e[1;32m==>\e[0m $*"; }
warn() { echo -e "\e[1;33m!!\e[0m $*"; }

log "Verificando integridad de binarios y librerías de Ryoku..."
broken=0

for bin in ryoku-shell ryoku ryoku-hub ryogami; do
  bin_path="$HOME/.local/bin/$bin"
  if [ -f "$bin_path" ]; then
    if ldd "$bin_path" 2>&1 | grep -q "not found"; then
      warn "Librería dinámica rota detectada en $bin."
      broken=1
    fi
  else
    warn "Binario ausente: $bin"
    broken=1
  fi
done

if [ $broken -eq 1 ] || [[ "${1:-}" == "--force" ]]; then
  log "Iniciando recompilación de componentes desde el monorepo..."
  
  if [ ! -d "$HOME/ryoku/.git" ]; then
    echo "ERROR: No se encuentra el monorepo de Ryoku en ~/ryoku" >&2
    exit 1
  }

  log "  -> Recompilando ryoku-shell"
  cd "$HOME/ryoku/ryoku/shell/ipc" && go build -o "$HOME/.local/bin/ryoku-shell" .
  
  log "  -> Recompilando ryoku (CLI)"
  cd "$HOME/ryoku/ryoku/cli" && go build -o "$HOME/.local/bin/ryoku" .
  
  log "  -> Recompilando ryoku-hub"
  cd "$HOME/ryoku/ryoku/hub/backend" && go build -o "$HOME/.local/bin/ryoku-hub" .

  log "Materializando configuraciones actualizadas..."
  ryoku materialize
  
  log "Recargando el daemon..."
  ryoku reload || true
  
  log "🎉 ¡Sistema de Ryoku reparado y sincronizado con éxito!"
else
  log "✓ Todos los binarios y dependencias están en perfecto estado. Ninguna acción requerida."
fi
