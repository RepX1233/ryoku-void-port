#!/usr/bin/env bash
# =============================================================================
# void-setup.sh — Instalación masiva de apps en Void Linux (XBPS + Flatpak)
# Nombres de paquetes verificados contra repodata/templates de Void y
# la API de Flathub (IDs de app confirmados con HTTP 200).
# Uso:  chmod +x void-setup.sh && sudo ./void-setup.sh
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 0) Precondiciones
# -----------------------------------------------------------------------------
if ! command -v xbps-install >/dev/null 2>&1; then
  echo "ERROR: xbps-install no encontrado. ¿Estás en Void Linux?" >&2
  exit 1
fi
if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: ejecuta este script como root (sudo ./void-setup.sh)." >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# 1) Habilitar repositorios nonfree y multilib (antes del sync)
#    - nonfree: steam, codecs, firmware, etc.
#    - multilib: libs 32-bit (Steam/Wine/Proton)
# -----------------------------------------------------------------------------
echo "==> Habilitando repositorios nonfree y multilib..."
xbps-install -S void-repo-nonfree void-repo-multilib

# -----------------------------------------------------------------------------
# 2) Sincronizar índices e instalar todo por XBPS en una sola transacción
# -----------------------------------------------------------------------------
# NOTAS de nombres verificados en Void (fácil errar):
#   obs (no obs-studio) · libreoffice (no -still/-fresh)
#   qView · melonDS (mayúsculas) · steam vive en nonfree
XBPS_PKGS=(
  # --- Navegadores (Brave/Zen no están → Flatpak) ---
  firefox
  chromium

  # --- Oficina / utilidades ---
  libreoffice
  qprompt

  # --- Edición y multimedia ---
  gimp
  inkscape
  krita
  blender
  darktable
  kdenlive
  shotcut
  obs
  handbrake
  audacity
  mpv
  qView

  # --- Juegos y emuladores (en repos; PCSX2/RPCS3 solo Flatpak) ---
  steam
  lutris
  dolphin-emu
  ppsspp
  retroarch
  scummvm
  melonDS
  mgba
  mame
  dosbox
  wine
  winetricks
  protontricks

  # --- Mensajería ---
  telegram-desktop

  # --- Terminal y desarrollo ---
  alacritty
  kitty
  micro
  neovim
  vim
  yazi
  btop

  # --- Sistema y rendimiento ---
  corectrl
  gparted
  qemu
  virt-manager
  scrcpy
  waydroid
  openrgb
  easyeffects
  antimicrox
  songrec

  # --- Base para la sección Flatpak ---
  flatpak
)

echo "==> Instalando ${#XBPS_PKGS[@]} paquetes XBPS..."
xbps-install -Sy "${XBPS_PKGS[@]}"

# -----------------------------------------------------------------------------
# 3) Flatpak + Flathub
#    Apps NO disponibles en Xbps (IDs Flathub verificados vía API):
#    Brave, Zen, ONLYOFFICE, Upscayl, LosslessCut, Heroic, PCSX2, RPCS3,
#    Vesktop, ZapZap/WhatsApp, Goverlay, LocalSend, Sober
# -----------------------------------------------------------------------------
echo "==> Configurando Flatpak + Flathub..."
flatpak remote-add --if-not-exists flathub \
  https://dl.flathub.org/repo/flathub.flatpakrepo

FLATPAK_APPS=(
  # Navegadores no empaquetados en Xbps
  com.brave.Browser
  app.zen_browser.zen

  # Oficina
  org.onlyoffice.desktopeditors

  # Multimedia (upscale + recorte sin pérdida; OBS ya va en XBPS)
  org.upscayl.Upscayl
  no.mifi.losslesscut

  # Juegos / launchers / emuladores ausentes en Xbps
  com.heroicgameslauncher.hgl
  net.pcsx2.PCSX2
  net.rpcs3.RPCS3

  # Mensajería / social
  dev.vencord.Vesktop
  com.rtosta.zapzap

  # Sistema / rendimiento
  io.github.benjamimgois.goverlay
  org.localsend.localsend_app
  org.vinegarhq.Sober
)

echo "==> Instalando ${#FLATPAK_APPS[@]} apps Flatpak..."
# -y / --noninteractive: sin prompts (idempotente: ya instaladas se omiten)
flatpak install -y --noninteractive flathub "${FLATPAK_APPS[@]}"

# -----------------------------------------------------------------------------
# 4) Resumen
# -----------------------------------------------------------------------------
echo
echo "============================================================"
echo " Instalación completada."
echo " XBPS : ${#XBPS_PKGS[@]} paquetes  |  Flatpak: ${#FLATPAK_APPS[@]} apps"
echo " Notas:"
echo "  - OBS en Void: paquete 'obs' (no 'obs-studio')"
echo "  - LibreOffice en Void: 'libreoffice' (no -still/-fresh)"
echo "  - qView / melonDS: nombres con mayúsculas tal cual"
echo "  - PSeInt: sin paquete en Xbps ni Flathub (compilar desde fuente)"
echo "  - steam usa nonfree + multilib (habilitados arriba)"
echo "============================================================"
