#!/usr/bin/env bash
# ============================================================================
#  Ryoku for Void Linux / Neko Void — port del instalador de la shell
# ----------------------------------------------------------------------------
#  Port de la shell de Ryoku (Hyprland + Quickshell + daemons Go) a sistemas
#  Void con xbps + runit. NO es el ISO ni el repositorio firmado [ryoku]:
#  compila los componentes desde el monorepo (github.com/ryoku-dev/ryoku) y
#  adapta autostart/materialización para que no dependa de systemd.
#
#  Componentes que instala:
#    * Hyprland (repo binario comunitario void-land/hyprland-void-packages)
#    * quickshell reconstruido con soporte Hyprland (vía xbps-src)
#    * matugen, y todo el runtime (pipewire, portal, grim, cliphist, ...)
#    * ryoku-shell / ryoku-hub / ryogami / ryoku (CLI) / ryoku-blobs,
#      compilados del monorepo con Go + CMake
#    * config base en /usr/share/ryoku/config y materialización en ~/.config
#    * entrada de sesión "Ryoku" para el display manager (wayland-sessions)
#
#  Lo que NO porta (dependencias de Arch): repositorio [ryoku] firmado,
#  actualizaciones automáticas, snapshots (snapper), plugins de Hyprland,
#  gpk, greeter SDDM de weston, units de systemd.
#
#  Uso (en la máquina Void, como root):
#      sudo bash ryoku-void-install.sh                 # instalación completa
#      sudo bash ryoku-void-install.sh --update        # rebuild desde git
#      sudo bash ryoku-void-install.sh --user=pepe     # otro usuario
#      sudo bash ryoku-void-install.sh --skip-quickshell   # reusar quickshell ya portado
# ============================================================================
set -euo pipefail

# --- argumentos --------------------------------------------------------------
MODE=install            # install | update
SKIP_QS=0
TUSER="${SUDO_USER:-}"
[ -n "$TUSER" ] || TUSER="$(id -un)"
for a in "$@"; do
  case "$a" in
    --update) MODE=update ;;
    --skip-quickshell) SKIP_QS=1 ;;
    --user=*) TUSER="${a#--user=}" ;;
    --help|-h)
      sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "argumento desconocido: $a (--help)"; exit 1 ;;
  esac
done

# --- helpers -----------------------------------------------------------------
c_good=$'\e[1;32m'; c_warn=$'\e[1;33m'; c_bad=$'\e[1;31m'; c_dim=$'\e[2m'; c_end=$'\e[0m'
log()  { echo "${c_good}==>${c_end} $*"; }
warn() { echo "${c_warn}!!${c_end} $*"; }
err()  { echo "${c_bad}XX${c_end} $*" >&2; }
die()  { err "$*"; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "falta '$1'"; }

REPO=https://github.com/ryoku-dev/ryoku
HYPR_REPO='https://github.com/void-land/hyprland-void-packages/releases/latest/download/'

# --- preflight ---------------------------------------------------------------
log "Preflight (modo: $MODE, usuario objetivo: $TUSER)"
[ "$(id -u)" -eq 0 ] || die "ejecuta como root: sudo bash $0"
need xbps-install || die "esto no parece Void (no hay xbps)"
need xbps-query  || die "falta xbps-query"
[ "$(uname -m)" = x86_64 ] || die "Ryoku solo soporta x86_64"
if [ "$(readlink /proc/1/exe 2>/dev/null || true)" = "/usr/lib/systemd/systemd" ]; then
  die "detectado systemd como init; este port es para Void con runit (o Neko Void)"
fi
grep -q runit /proc/1/comm 2>/dev/null || [ -d /run/runit ] || \
  warn "no veo runit como init (¿runit? ¿vsv?). Continuo, pero revisa el arranque."
id "$TUSER" >/dev/null 2>&1 || die "no existe el usuario '$TUSER'"
THOME="$(getent passwd "$TUSER" | cut -d: -f6)"
[ -n "$THOME" ] || die "sin home para '$TUSER'"
RYOKU_DIR="$THOME/ryoku"                    # checkout del monorepo
POOL_DIR="$THOME/ryoku-void-build"          # xbps-src pool
STAGE="$THOME/ryoku-void-stage"             # binarios compilados
LOCAL_BIN="$POOL_DIR/void-packages/hostdir/binpkgs"   # repo local xbps
need git || die "falta git"
need curl || die "falta curl"
for t in go cmake ninja; do
  command -v "$t" >/dev/null 2>&1 || warn "falta '$t' (se instala en la Etapa 1)"
done

run_as_user() { su - "$TUSER" -c "$1"; }

# ----------------------------------------------------------------------------
# Etapa 1: sistema (Hyprland + runtime) — xbps
# ----------------------------------------------------------------------------
stage_system() {
  log "Etapa 1/6 — paquetes de sistema (xbps)"
  mkdir -p /etc/xbps.d
  if [ ! -f /etc/xbps.d/ryoku-hyprland-repo.conf ]; then
    log "Añadiendo repo binario de Hyprland (void-land)"
    echo "repository=$HYPR_REPO" > /etc/xbps.d/ryoku-hyprland-repo.conf
  fi
  xbps-install -Sy || true   # refresca repos; pedirá aceptar la huella del repo Hyprland

  # núcleo del compositor (Hyprland + protocolos) desde el repo binario
  HYPR_PKGS="hyprland hyprland-protocols hyprwayland-scanner hyprutils hyprlang \
             hyprcursor aquamarine hypridle hyprlock hyprsunset \
             xdg-desktop-portal-hyprland hyprpolkitagent"
  if ! xbps-install -y $HYPR_PKGS >/dev/null 2>&1; then
    warn "falló instalar Hyprland desde void-land; pruebo el repo de Makrennel"
    echo 'repository=https://raw.githubusercontent.com/Makrennel/hyprland-void/repository-x86_64-glibc' \
      > /etc/xbps.d/ryoku-hyprland-repo.conf
    xbps-install -Sy || true
    if ! xbps-install -y $HYPR_PKGS >/dev/null 2>&1; then
      warn "los binarios (void-land/Makrennel) no resuelven contra esta snapshot (shlibs) —"
      warn "construyo el stack Hyprland desde templates con xbps-src."
      stage_hyprland_source
    fi
  fi
  need Hyprland || die "Hyprland no quedó en PATH"

  # runtime que la shell llama por nombre (+ herramientas de día uno)
  RUNTIME_PKGS="$(printf '%s\n' \
    base-devel git go cmake ninja python3 \
    qt6-base qt6-declarative qt6-multimedia qt6-shadertools \
    qt6-base-devel qt6-declarative-devel qt6-multimedia-devel qt6-shadertools-devel \
    wayland-devel wayland-protocols \
    pipewire wireplumber rtkit \
    matugen jq curl ImageMagick ffmpeg ffmpeg6-devel inotify-tools \
    grim slurp wl-clipboard cliphist playerctl \
    mpv yt-dlp cava python3-pip \
    tesseract zbar wf-recorder wtype libqalculate \
    brightnessctl upower \
    xdg-desktop-portal-gtk xdg-utils \
    gnome-keyring polkit dbus elogind \
    openrgb)"
  # TLP ya provee power-profiles-daemon en Neko Void (conflicto si ambos)
  xbps-query -p pkgver tlp-pd >/dev/null 2>&1 \
    || RUNTIME_PKGS="$RUNTIME_PKGS power-profiles-daemon"
  xbps-install -y $RUNTIME_PKGS 2>/dev/null || \
  xbps-install -y $RUNTIME_PKGS || \
    die "falló instalar paquetes de sistema. Revisa $RUNTIME_PKGS"
  # hyprpicker aparte: el repo principal lo ofrece más nuevo y ese candato
  # arrastra hyprutils@main (shlib .so.10) que rompe el stack local; se instala
  # SOLO desde el repo local compilado y se fija en hold con todo el stack.
  log "  hyprpicker desde el repo local (congruente con el stack Hyprland)"
  xbps-install -yR "$LOCAL_BIN" hyprpicker 2>/dev/null || \
    xbps-install -yR "$LOCAL_BIN" hyprpicker || \
    warn "  hyprpicker no instalado desde el repo local; instálalo a mano si falta"
  command -v hyprpicker >/dev/null 2>&1 || warn "  aviso: 'hyprpicker' no está en PATH aún"
  log "  fijando en hold el stack Hyprland local (que main no lo reemplace)"
  xbps-pkgdb -m hold \
    hyprland hyprland-protocols hyprwayland-scanner hyprutils hyprgraphics \
    hyprlang hyprcursor aquamarine hyprpicker hypridle hyprlock hyprsunset \
    xdg-desktop-portal-hyprland hyprpolkitagent 2>/dev/null || true

  # fuentes (algunas pueden no existir en void; se avisan pero no abortan)
  for f in inter-font noto-fonts noto-fonts-cjk noto-fonts-emoji \
           jetbrains-mono-nerd-fonts papirus-icon-theme; do
    xbps-install -y "$f" >/dev/null 2>&1 || warn "fuente/tema '$f' no instalado (opcional)"
  done

  # iconos de Material Symbols (ligaduras de la barra): se descargan a ~/.local/share/fonts
  if [ ! -f "$THOME/.local/share/fonts/MaterialSymbolsRounded.ttf" ]; then
    log "Descargando Material Symbols Rounded (iconos de la barra)"
    mkdir -p "$THOME/.local/share/fonts"
    curl -fsSL -o "$THOME/.local/share/fonts/MaterialSymbolsRounded.ttf" \
      "https://raw.githubusercontent.com/google/material-design-icons/master/variablefont/MaterialSymbolsRounded%5BFILL%2CGRAD%2Copsz%2Cwght%5D.ttf" \
      && run_as_user "fc-cache -f >/dev/null 2>&1" \
      || warn "no se pudo bajar Material Symbols; los iconos saldrán como ligaduras de texto"
    chown -R "$TUSER:" "$THOME/.local/share/fonts"
  fi
}

# ----------------------------------------------------------------------------
# Etapa 1b: Hyprland desde source (templates makrennel/hyprland-void)
#   Los repos binarios se construyen contra snapshots antiguas de Void y sus
#   shlibs (libfmt.so.9, libjxl.so.0.11, libhyprutils.so.6...) no resuelven
#   contra el Void actual (fmt 12, libjxl 0.12). Compilar desde los templates
#   del mismo mantenedor garantiza coherencia con la snapshot instalada.
# ----------------------------------------------------------------------------
stage_hyprland_source() {
  log "Etapa 1b/6 — Hyprland: build desde source (makrennel/hyprland-void)"
  if command -v Hyprland >/dev/null 2>&1 && [ -n "$(xbps-query -p pkgver hyprland 2>/dev/null)" ]; then
    log "  Hyprland ya está instalado; salto el build"
    log "  usando el repo local compilado ($LOCAL_BIN) para Hyprland"
    echo "repository=$LOCAL_BIN" > /etc/xbps.d/ryoku-hyprland-repo.conf
    return
  fi
  mkdir -p "$POOL_DIR"
  chown -R "$TUSER:" "$POOL_DIR"
  if [ ! -d "$POOL_DIR/void-packages" ]; then
    run_as_user "git clone --depth=1 https://github.com/void-linux/void-packages $POOL_DIR/void-packages"
  fi
  local HTPL="$POOL_DIR/hyprland-void"
  if [ ! -d "$HTPL/.git" ]; then
    run_as_user "git clone --depth=1 https://github.com/Makrennel/hyprland-void $HTPL"
  else
    run_as_user "cd $HTPL && git pull --ff-only >/dev/null 2>&1 || true"
  fi
  run_as_user "cd '$POOL_DIR/void-packages' && for d in '$HTPL'/srcpkgs/*/; do rm -rf \"srcpkgs/\$(basename \"\$d\")\"; cp -a \"\$d\" srcpkgs/; done"
  log "  registrando los sonames del stack en common/shlibs (sin pisar los de upstream)"
  run_as_user "cd '$POOL_DIR/void-packages' && \
    awk -F' ' 'NR==FNR { b=\$1; sub(/\\.so\\.[0-9].*\$/,\"\",b); keep[b]; next }
             { b=\$1; sub(/\\.so\\.[0-9].*\$/,\"\",b); if (!(b in keep)) print }' \
       '$HTPL/common/shlibs' common/shlibs > common/shlibs.ryoku && \
    mv common/shlibs.ryoku common/shlibs && \
    cat '$HTPL/common/shlibs' >> common/shlibs && \
    sort -u -o common/shlibs common/shlibs"
  run_as_user "cd '$POOL_DIR/void-packages' && if [ -f srcpkgs/hyprpicker/template ]; then sed -i '0,/^revision=[0-9]*/s//revision=3/' srcpkgs/hyprpicker/template; fi"
  run_as_user "cd '$POOL_DIR/void-packages' && sed -i 's/^  tomlplusplus$/  tomlplusplus-devel/' srcpkgs/hyprcursor/template"
  run_as_user "cd '$POOL_DIR/void-packages' && sed -i 's/^  tomlplusplus$/  tomlplusplus-devel/' srcpkgs/hyprland/template && \
    grep -q '^  hyprland-protocols$' srcpkgs/hyprland/template || sed -i 's/^  wayland-protocols$/  wayland-protocols\\n  hyprland-protocols/' srcpkgs/hyprland/template"
  log "  bootstrap del masterdir de xbps-src (una vez, descarga la base)"
  run_as_user "cd $POOL_DIR/void-packages && ./xbps-src binary-bootstrap" || \
    die "falló binary-bootstrap. Alternativa: sudo ./xbps-src binary-bootstrap en $POOL_DIR/void-packages"
  log "  compilando el stack Hyprland (puede tardar 30-60 min)"
  for p in hyprland-protocols hyprwayland-scanner hyprutils hyprgraphics hyprlang \
           hyprcursor aquamarine hyprpicker hyprland hypridle hyprlock hyprsunset \
           xdg-desktop-portal-hyprland hyprpolkitagent; do
    log "    xbps-src pkg $p"
    run_as_user "cd $POOL_DIR/void-packages && ./xbps-src pkg $p" || \
      die "falló compilar $p. Log: $POOL_DIR/void-packages/error.log"
  done
  xbps-install -yR "$LOCAL_BIN" \
    hyprland hyprland-protocols hyprwayland-scanner hyprutils hyprgraphics hyprlang \
    hyprcursor aquamarine hyprpicker hypridle hyprlock hyprsunset \
    xdg-desktop-portal-hyprland hyprpolkitagent || \
    die "no se instaló Hyprland compilado desde $LOCAL_BIN"
  log "  Hyprland compilado e instalado OK"
  # los repos binarios remotos (void-land/Makrennel) se construyen contra snapshot
  # antiguas y sus shlibs no resuelven contra el Void actual; una vez compilado el
  # stack, el repo local ES la fuente (coherente con los paquetes instalados).
  log "  using SOLO el repo local compilado ($LOCAL_BIN) para Hyprland"
  echo "repository=$LOCAL_BIN" > /etc/xbps.d/ryoku-hyprland-repo.conf
}

# ----------------------------------------------------------------------------
# Etapa 2: reconstruir quickshell con soporte Hyprland (xbps-src)
# ----------------------------------------------------------------------------
stage_quickshell() {
  [ "$SKIP_QS" = 1 ] && { log "Etapa 2/6 — quickshell: saltado (--skip-quickshell)"; return; }
  log "Etapa 2/6 — reconstruyendo quickshell con HYPRLAND=ON (compila Qt, tarda)"
  if xbps-query -p pkgver quickshell 2>/dev/null | grep -q '_2'; then
    log "  ya está el quickshell portado (revisión _2); salto el build"
    return
  fi
  mkdir -p "$POOL_DIR"
  chown -R "$TUSER:" "$POOL_DIR"
  if [ ! -d "$POOL_DIR/void-packages" ]; then
    run_as_user "git clone --depth=1 https://github.com/void-linux/void-packages $POOL_DIR/void-packages"
  fi
  TPL="$POOL_DIR/void-packages/srcpkgs/quickshell/template"
  # fuerza HYPRLAND=ON y sube la revisión para que xbps la prefiera al repo
  run_as_user "cd $POOL_DIR/void-packages && \
     git reset --hard HEAD >/dev/null 2>&1; \
     sed -i 's/^revision=[0-9]*/revision=2/' $TPL; \
     sed -i 's/-DCPPTRACE_SIGNAL_SAFE_UNWIND=0/-DCPPTRACE_SIGNAL_SAFE_UNWIND=0 -DHYPRLAND=ON/' $TPL; \
     grep -q 'wayland-protocols' $TPL || sed -i 's/hostmakedepends=\"pkg-config wayland-devel/hostmakedepends=\"pkg-config wayland-devel wayland-protocols/' $TPL"
  log "  bootstrap del masterdir de xbps-src (una vez, descarga base)"
  run_as_user "cd $POOL_DIR/void-packages && ./xbps-src binary-bootstrap" || \
    die "falló binary-bootstrap. Sin user namespaces usa: cd $POOL_DIR/void-packages && sudo ./xbps-src binary-bootstrap"
  log "  compilando quickshell (puede tardar 10-30 min)"
  run_as_user "cd $POOL_DIR/void-packages && ./xbps-src pkg quickshell" || \
    die "falló compilar quickshell. Revisa el log en '$POOL_DIR/void-packages/error.log'"
  xbps-install -yR "$LOCAL_BIN" quickshell || die "no se instaló quickshell desde $LOCAL_BIN"
  xbps-pkgdb -m hold quickshell 2>/dev/null || true   # que una subida de Void no lo revierta
  log "  quickshell instalado con Hyprland (revisión _2, en hold)"
}

# ----------------------------------------------------------------------------
# Etapa 3: compilar componentes de Ryoku desde el monorepo
# ----------------------------------------------------------------------------
stage_ryoku_build() {
  log "Etapa 3/6 — compilando los componentes de Ryoku (Go + CMake)"
  if [ ! -d "$RYOKU_DIR/.git" ]; then
    run_as_user "git clone --depth=1 $REPO $RYOKU_DIR"
  else
    run_as_user "cd $RYOKU_DIR && git pull --ff-only 2>/dev/null || true" || warn "git pull falló"
  fi
  mkdir -p "$STAGE/bin"
  chown -R "$TUSER:" "$STAGE"

  b() { # b <nombre> <dir go> [salida]
    local name="$1" dir="$2" out="${3:-$STAGE/bin/$1}"
    log "  go build $name"
    run_as_user "cd $RYOKU_DIR/$dir && CGO_ENABLED=0 go build -trimpath -o '$out' ." \
      || die "falló compilar $name"
  }
  b ryoku-shell  ryoku/shell/ipc
  b ryoku        ryoku/cli
  b ryoku-hub    ryoku/hub/backend
  b ryogami      ryoku/shell/ryogami/daemon

  log "  build ryoku-livewall / ryogami-live (C + wayland)"
  run_as_user "cd $RYOKU_DIR && bash ryoku/shell/livewall/build.sh '$STAGE/bin/ryoku-livewall'" || die "livewall"
  run_as_user "cd $RYOKU_DIR && bash ryoku/shell/livewall/build.sh '$STAGE/bin/ryogami-live'" || die "ryogami-live"

  log "  build ryoku-blobs (plugin QML Qt6)"
  run_as_user "cd $RYOKU_DIR && RYOKU_BLOBS_BUILD='$STAGE/blobs-build' bash ryoku/shell/plugin/build.sh '$STAGE/blobs-qml'" \
    || die "falló compilar ryoku-blobs"

  log "  go helpers de las apps (ryovm-fetch, ...)"
  while IFS= read -r gomod; do
    [ -f "$RYOKU_DIR/$gomod" ] || continue
    local dir mod
    dir="$(dirname "$gomod")" mod="$(grep -E '^module[[:space:]]+' "$RYOKU_DIR/$gomod" | head -1 | awk '{print $2}')"
    [ -n "$mod" ] || continue
    run_as_user "cd '$RYOKU_DIR/$dir' && go build -trimpath -o '$STAGE/bin/$mod' ." 2>/dev/null \
      && log "    helper: $mod" || warn "    no compiló helper $mod (se omite)"
  done < <(cd "$RYOKU_DIR" && git ls-files '*/go.mod' 2>/dev/null || true)
}

# ----------------------------------------------------------------------------
# Etapa 4: instalar en el sistema (root) — /usr/local, /usr/share, QML
# ----------------------------------------------------------------------------
install_config_base() {
  # monta /usr/share/ryoku/config espejando ~/.config (como ryoku-desktop)
  local cfg="/usr/share/ryoku/config"
  rm -rf "$cfg"; mkdir -p "$cfg"
  cp -a "$RYOKU_DIR/ryoku/hyprland/."           "$cfg/hypr/"
  cp -a "$RYOKU_DIR/ryoku/shell/quickshell/."   "$cfg/quickshell/"
  mkdir -p "$cfg/quickshell/hub"
  cp -a "$RYOKU_DIR/ryoku/hub/quickshell/."     "$cfg/quickshell/hub/"
  install -Dm644 "$RYOKU_DIR/ryoku/shell/portals/hyprland-portals.conf" \
    "$cfg/xdg-desktop-portal/hyprland-portals.conf"
  cp -a "$RYOKU_DIR/ryoku/shell/matugen/."      "$cfg/matugen/"
  # apps (quickshell trees + helpers + desktop + icon)
  for appdir in "$RYOKU_DIR"/ryoku/apps/*/; do
    [ -d "$appdir" ] || continue
    an="$(basename "$appdir")"
    [ -d "$appdir/quickshell" ] && { mkdir -p "$cfg/quickshell/$an"; cp -a "$appdir/quickshell/." "$cfg/quickshell/$an/"; }
    if [ -d "$appdir/bin" ]; then for b in "$appdir/bin"/*; do [ -f "$b" ] && install -Dm755 "$b" /usr/local/bin/; done; fi
    for d in "$appdir"*.desktop; do [ -f "$d" ] && install -Dm644 "$d" /usr/share/applications/; done
    icn="$appdir/quickshell/logo.svg"; [ -f "$icn" ] || icn="$appdir/logo.svg"
    [ -f "$icn" ] || icn="$RYOKU_DIR/ryoku/assets/brand/logo-mark.svg"
    install -Dm644 "$icn" "/usr/share/icons/hicolor/scalable/apps/$an.svg"
  done
  # configs por app
  install -Dm644 "$RYOKU_DIR/ryoku/apps/fish/config.fish"       "$cfg/fish/config.fish"
  install -Dm644 "$RYOKU_DIR/ryoku/shell/qt6ct/qt6ct.conf"      "$cfg/qt6ct/qt6ct.conf"
  install -Dm644 "$RYOKU_DIR/ryoku/apps/terminal-shell/env.sh"  "$cfg/ryoku-terminal/env.sh"
  install -Dm644 "$RYOKU_DIR/ryoku/apps/bash/ryoku.bash"        "$cfg/bash/ryoku.bash"
  install -Dm644 "$RYOKU_DIR/ryoku/apps/zsh/ryoku.zsh"          "$cfg/zsh/ryoku.zsh"
  # GTK toolkit baseline, si existe
  for gtk in "$RYOKU_DIR"/ryoku/shell/gtk/*; do
    [ -f "$gtk" ] || continue
    install -Dm644 "$gtk" "$cfg/gtk/$(basename "$gtk")"
  done
  # /etc/ryoku-release
  install -Dm644 /dev/stdin /etc/ryoku-release <<EOF
RELEASE=local-void-$(date +%Y%m%d)
NAME=$(tr -d '[:space:]' < "$RYOKU_DIR/CODENAME" 2>/dev/null || echo ryoku)
CHANNEL=void-local
VERSION=$(git -C "$RYOKU_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)
DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

stage_install_files() {
  log "Etapa 4/6 — instalando binarios, QML y configuración base"
  install -Dm755 "$STAGE/bin/ryoku-shell"    /usr/local/bin/ryoku-shell
  install -Dm755 "$STAGE/bin/ryoku"          /usr/local/bin/ryoku
  install -Dm755 "$STAGE/bin/ryoku-hub"      /usr/local/bin/ryoku-hub
  install -Dm755 "$STAGE/bin/ryogami"        /usr/local/bin/ryogami
  install -Dm755 "$STAGE/bin/ryoku-livewall" /usr/local/bin/ryoku-livewall
  install -Dm755 "$STAGE/bin/ryogami-live"   /usr/local/bin/ryogami-live
  for h in "$STAGE/bin"/*; do
    case "$(basename "$h")" in
      ryoku-shell|ryoku|ryoku-hub|ryogami|ryoku-livewall|ryogami-live) ;;
      *) install -Dm755 "$h" /usr/local/bin/ 2>/dev/null || true ;;
    esac
  done
  # scripts auxiliares + reload-cover
  install -Dm755 "$RYOKU_DIR/ryoku/shell/scripts/ryoku-reload-cover" /usr/local/bin/ryoku-reload-cover
  install -Dm755 "$RYOKU_DIR/ryoku/shell/scripts/ryostage"           /usr/local/bin/ryostage
  install -Dm755 "$RYOKU_DIR/ryoku/shell/scripts/ryoku-eq"           /usr/local/bin/ryoku-eq
  # leaf scripts de hyprland (ryoku-app, ryoku-cmd-*, ryoku-summon, ...) que los
  # binds y la shell llaman por nombre; en Arch van al bindir vía deploy.sh
  for hys in "$RYOKU_DIR"/ryoku/hyprland/scripts/ryoku-*; do
    [ -f "$hys" ] && install -Dm755 "$hys" /usr/local/bin/ 2>/dev/null || true
  done
  rm -rf /usr/share/ryoku/reload-cover
  install -d /usr/share/ryoku
  cp -a "$RYOKU_DIR/ryoku/shell/quickshell/reload-cover/." /usr/share/ryoku/reload-cover/
  # módulos QML (Blobs + PluginKit + Ui + FrameBars)
  rm -rf /usr/lib/qt6/qml/Ryoku
  install -d /usr/lib/qt6/qml/Ryoku
  cp -a "$STAGE/blobs-qml/Ryoku/Blobs/."          /usr/lib/qt6/qml/Ryoku/Blobs/
  cp -a "$RYOKU_DIR/ryoku/shell/quickshell/plugins/kit/." /usr/lib/qt6/qml/Ryoku/PluginKit/
  cp -a "$RYOKU_DIR/ryoku/ui/."                   /usr/lib/qt6/qml/Ryoku/Ui/
  cp -a "$RYOKU_DIR/ryoku/shell/framebars/."      /usr/lib/qt6/qml/Ryoku/FrameBars/
  rm -f /usr/lib/qt6/qml/Ryoku/Ui/install.sh /usr/lib/qt6/qml/Ryoku/FrameBars/install.sh
  rm -rf /usr/lib/qt6/qml/Ryoku/Ui/__pycache__
  chmod -R u=rwX,go=rX /usr/lib/qt6/qml/Ryoku
  # ryogami wall-ui
  rm -rf /usr/share/ryogami
  install -d /usr/share/ryogami
  cp -a "$RYOKU_DIR/ryoku/shell/ryogami/wall-ui/." /usr/share/ryogami/
  install -Dm644 "$RYOKU_DIR/ryoku/shell/ryogami/wall-ui/data/ryogami-wall.desktop" \
    /usr/share/applications/ryogami-wall.desktop
  install -Dm644 "$RYOKU_DIR/ryoku/shell/ryogami/wall-ui/LICENSE" \
    /usr/share/licenses/ryogami/LICENSE
  # extension de tema para browser (host nativo)
  rm -rf /usr/share/ryoku/browser
  install -d /usr/share/ryoku/browser
  cp -a "$RYOKU_DIR/ryoku/browser/." /usr/share/ryoku/browser/ 2>/dev/null || true

  install_config_base
  log "  PATCH: autostart de Hyprland sin systemd (arranca ryoku-shell + ryogami en segundo plano)"
  python3 - <<'PY'
import re, pathlib
p = pathlib.Path('/usr/share/ryoku/config/hypr/modules/autostart.lua')
s = p.read_text()
pat = re.compile(r'hl\.exec_cmd\("dbus-update-activation-environment.*?"\)', re.S)
rep = ('hl.exec_cmd("dbus-update-activation-environment --systemd --all; '
       '(setsid /usr/local/bin/ryoku-shell daemon >/dev/null 2>&1 &); '
       '(setsid /usr/local/bin/ryogami >/dev/null 2>&1 &)")')
s, n = pat.subn(rep, s)
if n == 0:
    raise SystemExit('no se encontró la línea de autostart a parchear: revisa autostart.lua')
p.write_text(s)
print(f'   autostart.lua parcheado ({n} sustitución)')
PY
}

# ----------------------------------------------------------------------------
# Etapa 5: materializar ~/.config para el usuario
# ----------------------------------------------------------------------------
stage_materialize() {
  local target="$THOME"
  log "Etapa 5/6 — materializando ~/.config para $TUSER"
  if [ -x /usr/local/bin/ryoku ]; then
    if run_as_user "env RYOKU_CONFIG_BASE=/usr/share/ryoku/config /usr/local/bin/ryoku materialize"; then
      log "  materialize vía CLI OK"
      return
    fi
    warn "  ryoku materialize falló; uso la copia manual (equivalente en instalación nueva)"
  fi
  # copia manual: base -> ~/.config; las semillas generadas por la máquina
  # (monitors, gpu, keyboard, user...) solo se crean si aún no existen.
  run_as_user "mkdir -p '$target/.config'"
  sudo -u "$TUSER" bash -c '
    set -e
    base=/usr/share/ryoku/config; dest="$HOME/.config"
    mkdir -p "$dest"
    seeds="hypr/monitors.lua hypr/gpu.lua hypr/keyboard.lua hypr/user.lua
           fastfetch/config.jsonc kitty/current-theme.conf ghostty/config ghostty/ryoku-colors"
    # copia todo salvo las semillas (se tratan aparte)
    excl=()
    for seed in $seeds; do excl+=(--exclude="./$seed"); done
    ( cd "$base" && tar cf - "${excl[@]}" . ) | ( cd "$dest" && tar xf - )
    # semillas solo si ausentes
    for seed in $seeds; do
      if [ ! -e "$dest/$seed" ]; then
        mkdir -p "$dest/$(dirname "$seed")"
        cp -a "$base/$seed" "$dest/$seed" 2>/dev/null || true
      fi
    done
    echo "   copia manual completada en $dest"
  '
}

# ----------------------------------------------------------------------------
# Etapa 5 bis: bootstrap de Hyprland para Void.
# Hyprland 0.49 (build de void-packages) NO ejecuta config Lua: ignora
# hyprland.lua y genera un hyprland.conf vacío, así que la shell ryoku nunca
# arranca. Escribimos un hyprland.conf nativo que arranca el daemon de la shell
# y el wallpaper, con los atajos ryoku que tienen equivalente por CLI. El
# hyprland.lua se conserva para un futuro Hyprland con soporte Lua (0.50+).
# ----------------------------------------------------------------------------
stage_hyprland_bootstrap() {
  log "Etapa 5.5/6 — bootstrap Hyprland (sin Lua) + apps por defecto"
  run_as_user "mkdir -p '$THOME/.config/hypr' '$THOME/.config/ryoku'"
  sudo -u "$TUSER" bash -s <<'BOOTSTRAP'
set -e
dest="$HOME/.config"

cat > "$dest/hypr/hyprland.conf" <<'CONF'
# Ryoku on Void — Hyprland bootstrap (Hyprland 0.49, sin soporte de config Lua)
# Reemplaza lo que ryoku haría vía hyprland.lua. La config Lua completa sigue en
# ~/.config/hypr/hyprland.lua y se activará cuando el Hyprland de Void soporte Lua.

autogenerated = 0

monitor = ,preferred,auto,1

env = XCURSOR_THEME,Bibata-Gruvbox
env = XCURSOR_SIZE,24
env = HYPRCURSOR_THEME,Bibata-Gruvbox
env = HYPRCURSOR_SIZE,24
env = QT_QPA_PLATFORM,wayland
env = QT_QPA_PLATFORMTHEME,qt6ct
env = XDG_CURRENT_DESKTOP,Hyprland

# arranque de la shell ryoku (un solo proceso que dibuja toda la UI) + wallpaper
exec-once = setsid sh -c '/usr/local/bin/ryoku-shell daemon >/dev/null 2>&1 &'
exec-once = setsid sh -c '/usr/local/bin/ryogami >/dev/null 2>&1 &'
exec-once = hyprctl setcursor Bibata-Gruvbox 24

input {
  kb_layout = us
  follow_mouse = 1
  touchpad { natural_scroll = true }
}

general {
  gaps_in = 4
  gaps_out = 12
  border_size = 2
  col.active_border = rgba(b8bb26ee)
  col.inactive_border = rgba(282828aa)
  layout = dwindle
}

decoration {
  rounding = 10
  active_opacity = 1.0
  inactive_opacity = 1.0
  blur {
    enabled = true
    size = 6
    passes = 2
  }
  shadow {
    enabled = true
    range = 16
    render_power = 3
  }
}

animations {
  enabled = true
  bezier = myBezier, 0.05, 0.9, 0.1, 1.0
  animation = windows, 1, 7, myBezier
  animation = windowsOut, 1, 7, default, popin 80%
  animation = border, 1, 10, default
  animation = switch, 1, 6, default
  animation = workspaces, 1, 6, default
}

dwindle {
  pseudotile = true
  preserve_split = true
}

misc {
  disable_hyprland_logo = true
}

$mod = SUPER

bind = $mod, Return, exec, ryoku-app terminal
bind = $mod, E, exec, ryoku-app files
bind = $mod, B, exec, ryoku-app browser
bind = $mod, N, exec, ryoku-app editor
bind = $mod, L, exec, ryoku-shell lock
bind = $mod, comma, exec, ryoku-shell hub open
bind = $mod, W, exec, ryogami wallpaper ui
bind = $mod SHIFT, W, exec, ryogami wallpaper random
bind = $mod, C, killactive
bind = $mod, M, exit
bind = $mod, F, fullscreen
bind = $mod, Space, togglefloating
bind = $mod, G, togglegroup

bind = $mod, left, movefocus, l
bind = $mod, right, movefocus, r
bind = $mod, up, movefocus, u
bind = $mod, down, movefocus, d
bind = $mod SHIFT, left, movewindow, l
bind = $mod SHIFT, right, movewindow, r
bind = $mod SHIFT, up, movewindow, u
bind = $mod SHIFT, down, movewindow, d

bind = $mod, 1, workspace, 1
bind = $mod, 2, workspace, 2
bind = $mod, 3, workspace, 3
bind = $mod, 4, workspace, 4
bind = $mod, 5, workspace, 5
bind = $mod, 6, workspace, 6
bind = $mod, 7, workspace, 7
bind = $mod, 8, workspace, 8
bind = $mod, 9, workspace, 9
bind = $mod, 0, workspace, 10
bind = $mod SHIFT, 1, movetoworkspacesilent, 1
bind = $mod SHIFT, 2, movetoworkspacesilent, 2
bind = $mod SHIFT, 3, movetoworkspacesilent, 3
bind = $mod SHIFT, 4, movetoworkspacesilent, 4
bind = $mod SHIFT, 5, movetoworkspacesilent, 5
bind = $mod SHIFT, 6, movetoworkspacesilent, 6
bind = $mod SHIFT, 7, movetoworkspacesilent, 7
bind = $mod SHIFT, 8, movetoworkspacesilent, 8
bind = $mod SHIFT, 9, movetoworkspacesilent, 9
bind = $mod SHIFT, 0, movetoworkspacesilent, 10

bind = $mod, mouse_down, workspace, e+1
bind = $mod, mouse_up, workspace, e-1
bindm = $mod, mouse:272, movewindow
bindm = $mod, mouse:273, resizewindow

# SUPER+Espacio (launcher), SUPER+Tab (overview), SUPER+V (clipboard), SUPER+K
# (cheatsheet), SUPER+Escape (quicksettings)... requieren la config Lua.
CONF

cat > "$dest/ryoku/hypr.json" <<'JSON'
{
  "apps": {
    "terminal": "konsole",
    "files": "dolphin",
    "browser": "firefox",
    "editor": "konsole -e nano"
  }
}
JSON

echo "   hyprland.conf (bootstrap) y hypr.json escritos en $dest"
BOOTSTRAP
}

# ----------------------------------------------------------------------------
# Etapa 6: sesión, servicios runit y grupos
# ----------------------------------------------------------------------------
stage_session() {
  log "Etapa 6/6 — entrada de sesión 'Ryoku' + servicios"
  install -Dm644 /dev/stdin /usr/share/wayland-sessions/ryoku.desktop <<'EOF'
[Desktop Entry]
Name=Ryoku
Comment=Hyprland session with the Ryoku shell (Void port)
Exec=Hyprland
Type=Application
DesktopNames=Hyprland
EOF

  # servicios runit necesarios para una sesión Wayland con elogind/seatd
  for svc in dbus elogind polkitd seatd; do
    if [ -d "/etc/sv/$svc" ] && [ ! -L "/var/service/$svc" ]; then
      ln -s "/etc/sv/$svc" /var/service/$svc 2>/dev/null && log "  habilitado $svc (runit)" \
        || warn "  no se pudo habilitar $svc"
    fi
  done
  # grupos para acceso a hardware
  for g in seat video input _seatd seatd; do
    getent group "$g" >/dev/null 2>&1 && usermod -aG "$g" "$TUSER" 2>/dev/null && log "  $TUSER en grupo $g"
  done
  log "  'ryoku' en PATH de $TUSER (vía /usr/local/bin)"
  log "  recuerda: reinicia o vuelve a iniciar sesión para que los grupos apliquen"
}

# ----------------------------------------------------------------------------
run() {
  stage_system
  stage_quickshell
  stage_ryoku_build
  stage_install_files
  stage_materialize
  stage_hyprland_bootstrap
  stage_session
}

log "═══════════════════════════════════════════════════════════════════"
log " Ryoku para Void / Neko Void — inicio (modo: $MODE)"
log "═══════════════════════════════════════════════════════════════════"
run
log "───────────────────────────────────────────────────────────────────"
log "Instalación completada."
log "  1. Cierra sesión (o reinicia) para que apliquen grupos/servicios."
log "  2. En el gestor de entrada elige la sesión 'Ryoku' (Hyprland)."
log "     Si tu DM no la muestra: loguéate en MATE y ejecuta 'Hyprland'."
log "  3. Diagnóstico: journal -> /tmp/ryoku-void-install.log;"
log "     reinicio de la shell: 'ryoku reload'; versión: 'ryoku version'."
log "  4. Actualizar a la última main: sudo bash $0 --update"
log "───────────────────────────────────────────────────────────────────"