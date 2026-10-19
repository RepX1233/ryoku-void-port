#!/usr/bin/env bash
# =============================================================================
# ryoku-void-update.sh — Actualización atómica del port en Void Linux
# 1. git pull del monorepo
# 2. Recompilación de daemons Go
# 3. Re-materialización de configuración
# 4. Recarga de la sesión
# =============================================================================
set -euo pipefail
log() { echo -e "\e[1;32m==>\e[0m $*"; }

log "Actualizando monorepo de Ryoku..."
cd "$HOME/ryoku"
git pull --ff-only

log "Recompilando componentes Go..."
cd "$HOME/ryoku/ryoku/shell/ipc" && go build -o "$HOME/.local/bin/ryoku-shell" .
cd "$HOME/ryoku/ryoku/cli" && go build -o "$HOME/.local/bin/ryoku" .
cd "$HOME/ryoku/ryoku/hub/backend" && go build -o "$HOME/.local/bin/ryoku-hub" .

log "Actualizando configuraciones..."
ryoku materialize

log "Recargando entorno..."
ryoku reload

log "🎉 ¡Ryoku actualizado correctamente!"
