#!/usr/bin/env bash
# ============================================================================
#  Ryoku for Void Linux / Neko Void — port del instalador de la shell
# ----------------------------------------------------------------------------
#  Port de la shell de Ryoku (Hyprland + Quickshell + daemons Go) a sistemas
#  Void con xbps + runit + turnstile. NO es el ISO ni el repositorio firmado
#  [ryoku]: compila los componentes desde el monorepo
#  (github.com/Ryoku-dev/ryoku) y los ENTREGA como paquete nativo
#  `ryoku-desktop.xbps` en un repo local, en lugar de regar archivos sueltos.
#
#  Arquitectura (niveles del port oficial, manteniendo Hyprland):
#    * Hyprland moderno (0.50+, config Lua) compilado con CLANG/lld vía
#      xbps-src — Void trae GCC 14 y no se traga su C++23/26.
#    * Servicios de USUARIO supervisados por runit a través de turnstile:
#      ~/.config/service/{ryoku-shell,ryogami} + bin/ryoku-session-init en
#      exec-once. Sin watchdog root, sin rascar /proc de otros procesos.
#    * Sin shim global de systemctl (opción legada --with-systemctl-shim);
#      el monorepo lleva el seam runit (patches/0001-void-runit-init.patch).
#    * Paquete .xbps `ryoku-desktop` → /usr/bin + /usr/share/ryoku/config +
#      /usr/lib/qt6/qml/Ryoku; desinstalable con `xbps-remove ryoku-desktop`.
#    * Capa de overrides: /usr/share/ryoku/config (base) vs
#      ~/.config/ryoku/overrides (usuario, jamás se pisa).
#    * Snapshots Btrfs pre/post (opcional, ryoku-void-snapshot.sh) y
#      ryoku-boot-guard para reverter arranques fallidos (opt-in).
#
#  Componentes empaquetados:
#    * ryoku-shell, ryoku, ryoku-hub, ryogami, ryoku-livewall, ryogami-live,
#      helpers Go, plugin QML Ryoku/Blobs, módulos QML (PluginKit/Ui/FrameBars)
#    * quickshell reconstruido con -DHYPRLAND=ON (xbps-src, en hold)
#    * stack Hyprland completo desde source con Clang (fallback si los bins
#      de los repos no resuelven shlibs contra tu snapshot)
#    * config base en /usr/share/ryoku/config, materializada en ~/.config
#    * entrada de sesión "Ryoku" (wayland-sessions) con dbus-run-session
#
#  Uso (en la máquina Void, como root):
#      sudo bash ryoku-void-install.sh                   # instalación completa
#      sudo bash ryoku-void-install.sh --update           # rebuild + reempaquete
#      sudo bash ryoku-void-install.sh --user=pepe        # otro usuario
#      sudo bash ryoku-void-install.sh --force-config     # respeta: pisa configs
#                                                          # (con backup .bak)
#      sudo bash ryoku-void-install.sh --legacy-conf      # hyprland.conf en vez
#                                                          # de hyprland.lua
#      sudo bash ryoku-void-install.sh --with-systemctl-shim  # legado
#      sudo bash ryoku-void-install.sh --rebuild-blobs    # sólo ryoku-blobs
#      sudo bash ryoku-void-install.sh --skip-quickshell  # reusar quickshell
#      sudo bash ryoku-void-install.sh --no-snapshot      # sin snapshot btrfs
# ============================================================================
set -euo pipefail

# --- argumentos --------------------------------------------------------------
MODE=install            # install | update
SKIP_QS=0
FORCE_CONFIG=0
LEGACY_CONF=0
WITH_SHIM=0
REBUILD_BLOBS=0
NO_SNAPSHOT=0
TUSER="${SUDO_USER:-}"
[ -n "$TUSER" ] || TUSER="$(id -un)"

usage() { sed -n '2,47p' "$0" | sed 's/^# \{0,1\}//'; }

for a in "$@"; do
  case "$a" in
    --update) MODE=update ;;
    --skip-quickshell) SKIP_QS=1 ;;
    --force-config) FORCE_CONFIG=1 ;;
    --legacy-conf) LEGACY_CONF=1 ;;
    --with-systemctl-shim) WITH_SHIM=1 ;;
    --rebuild-blobs) REBUILD_BLOBS=1 ;;
    --no-snapshot) NO_SNAPSHOT=1 ;;
    --user=*) TUSER="${a#--user=}" ;;
    --help|-h) usage; exit 0 ;;
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

REPO=https://github.com/Ryoku-dev/ryoku
HYPR_REPO='https://github.com/void-land/hyprland-void-packages/releases/latest/download/'
SRCDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run_as_user() { su - "$TUSER" -c "$1"; }

# --- límite de memoria para xbps-src (evita OOM con4-6 GB) -------------------
# XBPS_MAKEJOBS lo lee xbps-src en el host: si la RAM total es <= 6 GB se
# fuerza 2 hilos (defecto xbps-src es nº de CPUs, que en 4 GB con Qt6/Hyprland
# dispara el OOM killer).
detect_makejobs() {
  if [ -n "${XBPS_MAKEJOBS:-}" ]; then
    log "XBPS_MAKEJOBS=$XBPS_MAKEJOBS (entorno)"
    return 0
  fi
  local mem_kb
  mem_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
  if [ "$mem_kb" -gt 0 ] && [ "$mem_kb" -le 6291456 ]; then
    export XBPS_MAKEJOBS=2
    log "RAM ${mem_kb} kB <= 6 GB -> XBPS_MAKEJOBS=2 (anti-OOM)"
  else
    log "RAM ${mem_kb} kB -> XBPS_MAKEJOBS defecto de xbps-src"
  fi
}

# --- toolchain Clang (Hyprland moderno necesita C++23/26; GCC 14 no llega) ---
CC_LANG=clang; CXX_LANG=clang++; LDFLAGS_LANG=""
detect_clang() {
  if command -v clang >/dev/null 2>&1 && command -v clang++ >/dev/null 2>&1; then
    if command -v ld.lld >/dev/null 2>&1; then LDFLAGS_LANG="-fuse-ld=lld"; fi
    log "toolchain: clang/clang++ ${LDFLAGS_LANG}"
  else
    warn "clang no está instalado; el stack se compilará con GCC (¿fallará en C++23?)."
    warn "instala con: sudo xbps-install -y clang lld"
    CC_LANG=""; CXX_LANG=""; LDFLAGS_LANG=""
  fi
}

# Inyecta el toolchain en un template de xbps-src (idempotente). xbps-src hace
# source del template también en la fase de build, así que un `export CC=...`
# a nivel de template llega a make/cmake.
clangize_template() {
  local tpl=$1
  [ -f "$tpl" ] || return 0
  [ -n "$CC_LANG" ] || return 0
  grep -q 'RYOKU_VOID_CLANG' "$tpl" && return 0
  sed -i "1i # RYOKU_VOID_CLANG (inyectado por ryoku-void-install)\nexport CC=${CC_LANG}\nexport CXX=${CXX_LANG}\nexport LDFLAGS=\"\${LDFLAGS:-} ${LDFLAGS_LANG}\"" "$tpl"
  # ¡Ojo! export CC=clang sólo funciona si clang EXISTE dentro del masterdir
  # de xbps-src: el chroot sólo instala lo que el template declara en
  # hostmakedepends (gcc viene en base-chroot, clang NO). Sin esta línea el
  # build falla con "clang: not found" en la fase de compilación.
  local dep
  for dep in clang lld; do
    if grep -E '^hostmakedepends\+?=' "$tpl" | grep -qw "$dep"; then
      continue   # ya declarado por el template upstream
    fi
    printf '# RYOKU_VOID_CLANG: toolchain dentro del chroot de xbps-src\nhostmakedepends+="%s"\n' " $dep" >>"$tpl"
  done
}

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
[ "$TUSER" != root ] || die "elige un usuario de escritorio (--user=), no root"
RYOKU_DIR="$THOME/ryoku"                    # checkout del monorepo
POOL_DIR="$THOME/ryoku-void-build"          # xbps-src pool
STAGE="$THOME/ryoku-void-stage"             # staging de compilación (pre-paquete)
TREE="$POOL_DIR/void-packages"              # árbol void-packages
BINPKGS="$TREE/hostdir/binpkgs"             # repo local xbps
PKG_OVERLAY="$SRCDIR/pkg/srcpkgs"           # plantilla ryoku-desktop de este repo
LOCAL_REPO_CONF=/etc/xbps.d/ryoku-local-repo.conf
need git || die "falta git"
need curl || die "falta curl"
for t in go cmake ninja; do
  command -v "$t" >/dev/null 2>&1 || warn "falta '$t' (se instala en la Etapa 1)"
done
detect_makejobs

# Snapshots Btrfs pre/post (opcional, módulo 2E).
SNAPSHOT="$SRCDIR/ryoku-void-snapshot.sh"
snapshot_pre()  { [ "$NO_SNAPSHOT" = 1 ] && return 0; [ -x "$SNAPSHOT" ] && "$SNAPSHOT" pre  || true; }
snapshot_post() { [ "$NO_SNAPSHOT" = 1 ] && return 0; [ -x "$SNAPSHOT" ] && "$SNAPSHOT" post || true; }

# ============================================================================
# Etapa 1: sistema (Hyprland + runtime) — xbps
# ============================================================================
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
      warn "construyo el stack Hyprland desde templates con xbps-src (Clang)."
      stage_hyprland_source
    fi
  fi
  need Hyprland || die "Hyprland no quedó en PATH"

  # runtime que la shell llama por nombre (+ herramientas de día uno).
  # turnstile es la base de los servicios de usuario (Etapa 6).
  RUNTIME_PKGS="$(printf '%s\n' \
    base-devel git go cmake ninja python3 clang lld \
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
    gnome-keyring polkit dbus elogind turnstile \
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
  if [ -d "$BINPKGS" ]; then
    log "  hyprpicker desde el repo local (congruente con el stack Hyprland)"
    xbps-install -yR "$BINPKGS" hyprpicker 2>/dev/null || \
      warn "  hyprpicker no instalado desde el repo local; instálalo a mano si falta"
  fi
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
# Etapa 1b: Hyprland desde source con CLANG (templates makrennel/hyprland-void)
#   Los repos binarios se construyen contra snapshots antiguas de Void y sus
#   shlibs (libfmt.so.9, libjxl.so.0.11, libhyprutils.so.6...) no resuelven
#   contra el Void actual (fmt 12, libjxl 0.12). Compilar desde los templates
#   del mismo mantenedor garantiza coherencia con la snapshot instalada — y
#   con Clang, porque GCC 14 no compila el C++23/26 de Hyprland moderno.
# ----------------------------------------------------------------------------
stage_hyprland_source() {
  log "Etapa 1b/6 — Hyprland: build desde source con Clang (Makrennel/hyprland-void)"
  if command -v Hyprland >/dev/null 2>&1 && [ -n "$(xbps-query -p pkgver hyprland 2>/dev/null)" ]; then
    log "  Hyprland ya está instalado; salto el build"
    if [ -d "$BINPKGS" ]; then
      log "  usando el repo local compilado ($BINPKGS) para Hyprland"
      echo "repository=$BINPKGS" > /etc/xbps.d/ryoku-hyprland-repo.conf
    fi
    return
  fi
  detect_clang
  mkdir -p "$POOL_DIR"
  chown -R "$TUSER:" "$POOL_DIR"
  if [ ! -d "$TREE" ]; then
    run_as_user "git clone --depth=1 https://github.com/void-linux/void-packages '$TREE'"
  fi
  local HTPL="$POOL_DIR/hyprland-void"
  if [ ! -d "$HTPL/.git" ]; then
    run_as_user "git clone --depth=1 https://github.com/Makrennel/hyprland-void '$HTPL'"
  else
    run_as_user "cd '$HTPL' && git pull --ff-only >/dev/null 2>&1 || true"
  fi
  run_as_user "cd '$TREE' && for d in '$HTPL'/srcpkgs/*/; do rm -rf \"srcpkgs/\$(basename \"\$d\")\"; cp -a \"\$d\" srcpkgs/; done"
  log "  registrando los sonames del stack en common/shlibs (sin pisar los de upstream)"
  run_as_user "cd '$TREE' && \
    awk -F' ' 'NR==FNR { b=\$1; sub(/\\.so\\.[0-9].*\$/,\"\",b); keep[b]; next }
             { b=\$1; sub(/\\.so\\.[0-9].*\$/,\"\",b); if (!(b in keep)) print }' \
       '$HTPL/common/shlibs' common/shlibs > common/shlibs.ryoku && \
    mv common/shlibs.ryoku common/shlibs && \
    cat '$HTPL/common/shlibs' >> common/shlibs && \
    sort -u -o common/shlibs common/shlibs"
  run_as_user "cd '$TREE' && if [ -f srcpkgs/hyprpicker/template ]; then sed -i '0,/^revision=[0-9]*/s//revision=3/' srcpkgs/hyprpicker/template; fi"
  run_as_user "cd '$TREE' && sed -i 's/^  tomlplusplus\$/  tomlplusplus-devel/' srcpkgs/hyprcursor/template"
  run_as_user "cd '$TREE' && sed -i 's/^  tomlplusplus\$/  tomlplusplus-devel/' srcpkgs/hyprland/template && \
    grep -q '^  hyprland-protocols\$' srcpkgs/hyprland/template || sed -i 's/^  wayland-protocols\$/  wayland-protocols\n  hyprland-protocols/' srcpkgs/hyprland/template"
  # CLANG en todos los templates del stack (GCC 14 no llega al C++23/26).
  local p
  for p in hyprland-protocols hyprwayland-scanner hyprutils hyprgraphics hyprlang \
           hyprcursor aquamarine hyprpicker hyprland hypridle hyprlock hyprsunset \
           xdg-desktop-portal-hyprland hyprpolkitagent; do
    clangize_template "$TREE/srcpkgs/$p/template"
  done
  log "  bootstrap del masterdir de xbps-src (una vez, descarga la base)"
  run_as_user "cd '$TREE' && ./xbps-src binary-bootstrap" || \
    die "falló binary-bootstrap. Alternativa: sudo ./xbps-src binary-bootstrap en '$TREE'"
  log "  compilando el stack Hyprland con Clang (puede tardar 30-90 min)"
  for p in hyprland-protocols hyprwayland-scanner hyprutils hyprgraphics hyprlang \
           hyprcursor aquamarine hyprpicker hyprland hypridle hyprlock hyprsunset \
           xdg-desktop-portal-hyprland hyprpolkitagent; do
    log "    xbps-src pkg $p"
    run_as_user "cd '$TREE' && ./xbps-src pkg $p" || \
      die "falló compilar $p. Log: '$TREE'/error.log"
  done
  xbps-install -yR "$BINPKGS" \
    hyprland hyprland-protocols hyprwayland-scanner hyprutils hyprgraphics hyprlang \
    hyprcursor aquamarine hyprpicker hypridle hyprlock hyprsunset \
    xdg-desktop-portal-hyprland hyprpolkitagent || \
    die "no se instaló Hyprland compilado desde '$BINPKGS'"
  log "  Hyprland compilado e instalado OK (Clang)"
  # los repos binarios remotos (void-land/Makrennel) se construyen contra
  # snapshots antiguas; una vez compilado el stack, el repo local ES la fuente.
  log "  usando SOLO el repo local compilado ($BINPKGS) para Hyprland"
  echo "repository=$BINPKGS" > /etc/xbps.d/ryoku-hyprland-repo.conf
}

# ----------------------------------------------------------------------------
# Etapa 2: reconstruir quickshell con soporte Hyprland (xbps-src + Clang)
# ----------------------------------------------------------------------------
stage_quickshell() {
  if [ "$SKIP_QS" = 1 ]; then log "Etapa 2/6 — quickshell: saltado (--skip-quickshell)"; return; fi
  log "Etapa 2/6 — reconstruyendo quickshell con HYPRLAND=ON (Clang, compila Qt, tarda)"
  if xbps-query -p pkgver quickshell 2>/dev/null | grep -q '_2'; then
    log "  ya está el quickshell portado (revisión _2); salto el build"
    return
  fi
  detect_clang
  mkdir -p "$POOL_DIR"
  chown -R "$TUSER:" "$POOL_DIR"
  if [ ! -d "$TREE" ]; then
    run_as_user "git clone --depth=1 https://github.com/void-linux/void-packages '$TREE'"
  fi
  local TPL="$TREE/srcpkgs/quickshell/template"
  # fuerza HYPRLAND=ON y sube la revisión para que xbps la prefiera al repo
  run_as_user "cd '$TREE' && \
     git reset --hard HEAD >/dev/null 2>&1; \
     sed -i 's/^revision=[0-9]*/revision=2/' '$TPL'; \
     sed -i 's/-DCPPTRACE_SIGNAL_SAFE_UNWIND=0/-DCPPTRACE_SIGNAL_SAFE_UNWIND=0 -DHYPRLAND=ON/' '$TPL'; \
     grep -q 'wayland-protocols' '$TPL' || sed -i 's/hostmakedepends=\"pkg-config wayland-devel/hostmakedepends=\"pkg-config wayland-devel wayland-protocols/' '$TPL'"
  clangize_template "$TPL"
  log "  bootstrap del masterdir de xbps-src (una vez, descarga base)"
  run_as_user "cd '$TREE' && ./xbps-src binary-bootstrap" || \
    die "falló binary-bootstrap. Sin user namespaces usa: cd '$TREE' && sudo ./xbps-src binary-bootstrap"
  log "  compilando quickshell (puede tardar 10-30 min)"
  run_as_user "cd '$TREE' && ./xbps-src pkg quickshell" || \
    die "falló compilar quickshell. Revisa el log en '$TREE'/error.log"
  xbps-install -yR "$BINPKGS" quickshell || die "no se instaló quickshell desde '$BINPKGS'"
  xbps-pkgdb -m hold quickshell 2>/dev/null || true   # que una subida de Void no lo revierta
  log "  quickshell instalado con Hyprland (revisión _2, en hold)"
}

# ----------------------------------------------------------------------------
# Etapa 3: compilar TODOS los componentes de Ryoku (Go + C + QML) -> $STAGE
#   Jerarquía única: todo cae en $STAGE/bin y de ahí el paquete lo lleva a
#   /usr/bin. Nada se instala a mano en /usr/local/bin.
# ----------------------------------------------------------------------------
stage_ryoku_build() {
  log "Etapa 3/6 — compilando los componentes de Ryoku (Go + C + QML)"
  if [ ! -d "$RYOKU_DIR/.git" ]; then
    run_as_user "git clone --depth=1 $REPO '$RYOKU_DIR'"
  else
    run_as_user "cd '$RYOKU_DIR' && git pull --ff-only 2>/dev/null || true" || warn "git pull falló"
  fi
  # Aplica el parche runit nativo si el monorepo no lo trae (2C).
  if [ -f "$SRCDIR/patches/0001-void-runit-init.patch" ]; then
    run_as_user "cd '$RYOKU_DIR' && git apply --check '$SRCDIR/patches/0001-void-runit-init.patch' >/dev/null 2>&1 && \
      git apply '$SRCDIR/patches/0001-void-runit-init.patch' && echo '   parche runit aplicado' || \
      echo '   parche runit ya aplicado o no aplicable (ok)'"
  fi
  mkdir -p "$STAGE/bin" "$STAGE/qml/Ryoku"
  chown -R "$TUSER:" "$STAGE"

  b() { # b <nombre> <dir go>
    local name="$1" dir="$2"
    log "  go build $name"
    run_as_user "cd '$RYOKU_DIR/$dir' && CGO_ENABLED=0 go build -trimpath -o '$STAGE/bin/$name' ." \
      || die "falló compilar $name"
  }
  b ryoku-shell  ryoku/shell/ipc
  b ryoku        ryoku/cli
  b ryoku-hub    ryoku/hub/backend
  b ryogami      ryoku/shell/ryogami/daemon

  log "  build ryoku-livewall / ryogami-live (C + wayland)"
  run_as_user "cd '$RYOKU_DIR' && bash ryoku/shell/livewall/build.sh '$STAGE/bin/ryoku-livewall'" || die "livewall"
  run_as_user "cd '$RYOKU_DIR' && bash ryoku/shell/livewall/build.sh '$STAGE/bin/ryogami-live'" || die "ryogami-live"

  stage_rebuild_blobs

  log "  go helpers de las apps (ryovm-fetch, ...)"
  while IFS= read -r gomod; do
    [ -f "$RYOKU_DIR/$gomod" ] || continue
    local dir mod
    dir="$(dirname "$gomod")" mod="$(grep -E '^module[[:space:]]+' "$RYOKU_DIR/$gomod" | head -1 | awk '{print $2}')"
    [ -n "$mod" ] || continue
    run_as_user "cd '$RYOKU_DIR/$dir' && CGO_ENABLED=0 go build -trimpath -o '$STAGE/bin/$mod' ." 2>/dev/null \
      && log "    helper: $mod" || warn "    no compiló helper $mod (se omite)"
  done < <(cd "$RYOKU_DIR" && git ls-files '*/go.mod' 2>/dev/null || true)
}

# Sólo el plugin QML (lo usa ryoku-void-heal.sh vía --rebuild-blobs).
stage_rebuild_blobs() {
  log "  build ryoku-blobs (plugin QML Qt6)"
  mkdir -p "$STAGE/qml/Ryoku" "$STAGE/blobs-build"
  chown -R "$TUSER:" "$STAGE"
  run_as_user "cd '$RYOKU_DIR' && RYOKU_BLOBS_BUILD='$STAGE/blobs-build' bash ryoku/shell/plugin/build.sh '$STAGE/qml'" \
    || die "falló compilar ryoku-blobs"
}

# ============================================================================
# Etapa 4: empaquetar como .xbps nativo (ryoku-desktop) e instalarlo
#   El payload se stagingea en FHS dentro de
#   srcpkgs/ryoku-desktop/files/payload (visible para xbps-src) y la plantilla
#   de este repo (pkg/srcpkgs) lo convierte en un paquete rastreable.
# ============================================================================
stage_package() {
  log "Etapa 4/6 — empaquetado nativo ryoku-desktop.xbps"
  mkdir -p "$POOL_DIR"
  chown -R "$TUSER:" "$POOL_DIR"
  if [ ! -d "$TREE" ]; then
    run_as_user "git clone --depth=1 https://github.com/void-linux/void-packages '$TREE'"
  fi
  if [ ! -d "$TREE/masterdir-x86_64" ]; then
    log "  bootstrap del masterdir de xbps-src (una vez)"
    run_as_user "cd '$TREE' && ./xbps-src binary-bootstrap" || \
      die "falló binary-bootstrap en '$TREE'"
  fi
  # Overlay: nuestra plantilla vive en el repo y se copia al árbol.
  rm -rf "$TREE/srcpkgs/ryoku-desktop"
  run_as_user "cp -a '$PKG_OVERLAY/.' '$TREE/srcpkgs/'"
  # Versión del paquete = describe del monorepo (estilo xbps: empieza por dígito).
  local ver
  ver="$(git -C "$RYOKU_DIR" describe --tags --always 2>/dev/null || true)"
  ver="$(printf '%s' "$ver" | sed 's/^[vV]//; s/[^A-Za-z0-9._+~-]/./g')"
  [ -n "$ver" ] || ver=0.0.0
  case $ver in [0-9]*) ;; *) ver="0.0.0_$ver" ;; esac
  log "  version del paquete: $ver"
  run_as_user "sed -i 's/^version=.*/version=$ver/' '$TREE/srcpkgs/ryoku-desktop/template'"

  stage_payload

  log "  compilando el paquete (xbps-src pkg ryoku-desktop — es prebuilt, rápido)"
  run_as_user "cd '$TREE' && ./xbps-src pkg ryoku-desktop" || {
    warn "falló xbps-src pkg ryoku-desktop (log: '$TREE'/error.log)"
    warn "modo legado: instalando archivos directamente en /usr/bin (sin rastreo)"
    stage_install_files_legacy
    return 0
  }
  log "  indexando repo local (xbps-rindex)"
  run_as_user "xbps-rindex -a '$BINPKGS'/*.xbps" || die "falló xbps-rindex"
  echo "repository=$BINPKGS" > "$LOCAL_REPO_CONF"
  log "  instalando/actualizando ryoku-desktop desde el repo local"
  xbps-install -yR "$BINPKGS" ryoku-desktop || \
    die "falló xbps-install -yR ryoku-desktop (¿conflicto con archivos de antes?)"
  log "  ryoku-desktop instalado: $(xbps-query -p pkgver ryoku-desktop 2>/dev/null || echo '?')"
}

# --- payload FHS --------------------------------------------------------------
stage_payload() {
  local PAY="$TREE/srcpkgs/ryoku-desktop/files/payload"
  local cfg="$PAY/usr/share/ryoku/config"
  log "  staging del payload en $PAY"
  rm -rf "$PAY"
  mkdir -p "$PAY/usr/bin" "$cfg" "$PAY/usr/lib/qt6/qml/Ryoku" \
           "$PAY/usr/lib/ryoku/runit" "$PAY/usr/share/ryoku" \
           "$PAY/usr/share/applications" "$PAY/usr/share/icons/hicolor/scalable/apps" \
           "$PAY/usr/share/wayland-sessions" "$PAY/usr/share/licenses/ryoku-desktop" \
           "$PAY/etc"

  # 1) binarios (todos: Go estáticos, livewall, helpers)
  local f
  for f in "$STAGE/bin"/*; do
    [ -f "$f" ] || continue
    install -Dm755 "$f" "$PAY/usr/bin/$(basename "$f")"
  done

  # 2) scripts del port (instalados junto al resto: jerarquía única)
  local s
  for s in ryoku-void-install ryoku-void-update ryoku-void-heal ryoku-void-snapshot; do
    [ -f "$SRCDIR/$s.sh" ] && install -Dm755 "$SRCDIR/$s.sh" "$PAY/usr/bin/$s"
  done
  for s in "$SRCDIR"/bin/*; do
    [ -f "$s" ] && install -Dm755 "$s" "$PAY/usr/bin/$(basename "$s")"
  done
  # ... y el material de mantenimiento en /usr/share/ryoku/port
  mkdir -p "$PAY/usr/share/ryoku/port"
  for s in rebuild-hypr-stack.sh systemctl-shim.sh void-setup.sh README.md; do
    [ -f "$SRCDIR/$s" ] && install -Dm644 "$SRCDIR/$s" "$PAY/usr/share/ryoku/port/$s"
  done
  [ -f "$SRCDIR/rebuild-hypr-stack.sh" ] && chmod 755 "$PAY/usr/share/ryoku/port/rebuild-hypr-stack.sh"

  # 3) definiciones de servicios de usuario (turnstile) + boot-guard
  if [ -d "$SRCDIR/runit/user" ]; then
    mkdir -p "$PAY/usr/lib/ryoku/runit/user"
    cp -a "$SRCDIR/runit/user/." "$PAY/usr/lib/ryoku/runit/user/"
    chmod 755 "$PAY/usr/lib/ryoku/runit/user"/*/run "$PAY/usr/lib/ryoku/runit/user"/*/finish 2>/dev/null || true
  fi
  if [ -d "$SRCDIR/runit/system" ]; then
    mkdir -p "$PAY/usr/lib/ryoku/runit/system"
    cp -a "$SRCDIR/runit/system/." "$PAY/usr/lib/ryoku/runit/system/"
    chmod 755 "$PAY/usr/lib/ryoku/runit/system"/*/run "$PAY/usr/lib/ryoku/runit/system"/*/finish 2>/dev/null || true
  fi

  # 4) módulos QML: Blobs (compilado) + PluginKit + Ui + FrameBars
  if [ -d "$STAGE/qml/Ryoku/Blobs" ]; then
    cp -a "$STAGE/qml/Ryoku/Blobs" "$PAY/usr/lib/qt6/qml/Ryoku/"
  else
    die "falta el plugin QML Ryoku/Blobs (stage_rebuild_blobs no corrió?)"
  fi
  cp -a "$RYOKU_DIR/ryoku/shell/quickshell/plugins/kit/." "$PAY/usr/lib/qt6/qml/Ryoku/PluginKit/"
  rm -f "$PAY/usr/lib/qt6/qml/Ryoku/PluginKit/install.sh"
  cp -a "$RYOKU_DIR/ryoku/ui/." "$PAY/usr/lib/qt6/qml/Ryoku/Ui/"
  rm -f "$PAY/usr/lib/qt6/qml/Ryoku/Ui/install.sh"
  rm -rf "$PAY/usr/lib/qt6/qml/Ryoku/Ui/__pycache__"
  cp -a "$RYOKU_DIR/ryoku/shell/framebars/." "$PAY/usr/lib/qt6/qml/Ryoku/FrameBars/"
  rm -f "$PAY/usr/lib/qt6/qml/Ryoku/FrameBars/install.sh" "$PAY"/usr/lib/qt6/qml/Ryoku/FrameBars/*.test.mjs 2>/dev/null || true

  # 5) config base en /usr/share/ryoku/config (espejo de ~/.config)
  cp -a "$RYOKU_DIR/ryoku/hyprland/."           "$cfg/hypr/"
  install -Dm644 "$RYOKU_DIR/ryoku/hyprland/hyprland-portals.conf" \
    "$cfg/xdg-desktop-portal/hyprland-portals.conf"
  cp -a "$RYOKU_DIR/ryoku/shell/quickshell/."   "$cfg/quickshell/"
  mkdir -p "$cfg/quickshell/hub"
  cp -a "$RYOKU_DIR/ryoku/hub/quickshell/."     "$cfg/quickshell/hub/"
  cp -a "$RYOKU_DIR/ryoku/shell/matugen/."      "$cfg/matugen/"
  # apps quickshell (ryostore, ryovm...) + sus binarios/.desktop/iconos
  local appdir an d icn
  for appdir in "$RYOKU_DIR"/ryoku/apps/*/; do
    [ -d "$appdir" ] || continue
    an="$(basename "$appdir")"
    [ -d "$appdir/quickshell" ] && { mkdir -p "$cfg/quickshell/$an"; cp -a "$appdir/quickshell/." "$cfg/quickshell/$an/"; }
    if [ -d "$appdir/bin" ]; then
      for d in "$appdir/bin"/*; do [ -f "$d" ] && install -Dm755 "$d" "$PAY/usr/bin/$(basename "$d")"; done
    fi
    for d in "$appdir"*.desktop; do [ -f "$d" ] && install -Dm644 "$d" "$PAY/usr/share/applications/$(basename "$d")"; done
    icn="$appdir/quickshell/logo.svg"; [ -f "$icn" ] || icn="$appdir/logo.svg"
    [ -f "$icn" ] || icn="$RYOKU_DIR/ryoku/assets/brand/logo-mark.svg"
    [ -f "$icn" ] && install -Dm644 "$icn" "$PAY/usr/share/icons/hicolor/scalable/apps/$an.svg"
    # helpers Go de la app
    local gomod helperdir helper
    for gomod in "${appdir}"*/go.mod; do
      [ -f "$gomod" ] || continue
      helperdir="$(dirname "$gomod")"
      helper="$(sed -n -E 's/^module[[:space:]]+//p' "$gomod" | head -1)"
      [ -n "$helper" ] || continue
      run_as_user "cd '$helperdir' && CGO_ENABLED=0 go build -trimpath -o '$PAY/usr/bin/$helper' ." \
        && log "    helper app: $helper" || warn "    helper app $helper no compiló"
    done
  done
  # configs por app
  [ -f "$RYOKU_DIR/ryoku/apps/fish/config.fish" ] && \
    install -Dm644 "$RYOKU_DIR/ryoku/apps/fish/config.fish" "$cfg/fish/config.fish"
  [ -f "$RYOKU_DIR/ryoku/shell/qt6ct/qt6ct.conf" ] && \
    install -Dm644 "$RYOKU_DIR/ryoku/shell/qt6ct/qt6ct.conf" "$cfg/qt6ct/qt6ct.conf"
  [ -f "$RYOKU_DIR/ryoku/apps/terminal-shell/env.sh" ] && \
    install -Dm644 "$RYOKU_DIR/ryoku/apps/terminal-shell/env.sh" "$cfg/ryoku-terminal/env.sh"
  [ -f "$RYOKU_DIR/ryoku/apps/bash/ryoku.bash" ] && \
    install -Dm644 "$RYOKU_DIR/ryoku/apps/bash/ryoku.bash" "$cfg/bash/ryoku.bash"
  [ -f "$RYOKU_DIR/ryoku/apps/zsh/ryoku.zsh" ] && \
    install -Dm644 "$RYOKU_DIR/ryoku/apps/zsh/ryoku.zsh" "$cfg/zsh/ryoku.zsh"
  # GTK baseline (xsettings-less Wayland)
  for gtk in "$RYOKU_DIR"/ryoku/shell/gtk-3.0/settings.ini "$RYOKU_DIR"/ryoku/shell/gtk-4.0/settings.ini; do
    [ -f "$gtk" ] && install -Dm644 "$gtk" "$cfg/$(basename "$(dirname "$gtk")")/settings.ini"
  done

  # 6) leaf scripts de la shell y de hyprland en /usr/bin (los binds llaman
  #    ryoku-app, ryoku-cmd-*, ryostage... por nombre)
  for s in "$RYOKU_DIR"/ryoku/shell/scripts/ryoku-* "$RYOKU_DIR"/ryoku/shell/scripts/stash-*.sh \
           "$RYOKU_DIR"/ryoku/hyprland/scripts/*; do
    [ -f "$s" ] || continue
    install -Dm755 "$s" "$PAY/usr/bin/$(basename "$s")"
  done

  # 7) reload-cover, extensión de navegador, assets, i18n
  if [ -d "$RYOKU_DIR/ryoku/shell/quickshell/reload-cover" ]; then
    cp -a "$RYOKU_DIR/ryoku/shell/quickshell/reload-cover" "$PAY/usr/share/ryoku/reload-cover"
  fi
  if [ -d "$RYOKU_DIR/ryoku/browser" ]; then
    mkdir -p "$PAY/usr/share/ryoku/browser"
    cp -a "$RYOKU_DIR/ryoku/browser/." "$PAY/usr/share/ryoku/browser/"
    rm -rf "$PAY/usr/share/ryoku/browser/dist"
  fi
  [ -d "$RYOKU_DIR/ryoku/assets/brand" ] && \
    cp -a "$RYOKU_DIR/ryoku/assets/brand" "$PAY/usr/share/ryoku/brand"
  if [ -d "$RYOKU_DIR/ryoku/i18n/catalog" ]; then
    mkdir -p "$PAY/usr/share/ryoku/i18n"
    cp -a "$RYOKU_DIR/ryoku/i18n/catalog/." "$PAY/usr/share/ryoku/i18n/"
    [ -f "$RYOKU_DIR/ryoku/i18n/langs.json" ] && \
      install -Dm644 "$RYOKU_DIR/ryoku/i18n/langs.json" "$PAY/usr/share/ryoku/i18n/langs.json"
  fi

  # 8) sesión Wayland (con dbus-run-session condicional) + desktop entries
  install -Dm755 "$SRCDIR/bin/ryoku-session-exec" "$PAY/usr/bin/ryoku-session-exec"
  install -Dm644 /dev/stdin "$PAY/usr/share/wayland-sessions/ryoku.desktop" <<'EOF'
[Desktop Entry]
Name=Ryoku
Comment=Hyprland session with the Ryoku shell (Void port)
Exec=ryoku-session-exec Hyprland
Type=Application
DesktopNames=Hyprland
EOF
  install -Dm644 /dev/stdin "$PAY/usr/share/applications/ryoku-hub.desktop" <<'EOF'
[Desktop Entry]
Name=Ryoku Hub
Comment=Ryoku settings and control panel
Exec=ryoku-hub
Terminal=false
Type=Application
Categories=Settings;System;
EOF
  [ -f "$RYOKU_DIR/ryoku/assets/brand/logo.svg" ] && \
    install -Dm644 "$RYOKU_DIR/ryoku/assets/brand/logo.svg" "$PAY/usr/share/icons/hicolor/scalable/apps/ryoku-hub.svg"
  [ -f "$RYOKU_DIR/ryoku/assets/brand/logo-mark.svg" ] && \
    install -Dm644 "$RYOKU_DIR/ryoku/assets/brand/logo-mark.svg" "$PAY/usr/share/icons/hicolor/scalable/apps/ryoku.svg"

  # 9) /etc/ryoku-release (estado de este build)
  local codename
  codename="$(tr -d '[:space:]' < "$RYOKU_DIR/CODENAME" 2>/dev/null || echo ryoku)"
  install -Dm644 /dev/stdin "$PAY/etc/ryoku-release" <<EOF
RELEASE=local-void-$(date +%Y%m%d)
NAME=$codename
CHANNEL=void-local
VERSION=$(git -C "$RYOKU_DIR" describe --tags --always 2>/dev/null || echo unknown)
DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

  # 10) licencias + permisos finales
  [ -f "$RYOKU_DIR/LICENSE" ] && install -Dm644 "$RYOKU_DIR/LICENSE" "$PAY/usr/share/licenses/ryoku-desktop/LICENSE"
  chmod -R u=rwX,go=rX "$PAY/usr/share" "$PAY/etc" 2>/dev/null || true
  find "$PAY/usr/bin" "$PAY/usr/lib/ryoku" -type f -exec chmod 755 {} + 2>/dev/null || true
}

# --- fallback legado (sin paquete): mismas rutas FHS, pero sin rastreo -------
stage_install_files_legacy() {
  local PAY="$TREE/srcpkgs/ryoku-desktop/files/payload"
  if [ ! -d "$PAY" ]; then
    stage_payload
  fi
  cp -a "$PAY/." /
  log "  payload copiado a / (recuerda: xbps no lo podrá desinstalar)"
}

# ============================================================================
# Etapa 5: materializar ~/.config para el usuario
#   Reglas del port:
#     * base  = /usr/share/ryoku/config   (del paquete, se refresca en updates)
#     * usuario = ~/.config               (NO se pisa salvo --force-config,
#                                          con backup .bak previo)
#     * overrides = ~/.config/ryoku/overrides/<ruta-relativa>
#                   se aplican SIEMPRE al final y jamás se borran ni actualizan
#     * semillas de máquina (monitors, gpu, keyboard, user, ...): sólo si faltan
# ============================================================================
stage_materialize() {
  local base=/usr/share/ryoku/config dest="$THOME/.config"
  local ovr="$THOME/.config/ryoku/overrides"
  log "Etapa 5/6 — materializando ~/.config para $TUSER (base: $base)"

  if [ "$FORCE_CONFIG" = 1 ]; then
    local bak="$THOME/.config.bak-$(date +%Y%m%d-%H%M%S)"
    if [ -d "$dest" ]; then
      run_as_user "cp -a '$dest' '$bak'" && log "  backup previo: $bak"
    fi
  fi

  # 1) base -> ~/.config. Preferimos el CLI upstream (respeta semillas y
  #    ficheros del usuario); si no está o falla, copia manual.
  local used_cli=0
  if [ "$FORCE_CONFIG" = 0 ] && [ -x /usr/bin/ryoku ]; then
    if run_as_user "env RYOKU_CONFIG_BASE=$base /usr/bin/ryoku materialize"; then
      used_cli=1
      log "  materialize vía ryoku CLI OK"
    else
      warn "  ryoku materialize falló; uso la copia manual del port"
    fi
  fi
  if [ "$used_cli" = 0 ]; then
    sudo -u "$TUSER" env dest="$dest" base="$base" force="$FORCE_CONFIG" bash -c '
      set -e
      mkdir -p "$dest"
      seeds="hypr/monitors.lua hypr/gpu.lua hypr/keyboard.lua hypr/user.lua
             fastfetch/config.jsonc kitty/current-theme.conf ghostty/config ghostty/ryoku-colors"
      excl=()
      for seed in $seeds; do excl+=(--exclude="./$seed"); done
      if [ "$force" = 1 ]; then
        # force: pisa la base (las semillas siguen intactas)
        ( cd "$base" && tar cf - "${excl[@]}" . ) | ( cd "$dest" && tar xf - )
      else
        # normal: sólo ficheros que AÚN no existen (nunca pisa al usuario)
        while IFS= read -r rel; do
          rel=${rel#./}
          [ -n "$rel" ] || continue
          case " $seeds " in *" $rel "*) continue ;; esac
          if [ ! -e "$dest/$rel" ]; then
            mkdir -p "$dest/$(dirname "$rel")"
            cp -a "$base/$rel" "$dest/$rel"
          fi
        done < <(cd "$base" && find . -type f)
      fi
      # semillas generadas por la máquina: sólo si ausentes
      for seed in $seeds; do
        if [ ! -e "$dest/$seed" ] && [ -e "$base/$seed" ]; then
          mkdir -p "$dest/$(dirname "$seed")"
          cp -a "$base/$seed" "$dest/$seed"
        fi
      done
      echo "   copia completada en $dest"
    '
  fi

  # 2) capa de overrides: el usuario gana SIEMPRE (y no se toca nunca).
  if [ -d "$ovr" ]; then
    local n=0 rel
    while IFS= read -r rel; do
      rel=${rel#"$ovr/"}
      [ -n "$rel" ] || continue
      mkdir -p "$dest/$(dirname "$rel")"
      cp -a "$ovr/$rel" "$dest/$rel"
      n=$((n + 1))
    done < <(find "$ovr" -type f 2>/dev/null)
    [ "$n" -gt 0 ] && log "  capa de overrides aplicada: $n fichero(s) desde $ovr"
  else
    mkdir -p "$ovr"
    run_as_user "mkdir -p '$ovr'" 2>/dev/null || true
  fi
}

# ============================================================================
# Etapa 5.5: configuración de Hyprland — Lua como modo principal (0.50+)
#   * Hyprland >= 0.50 (config Lua)  -> hyprland.lua es el modo principal;
#     el hyprland.conf del port SOLO se conserva como respaldo (--legacy-conf
#     o Hyprland < 0.50).
#   * Nunca se pisa un fichero del usuario; los ficheros "del port" se
#     identifican por su marcador y sólo esos se gestionan automáticamente.
#   * Los daemon los lanza runit (sv up) vía ryoku-session-init: ni el .conf
#     ni autostart.lua arrancan procesos directamente, así que NO hay doble
#     lanzamiento aunque ambos queden activos.
# ============================================================================
PORT_MARKER='Ryoku on Void — port'

hyprland_version() {
  Hyprland --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -n1 || echo ""
}

version_ge() { # version_ge "0.50" "0.50" -> 0 si a>=b
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

stage_hyprland_config() {
  local dest="$THOME/.config" ver lua=0
  ver="$(hyprland_version)"
  if [ -n "$ver" ] && version_ge "$ver" 0.50; then lua=1; fi
  if [ "$LEGACY_CONF" = 1 ]; then lua=0; fi

  if [ "$lua" = 1 ]; then
    log "Etapa 5.5/6 — modo LUA (Hyprland $ver >= 0.50): hyprland.lua es el principal"
    run_as_user "mkdir -p '$dest/hypr' '$dest/ryoku'"
    # asegurar hyprland.lua en ~/.config (si materialize no lo puso)
    if [ ! -f "$dest/hypr/hyprland.lua" ] && [ -f /usr/share/ryoku/config/hypr/hyprland.lua ]; then
      run_as_user "cp -a /usr/share/ryoku/config/hypr/hyprland.lua '$dest/hypr/hyprland.lua'"
      log "  hyprland.lua sembrado en ~/.config/hypr"
    fi
    # un hyprland.conf del port (con marcador) se retira a .legacy.bak para
    # que no compita con Lua; un hyprland.conf ajeno se respeta y se avisa.
    if [ -f "$dest/hypr/hyprland.conf" ]; then
      if grep -q "$PORT_MARKER" "$dest/hypr/hyprland.conf" 2>/dev/null; then
        run_as_user "mv '$dest/hypr/hyprland.conf' '$dest/hypr/hyprland.conf.legacy.bak'"
        log "  hyprland.conf del port movido a hyprland.conf.legacy.bak (modo Lua)"
      else
        warn "  $dest/hypr/hyprland.conf existe y NO es del port: lo dejo intacto."
        warn "  Si Hyprland 0.50+ lo lee junto a hyprland.lua, móvelo a mano."
      fi
    fi
    patch_autostart_lua
  else
    log "Etapa 5.5/6 — modo RESPALDO hyprland.conf (Hyprland ${ver:-desconocido} < 0.50 o --legacy-conf)"
    stage_legacy_conf
    patch_autostart_lua   # por si el usuario sube de versión: ya queda listo
  fi

  # registro del modo gestionado (lo leen heal/update para diagnosticar)
  run_as_user "mkdir -p '$dest/ryoku'"
  run_as_user "printf '{\n  \"port\": \"ryoku-void-port\",\n  \"hyprland_mode\": \"%s\",\n  \"managed_by\": \"ryoku-void-install\"\n}\n' \
    '$([ "$lua" = 1 ] && echo lua || echo legacy)' > '$dest/ryoku/void-port.json'"
}

# Parchea autostart.lua para que lance SOLO ryoku-session-init (idempotente).
# session-init publica el entorno y hace `sv up` de los servicios: los daemon
# los posee runit, así que nunca arrancan dos veces.
patch_autostart_lua() {
  local f=/usr/share/ryoku/config/hypr/modules/autostart.lua
  [ -f "$f" ] || { warn "  no existe $f (¿se instaló la config base?)"; return 0; }
  if grep -q 'ryoku-session-init' "$f" 2>/dev/null; then
    log "  autostart.lua ya lanza ryoku-session-init"
    return 0
  fi
  log "  parcheando autostart.lua -> ryoku-session-init"
  python3 - "$f" <<'PY' || warn "  no pude parchear autostart.lua (revísalo a mano)"
import re, sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
pat = re.compile(r'hl\.exec_cmd\("dbus-update-activation-environment.*?"\)', re.S)
rep = ('hl.exec_cmd("dbus-update-activation-environment --all; '
       '(setsid /usr/bin/ryoku-session-init >/dev/null 2>&1 &)")')
s2, n = pat.subn(rep, s)
if n == 0:
    # sin la línea original: inserta el arranque tras el primer módulo
    pat2 = re.compile(r'^(local hl = .*)$', re.M)
    s2, n = pat2.subn(r"\1\nhl.exec_cmd(\"(setsid /usr/bin/ryoku-session-init >/dev/null 2>&1 &)\")", s, count=1)
if n == 0:
    sys.exit('no se encontró punto de inserción en autostart.lua')
p.write_text(s2)
print(f'   autostart.lua parcheado ({n} sustitución)')
PY
}

# hyprland.conf de respaldo (Hyprland < 0.50 o --legacy-conf).
# Sólo escribe si: no existe, es del port (marcador), o --force-config (backup).
stage_legacy_conf() {
  local dest="$THOME/.config"
  run_as_user "mkdir -p '$dest/hypr' '$dest/ryoku'"
  local conf="$dest/hypr/hyprland.conf"
  local write=1
  if [ -f "$conf" ]; then
    if grep -q "$PORT_MARKER" "$conf" 2>/dev/null; then
      write=1   # es nuestro: se gestiona
    elif [ "$FORCE_CONFIG" = 1 ]; then
      run_as_user "cp -a '$conf' '$conf.bak'" && log "  backup: $conf.bak"
      write=1
    else
      write=0
      warn "  $conf existe y es del usuario: NO se pisa (usa --force-config para regenerarlo)"
    fi
  fi
  if [ "$write" = 1 ]; then
    run_as_user "cat > '$conf'" <<CONF
# $PORT_MARKER — Hyprland bootstrap (modo respaldo, sin config Lua)
# Generado por ryoku-void-install.sh. Los daemon NO se lanzan aquí: este
# fichero sólo publica la sesión; los servicios de usuario (turnstile/runit)
# arranca/levanta ryoku-session-init con \`sv up\`.
# Si tu Hyprland es >= 0.50, borra este fichero y usa ~/.config/hypr/hyprland.lua
# (o vuelve a ejecutar el instalador sin --legacy-conf).

autogenerated = 0

monitor = ,preferred,auto,1

env = XCURSOR_THEME,Bibata-Gruvbox
env = XCURSOR_SIZE,24
env = HYPRCURSOR_THEME,Bibata-Gruvbox
env = HYPRCURSOR_SIZE,24
env = QT_QPA_PLATFORM,wayland
env = QT_QPA_PLATFORMTHEME,qt6ct
env = XDG_CURRENT_DESKTOP,Hyprland

# única fuente de arranque de la sesión (idempotente)
exec-once = /usr/bin/ryoku-session-init
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

\$mod = SUPER

bind = \$mod, Return, exec, ryoku-app terminal
bind = \$mod, E, exec, ryoku-app files
bind = \$mod, B, exec, ryoku-app browser
bind = \$mod, N, exec, ryoku-app editor
bind = \$mod, L, exec, ryoku-shell lock
bind = \$mod, comma, exec, ryoku-shell hub open
bind = \$mod, W, exec, ryogami wallpaper ui
bind = \$mod SHIFT, W, exec, ryogami wallpaper random
bind = \$mod, C, killactive
bind = \$mod, M, exit
bind = \$mod, F, fullscreen
bind = \$mod, Space, togglefloating
bind = \$mod, G, togglegroup

bind = \$mod, left, movefocus, l
bind = \$mod, right, movefocus, r
bind = \$mod, up, movefocus, u
bind = \$mod, down, movefocus, d
bind = \$mod SHIFT, left, movewindow, l
bind = \$mod SHIFT, right, movewindow, r
bind = \$mod SHIFT, up, movewindow, u
bind = \$mod SHIFT, down, movewindow, d

bind = \$mod, 1, workspace, 1
bind = \$mod, 2, workspace, 2
bind = \$mod, 3, workspace, 3
bind = \$mod, 4, workspace, 4
bind = \$mod, 5, workspace, 5
bind = \$mod, 6, workspace, 6
bind = \$mod, 7, workspace, 7
bind = \$mod, 8, workspace, 8
bind = \$mod, 9, workspace, 9
bind = \$mod, 0, workspace, 10
bind = \$mod SHIFT, 1, movetoworkspacesilent, 1
bind = \$mod SHIFT, 2, movetoworkspacesilent, 2
bind = \$mod SHIFT, 3, movetoworkspacesilent, 3
bind = \$mod SHIFT, 4, movetoworkspacesilent, 4
bind = \$mod SHIFT, 5, movetoworkspacesilent, 5
bind = \$mod SHIFT, 6, movetoworkspacesilent, 6
bind = \$mod SHIFT, 7, movetoworkspacesilent, 7
bind = \$mod SHIFT, 8, movetoworkspacesilent, 8
bind = \$mod SHIFT, 9, movetoworkspacesilent, 9
bind = \$mod SHIFT, 0, movetoworkspacesilent, 10

bind = \$mod, mouse_down, workspace, e+1
bind = \$mod, mouse_up, workspace, e-1
bindm = \$mod, mouse:272, movewindow
bindm = \$mod, mouse:273, resizewindow

# SUPER+Espacio (launcher), SUPER+Tab (overview), SUPER+V (clipboard), SUPER+K
# (cheatsheet), SUPER+Escape (quicksettings)... requieren la config Lua.
CONF
    log "  hyprland.conf (respaldo) escrito en $conf"
  fi

  # hypr.json (delegación de apps): sólo si falta (o force con backup)
  local hj="$dest/ryoku/hypr.json"
  if [ ! -f "$hj" ] || { [ "$FORCE_CONFIG" = 1 ] && [ -f "$hj" ]; }; then
    [ -f "$hj" ] && [ "$FORCE_CONFIG" = 1 ] && run_as_user "cp -a '$hj' '$hj.bak'"
    run_as_user "cat > '$hj'" <<'JSON'
{
  "apps": {
    "terminal": "konsole",
    "files": "dolphin",
    "browser": "firefox",
    "editor": "konsole -e nano"
  }
}
JSON
    log "  hypr.json escrito en $hj"
  fi
}

# ============================================================================
# Etapa 6: sesión, servicios runit/turnstile, grupos y sudoers
# ============================================================================
enable_svc() { # enable_svc <nombre> — sólo si /etc/sv/<n> existe
  local s=$1
  [ -d "/etc/sv/$s" ] || { warn "  no existe /etc/sv/$s (se omite)"; return 0; }
  if [ -L "/var/service/$s" ]; then return 0; fi
  ln -s "/etc/sv/$s" "/var/service/$s" 2>/dev/null && log "  habilitado $s (runit)" \
    || warn "  no se pudo habilitar $s"
}
svc_running() { sv status "$1" 2>/dev/null | grep -q '^run:'; }

set_turnstile_rundir() { # yes|no — quién crea /run/user/<uid>
  local conf=/etc/turnstile/turnstiled.conf val=$1
  [ -f "$conf" ] || return 0
  if grep -qE "^\s*manage_rundir\s*=" "$conf"; then
    sed -i -E "s/^(\s*manage_rundir\s*=\s*).*/\1$val/" "$conf"
  else
    printf '\nmanage_rundir = %s\n' "$val" >> "$conf"
  fi
}

stage_session() {
  log "Etapa 6/6 — sesión, servicios y privilegios"

  # --- servicios de sistema: elogind Y seatd NO a la vez --------------------
  # Compiten por el seat/DRM. Regla del port:
  #   * si elogind ya está activo -> se respeta; NO se habilita seatd
  #   * si no lo está -> estándar del port: seatd + turnstile
  local elogind_on=0 seatd_on=0
  { [ -L /var/service/elogind ] && svc_running elogind; } && elogind_on=1
  { [ -L /var/service/seatd ] && svc_running seatd; } && seatd_on=1

  if [ "$elogind_on" = 1 ] && [ "$seatd_on" = 1 ]; then
    warn "  elogind y seatd están activos a la vez (compiten por el seat)."
    warn "  No toco nada: decide cuál quieres (recomendado en este port: elogind)."
  elif [ "$elogind_on" = 1 ]; then
    log "  elogind activo: respetado, NO habilito seatd"
    set_turnstile_rundir no    # elogind es dueño de /run/user
  elif [ "$seatd_on" = 1 ]; then
    log "  seatd ya activo: mantenido (estándar del port con turnstile)"
    set_turnstile_rundir yes
  else
    log "  estándar del port: seatd + turnstile"
    enable_svc seatd
    set_turnstile_rundir yes   # nadie más crea /run/user/<uid>
  fi
  enable_svc dbus
  enable_svc polkitd
  enable_svc turnstiled

  # --- grupos de hardware ---------------------------------------------------
  for g in seat video input _seatd seatd; do
    getent group "$g" >/dev/null 2>&1 && usermod -aG "$g" "$TUSER" 2>/dev/null && log "  $TUSER en grupo $g"
  done

  # --- servicios de usuario (turnstile) -------------------------------------
  if [ -x /usr/bin/ryoku-sv-provision ]; then
    run_as_user "/usr/bin/ryoku-sv-provision" || warn "  ryoku-sv-provision reportó problemas"
  else
    warn "  /usr/bin/ryoku-sv-provision ausente (¿se instaló el paquete?)"
  fi

  # --- boot-guard (opcional: sólo con raíz Btrfs + snapper) -----------------
  if [ "$(findmnt -no FSTYPE / 2>/dev/null || true)" = btrfs ] && command -v snapper >/dev/null 2>&1; then
    if [ -d /etc/sv ] && [ -d "$SRCDIR/runit/system/ryoku-boot-guard" ]; then
      mkdir -p /etc/sv/ryoku-boot-guard
      cp -a "$SRCDIR/runit/system/ryoku-boot-guard/." /etc/sv/ryoku-boot-guard/
      chmod 755 /etc/sv/ryoku-boot-guard/run /etc/sv/ryoku-boot-guard/finish
      enable_svc ryoku-boot-guard
      install -Dm644 /dev/stdin /etc/ryoku/boot-guard.conf <<EOF
# Generado por ryoku-void-install.sh — ver runit/system/ryoku-boot-guard/run
BOOT_GUARD_USER=$TUSER
BOOT_GUARD_HOME=$THOME
BOOT_GUARD_THRESHOLD=2
# Opt-in: revertir al último snapshot si la sesión gráfica falla 2 arranques.
BOOT_GUARD_AUTO_REVERT=0
EOF
      log "  ryoku-boot-guard habilitado (umbral 2, auto-revert OFF)"
    fi
  else
    log "  sin Btrfs+snapper: ryoku-boot-guard no se instala (módulo opcional)"
  fi

  # --- sudoers acotado (dinámico: usuario real, sin install/cp genéricos) ---
  local sudesterm="$SRCDIR/sudoers/ryoku-update"
  if [ -f "$sudesterm" ]; then
    sed "s/@TUSER@/$TUSER/g" "$sudesterm" > /etc/sudoers.d/zz-ryoku-update
    chmod 440 /etc/sudoers.d/zz-ryoku-update
    if command -v visudo >/dev/null 2>&1; then
      visudo -cf /etc/sudoers.d/zz-ryoku-update >/dev/null || {
        rm -f /etc/sudoers.d/zz-ryoku-update
        die "la regla sudoers generada no valida con visudo; aborto"
      }
    else
      warn "  visudo no disponible: regla instalada sin validación"
    fi
    log "  sudoers acotado instalado para $TUSER (/etc/sudoers.d/zz-ryoku-update)"
  else
    warn "  falta sudoers/ryoku-update: 'ryoku update' pedirá contraseña"
  fi

  # --- shim de systemctl: SOLO modo legado (--with-systemctl-shim) ----------
  local shim_target=/usr/local/bin/systemctl
  if [ "$WITH_SHIM" = 1 ]; then
    install -Dm755 "$SRCDIR/systemctl-shim.sh" "$shim_target"
    warn "  shim systemctl instalado en $shim_target (MODO LEGADO)"
  else
    # Limpieza del hijacking de versiones anteriores del port.
    if [ -f "$shim_target" ] && grep -q 'runit shim inteligente para Void' "$shim_target" 2>/dev/null; then
      rm -f "$shim_target"
      log "  shim systemctl antiguo retirado (ahora nativo vía patches/0001-void-runit-init.patch)"
    elif [ -e "$shim_target" ]; then
      warn "  $shim_target existe y no es nuestro: no se toca"
    fi
  fi

  log "  'ryoku' y el resto en /usr/bin (paquete ryoku-desktop)"
  log "  recuerda: cierra sesión para que apliquen grupos/servicios"
}

# ============================================================================
run() {
  snapshot_pre
  if [ "$REBUILD_BLOBS" = 1 ]; then
    stage_rebuild_blobs
    stage_package
    snapshot_post
    return 0
  fi
  stage_system
  stage_quickshell
  stage_ryoku_build
  stage_package
  stage_materialize
  stage_hyprland_config
  stage_session
  snapshot_post
}

log "═══════════════════════════════════════════════════════════════════"
log " Ryoku para Void / Neko Void — inicio (modo: $MODE)"
log "═══════════════════════════════════════════════════════════════════"
run
log "───────────────────────────────────────────────────────────────────"
log "Instalación completada."
log "  1. Cierra sesión (o reinicia) para que apliquen grupos/servicios."
log "  2. En el gestor de entrada elige la sesión 'Ryoku' (Hyprland)."
log "     Si tu DM no la muestra: loguéate en MATE y ejecuta 'ryoku-session-exec'."
log "  3. Diagnóstico: ryoku version / ryoku reload; heal: ryoku-void-heal.sh"
log "  4. Actualizar: sudo ryoku-void-update [--system] [--stack]"
log "  5. Desinstalar: sudo xbps-remove ryoku-desktop (ver README)"
log "───────────────────────────────────────────────────────────────────"
