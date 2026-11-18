#!/usr/bin/env bash
# =============================================================================
# rebuild-hypr-stack.sh — Reconstruye el stack Hyprland COMPLETO con CLANG
# sobre el árbol void-packages local.
#
# Por qué Clang: Void trae GCC 14 y las versiones recientes de Hyprland
# (0.50+, config Lua) usan C++23/26 que GCC 14 no se traga; el port oficial
# de Void renunció a Hyprland por esto. Compilando con clang + lld el stack
# completo se obtiene Hyprland moderno en Void sin esperar a GCC 15.
#
# Árbol:   ~/ryoku-void-build/void-packages  (masterdir-x86_64, layout directo)
# Repo:    hostdir/binpkgs indexado con xbps-rindex; declarado en
#          /etc/xbps.d/ryoku-hyprland-repo.conf
#
# Subcomandos (idempotentes, en este orden):
#   build     ./xbps-src pkg de la lista BUILD_PKGS (con Clang inyectado en
#             cada template) + poda de .xbps obsoletos
#   repo      xbps-rindex -a + conf del repo local
#   unhold    quita los holds del stack (para poder reinstalar)
#   install   xbps-install -Sy de los paquetes actualizados
#   cleanup   elimina el symlink /usr/lib/libdisplay-info.so.2 y revierte el
#             parche manual de shlib-provides en pkgdb-*.plist
#   verify    comprobaciones de compilación, pkgdb, shlibs y symlink
#   all       build -> repo -> unhold -> install -> cleanup -> verify
#
# Uso:  ./rebuild-hypr-stack.sh [build|repo|unhold|install|cleanup|verify|all]
# Env:  XBPS_MAKEJOBS  (si no está: 2 si la RAM total <= 6 GB, si no el
#                       defecto de xbps-src; evita OOM al compilar Qt6/Hyprland
#                       en máquinas con 4 GB)
#       USE_CLANG=0    (vuelve al toolchain por defecto; no recomendado)
#
# NOTAS DE SEGURIDAD:
#  - xbps-src NUNCA se ejecuta como root (esto lo valida).
#  - Las operaciones con sudo piden contraseña de forma interactiva.
#  - cleanup exige que NINGÚN paquete instalado siga requiriendo
#    libdisplay-info.so.2 antes de tocar nada (es decir, tras instalar el
#    aquamarine reconstruido). Si no, aborta.
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

# ----------------------------------------------------------------- variables
TREE="$HOME/ryoku-void-build/void-packages"
BINPKGS="$TREE/hostdir/binpkgs"
REPO_CONF="/etc/xbps.d/ryoku-hyprland-repo.conf"
REPO_LINE="repository=$BINPKGS"
COMPAT_SYMLINK="/usr/lib/libdisplay-info.so.2"

# Orden de dependencias (respeta el grafo de build del stack):
#   protocols -> scanner -> hyprutils -> graphics/lang -> cursor ->
#   aquamarine -> picker -> hyprland -> idle/lock/sunset -> portales -> quickshell
BUILD_PKGS=(
  hyprland-protocols
  hyprwayland-scanner
  hyprutils
  hyprgraphics
  hyprlang
  hyprcursor
  aquamarine
  hyprpicker
  hyprland
  hypridle
  hyprlock
  hyprsunset
  xdg-desktop-portal-hyprland
  hyprpolkitagent
  quickshell
)
# Paquetes a instalar tras unhold (idénticos a los reconstruidos).
INSTALL_PKGS=("${BUILD_PKGS[@]}")
# Holds a retirar (pkgname sin versión). Coincide con lo que fija
# ryoku-void-install.sh para que main no reemplace el stack local.
HOLD_PKGS=(
  hyprland hyprland-protocols hyprwayland-scanner hyprutils hyprgraphics
  hyprlang hyprcursor aquamarine hyprpicker hypridle hyprlock hyprsunset
  xdg-desktop-portal-hyprland hyprpolkitagent quickshell libdisplay-info
)

# ---------------------------------------------------------------- toolchain
# Clang por defecto (GCC 14 de Void no compila el C++23/26 de Hyprland
# moderno). USE_CLANG=0 lo desactiva para experimentar.
USE_CLANG=${USE_CLANG:-1}

detect_toolchain() {
  if [ "$USE_CLANG" != 1 ]; then
    warn "USE_CLANG=0: se compilará con el toolchain por defecto de Void (GCC)"
    CC_LANG=${CC:-cc} CXX_LANG=${CXX:-c++}
    return 0
  fi
  command -v clang >/dev/null 2>&1 || die \
    "falta 'clang' (instálalo: sudo xbps-install -y clang lld)"
  command -v clang++ >/dev/null 2>&1 || die "falta 'clang++'"
  CC_LANG=clang CXX_LANG=clang++
  if command -v ld.lld >/dev/null 2>&1; then
    LDFLAGS_LANG="${LDFLAGS:-} -fuse-ld=lld"
  else
    LDFLAGS_LANG="${LDFLAGS:-}"
    warn "sin lld: se enlaza con el linker por defecto"
  fi
  info "toolchain: $CC_LANG / $CXX_LANG (${LDFLAGS_LANG:-sin LDFLAGS extra})"
}

# Límite de memoria para las compilaciones: con <= 6 GB de RAM se fuerza
# XBPS_MAKEJOBS=2 para no morir por OOM al compilar Qt6/Hyprland.
detect_makejobs() {
  if [ -n "${XBPS_MAKEJOBS:-}" ]; then
    info "XBPS_MAKEJOBS=$XBPS_MAKEJOBS (definido por el entorno)"
    return 0
  fi
  local mem_kb
  mem_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
  if [ "$mem_kb" -gt 0 ] && [ "$mem_kb" -le 6291456 ]; then
    export XBPS_MAKEJOBS=2
    info "RAM ${mem_kb} kB <= 6 GB -> XBPS_MAKEJOBS=2 (anti-OOM)"
  else
    info "RAM ${mem_kb} kB > 6 GB -> XBPS_MAKEJOBS por defecto de xbps-src"
  fi
}

# Inyecta el toolchain en un template de xbps-src (idempotente). xbps-src
# hace source del template también en la fase de build, así que un
# `export CC=...` a nivel de template llega a make/cmake.
clangize_template() {
  local tpl=$1
  [ -f "$tpl" ] || return 0
  [ "$USE_CLANG" = 1 ] || return 0
  grep -q 'RYOKU_VOID_CLANG' "$tpl" && return 0
  sed -i "1i # RYOKU_VOID_CLANG (inyectado por rebuild-hypr-stack.sh)\nexport CC=${CC_LANG}\nexport CXX=${CXX_LANG}\nexport LDFLAGS=\"\${LDFLAGS:-} ${LDFLAGS_LANG}\"" "$tpl"
  # export CC=clang no basta: xbps-src sólo instala en el masterdir (chroot de
  # build) lo que el template declara en hostmakedepends. gcc viene en
  # base-chroot, pero clang/lld NO, así que hay que declararlos; de lo contrario
  # la fase de build falla con "clang: not found".
  local dep
  for dep in clang lld; do
    if grep -E '^hostmakedepends\+?=' "$tpl" | grep -qw "$dep"; then
      continue   # ya declarado por el template upstream
    fi
    printf '# RYOKU_VOID_CLANG: toolchain dentro del chroot de xbps-src\nhostmakedepends+="%s"\n' " $dep" >>"$tpl"
  done
  info "clang+lld y toolchain inyectados en $(basename "$(dirname "$tpl")")"
}

# Fuerza -DHYPRLAND=ON en el template de quickshell (idempotente): sin esto
# quickshell no sirve a la shell en Hyprland.
qs_hyprland_flag() {
  local tpl="$TREE/srcpkgs/quickshell/template"
  [ -f "$tpl" ] || return 0
  grep -q -- '-DHYPRLAND=ON' "$tpl" && return 0
  sed -i 's/-DCPPTRACE_SIGNAL_SAFE_UNWIND=0/-DCPPTRACE_SIGNAL_SAFE_UNWIND=0 -DHYPRLAND=ON/' "$tpl" \
    || die "no pude inyectar -DHYPRLAND=ON en quickshell/template"
  info "-DHYPRLAND=ON inyectado en quickshell"
}

# ---------------------------------------------------------------- utilidades
C_RST=$'\033[0m'; C_B=$'\033[1m'; C_G=$'\033[32m'; C_Y=$'\033[33m'
C_R=$'\033[31m'; C_C=$'\033[36m'

step()  { printf '\n%s==>%s %s%s%s\n' "$C_C" "$C_RST" "$C_B" "$*" "$C_RST"; }
info()  { printf '    %s\n' "$*"; }
ok()    { printf '    %s[OK]%s %s\n' "$C_G" "$C_RST" "$*"; }
warn()  { printf '    %s[AVISO]%s %s\n' "$C_Y" "$C_RST" "$*"; }
die()   { printf '\n%s[ERROR]%s %s\n' "$C_R" "$C_RST" "$*" >&2; exit 1; }

on_err() {
  printf '\n%s[FALLO]%s error en la línea %s (comando: %s)\n' \
    "$C_R" "$C_RST" "${BASH_LINENO[0]:-?}" "${BASH_COMMAND:-?}" >&2
}
trap on_err ERR

need_user() {
  [[ $EUID -ne 0 ]] || die "Ejecuta este script como usuario normal, no como root (xbps-src lo exige)."
}

run_root() { sudo -v && sudo "$@"; }

check_tree() {
  [[ -d $TREE ]] || die "No existe el árbol de build: $TREE"
  [[ -x $TREE/xbps-src ]] || die "$TREE/xbps-src no es ejecutable."
  [[ -d $TREE/masterdir-x86_64 ]] || die \
    "No hay masterdir en $TREE/masterdir-x86_64. Ejecuta primero: cd $TREE && ./xbps-src binary-bootstrap"
  [[ -d $BINPKGS ]] || die "No existe $BINPKGS"
}

# --------------------------------------------------------------- build
do_build() {
  step "VERIFICACIÓN DE FUENTES (void-packages)"
  check_tree
  info "Árbol:  $TREE"
  info "Commit: $(git -C "$TREE" rev-parse --short HEAD 2>/dev/null || echo 'n/d')"
  local dirty
  dirty=$(git -C "$TREE" status --porcelain 2>/dev/null | wc -l)
  info "Plantillas locales sin commitear/modificadas: $dirty (esperado: templates hypr* locales)"
  for pkg in "${BUILD_PKGS[@]}"; do
    if [[ ! -f $TREE/srcpkgs/$pkg/template ]]; then
      # Plantillas que el port copia desde Makrennel/hyprland-void en la
      # Etapa 1b de ryoku-void-install.sh (hyprgraphics, hyprpicker...).
      warn "Falta srcpkgs/$pkg/template (¿copiaste el overlay de Makrennel? Ejecuta la Etapa 1b de ryoku-void-install.sh)"
    fi
  done
  ok "Fuentes verificadas; masterdir presente."

  step "COMPILACIÓN CON xbps-src (orden de dependencias, Clang)"
  detect_toolchain
  detect_makejobs
  info "Paquetes: ${BUILD_PKGS[*]}"
  cd "$TREE"
  local pkg
  for pkg in "${BUILD_PKGS[@]}"; do
    step "xbps-src pkg $pkg"
    clangize_template "$TREE/srcpkgs/$pkg/template"
    [ "$pkg" = quickshell ] && qs_hyprland_flag
    ./xbps-src pkg "$pkg"
    ok "$pkg compilado."
  done

  step "PODA DE .XBPS OBSOLETOS EN hostdir/binpkgs"
  # Por cada pkg de BUILD_PKGS conservar solo la versión más alta
  # (patrón ${pkg}-[0-9]* evita tocar subpaquetes como hyprland-devel).
  for pkg in "${BUILD_PKGS[@]}"; do
    local files newest f
    mapfile -t files < <(find "$BINPKGS" -maxdepth 1 -name "${pkg}-[0-9]*.xbps" | sort -V)
    ((${#files[@]})) || continue
    newest="${files[-1]}"
    for f in "${files[@]}"; do
      if [[ $f != "$newest" ]]; then
        info "eliminando obsoleto: $(basename "$f")"
        rm -f -- "$f"
      fi
    done
  done
  # Higiene: el libdisplay-info 0.2.0 del repo local es un artefacto viejo;
  # el 0.3.0_1 vive en el repo oficial.
  find "$BINPKGS" -maxdepth 1 -name 'libdisplay-info*-0.2*.xbps' -print -delete
  ok "binpkgs depurado."
}

# ----------------------------------------------------------------- repo
do_repo() {
  step "REGENERAR ÍNDICE DEL REPOSITORIO LOCAL"
  check_tree
  local n
  n=$(find "$BINPKGS" -maxdepth 1 -name '*.xbps' | wc -l)
  info "Paquetes binarios en $BINPKGS: $n"
  ((n)) || die "No hay .xbps que indexar; ejecuta primero el subcomando 'build'."
  cd "$TREE"
  xbps-rindex -a "$BINPKGS"/*.xbps
  [[ -f $BINPKGS/x86_64-repodata ]] || die "No se generó x86_64-repodata."
  ok "Índice x86_64-repodata regenerado."

  step "DECLARAR REPO LOCAL EN $REPO_CONF"
  if [[ -f $REPO_CONF ]] && [[ $(<"$REPO_CONF") == "$REPO_LINE" ]]; then
    ok "El conf ya está correcto: $REPO_LINE"
  else
    info "Instalando/actualizando $REPO_CONF (se pide contraseña sudo)"
    printf '%s\n' "$REPO_LINE" | run_root tee "$REPO_CONF" >/dev/null
    ok "Repo local declarado."
  fi
  info "Contenido actual: $(cat "$REPO_CONF")"
}

# ---------------------------------------------------------------- unhold
do_unhold() {
  step "RETIRAR HOLDS DE XBPS"
  local held before
  before=$(xbps-query -H 2>/dev/null || true)
  info "Holds actuales:"
  printf '%s\n' "$before" | sed 's/^/        /'
  run_root xbps-pkgdb --unhold "${HOLD_PKGS[@]}"
  held=$(xbps-query -H 2>/dev/null || true)
  local p
  for p in "${HOLD_PKGS[@]}"; do
    if printf '%s\n' "$held" | grep -q "^$p-"; then
      die "El hold de $p sigue activo."
    fi
  done
  ok "Holds retirados: ${HOLD_PKGS[*]}"
}

# --------------------------------------------------------------- install
do_install() {
  step "INSTALAR PAQUETES ACTUALIZADOS (xbps-install -Sy)"
  info "Plan de transacción (dry-run):"
  sudo -n true 2>/dev/null || info "(se pedirá la contraseña sudo)"
  xbps-install -Syn "${INSTALL_PKGS[@]}" 2>&1 | sed 's/^/        /' || true
  step "Confirmando la instalación"
  run_root xbps-install -Sy "${INSTALL_PKGS[@]}"
  ok "Paquetes instalados: ${INSTALL_PKGS[*]}"
  warn "La sesión Hyprland activa sigue usando los .so viejos en memoria;"
  info "reinicia la sesión (o el equipo) para que cargue el aquamarine nuevo."
}

# --------------------------------------------------------------- cleanup
do_cleanup() {
  step "CLEANUP: SYMLINK COMPAT + PARCHE MANUAL DE PKGDB"

  # Localizar el pkgdb real (cambia de número de versión con actualizaciones).
  local pkgdb
  pkgdb=$(ls /var/db/xbps/pkgdb-*.plist 2>/dev/null | head -n1) || true
  [[ -n ${pkgdb:-} && -f $pkgdb ]] || die "No se encontró /var/db/xbps/pkgdb-*.plist"

  # ---- PRECONDICIÓN: ningún paquete instalado debe requerir todavía .so.2.
  info "Comprobando que nada requiera libdisplay-info.so.2 en $pkgdb ..."
  local offenders
  offenders=$(python3 - "$pkgdb" <<'PYEOF'
import plistlib, sys
with open(sys.argv[1], 'rb') as fh:
    db = plistlib.load(fh)
bad = []
for name, ent in db.items():
    if isinstance(ent, dict) and 'libdisplay-info.so.2' in (ent.get('shlib-requires') or []):
        bad.append(f"{name} ({ent.get('pkgver', '?')})")
print('\n'.join(bad))
PYEOF
)
  if [[ -n $offenders ]]; then
    die "Aún requieren libdisplay-info.so.2:
$offenders
Reconstruye e instala esos paquetes antes del cleanup (subcomando 'all' completo)."
  fi
  ok "Ningún paquete requiere libdisplay-info.so.2."

  # ---- 1) Revertir el parche manual de shlib-provides en el pkgdb.
  step "Revirtiendo parche manual en $pkgdb (backup previo)"
  run_root cp -a "$pkgdb" "${pkgdb}.bak-$(date +%Y%m%d-%H%M%S)"
  run_root python3 - "$pkgdb" <<'PYEOF'
import os, plistlib, sys
path = sys.argv[1]
with open(path, 'rb') as fh:
    db = plistlib.load(fh)
ent = db.get('libdisplay-info')
provides = (ent or {}).get('shlib-provides') or []
if 'libdisplay-info.so.2' in provides:
    ent['shlib-provides'] = [s for s in provides if s != 'libdisplay-info.so.2']
    tmp = path + '.tmp'
    with open(tmp, 'wb') as fh:
        plistlib.dump(db, fh)
    os.replace(tmp, path)
    print('PARCHÉ REVERTIDO: libdisplay-info.so.2 eliminado de shlib-provides.')
else:
    print('pkgdb ya limpio: libdisplay-info.so.2 no está en shlib-provides.')
PYEOF
  ok "pkgdb restaurado."

  # ---- 2) Eliminar el symlink de compatibilidad (solo si ES symlink).
  step "Eliminando symlink de compatibilidad $COMPAT_SYMLINK"
  if [[ -L $COMPAT_SYMLINK ]]; then
    local target
    target=$(readlink "$COMPAT_SYMLINK")
    case $target in
      *libdisplay-info*)
        run_root rm -f -- "$COMPAT_SYMLINK"
        ok "Symlink eliminado (apuntaba a: $target)."
        ;;
      *)
        die "$COMPAT_SYMLINK es un symlink pero apunta a '$target' (inesperado); no se toca."
        ;;
    esac
  elif [[ -e $COMPAT_SYMLINK ]]; then
    die "$COMPAT_SYMLINK existe y NO es un symlink (¿archivo regular?); no se toca automáticamente."
  else
    ok "El symlink ya no existe."
  fi

  # ---- 3) Validar la integridad de la base de paquetes.
  step "Validando integridad (xbps-pkgdb --check)"
  run_root xbps-pkgdb --check
  ok "pkgdb íntegro."
}

# --------------------------------------------------------------- verify
do_verify() {
  step "VERIFICACIÓN FINAL"
  local fail=0 pkg

  info "--- 1) .xbps más recientes en el repo local ---"
  for pkg in "${BUILD_PKGS[@]}"; do
    local newest
    newest=$(find "$BINPKGS" -maxdepth 1 -name "${pkg}-[0-9]*.xbps" | sort -V | tail -n1 || true)
    if [[ -n $newest ]]; then
      info "$pkg -> $(basename "$newest")"
    else
      warn "$pkg: sin .xbps en el repo local"; fail=1
    fi
  done

  info "--- 2) shlib-requires del aquamarine del repo local (debe decir .so.3) ---"
  local repo_req
  repo_req=$(xbps-query --repository="$BINPKGS" -p shlib-requires aquamarine 2>/dev/null || true)
  printf '%s\n' "$repo_req" | tr ' ' '\n' | grep -F 'libdisplay-info' | sed 's/^/        /' || true
  if printf '%s\n' "$repo_req" | grep -qF 'libdisplay-info.so.3'; then
    ok "aquamarine (repo local) enlaza contra .so.3"
  else
    warn "aquamarine (repo local) NO enlaza contra .so.3"; fail=1
  fi

  info "--- 3) shlib-requires de aquamarine INSTALADO ---"
  local inst_req
  inst_req=$(xbps-query -p shlib-requires aquamarine 2>/dev/null || true)
  printf '%s\n' "$inst_req" | tr ' ' '\n' | grep -F 'libdisplay-info' | sed 's/^/        /' || true
  if printf '%s\n' "$inst_req" | grep -qF 'libdisplay-info.so.3'; then
    ok "aquamarine instalado enlaza contra .so.3"
  else
    warn "aquamarine instalado NO enlaza contra .so.3 (¿falta 'install'?)"; fail=1
  fi

  info "--- 4) symlink de compatibilidad ---"
  if [[ -e $COMPAT_SYMLINK || -L $COMPAT_SYMLINK ]]; then
    warn "$COMPAT_SYMLINK aún existe"; fail=1
  else
    ok "$COMPAT_SYMLINK ausente (correcto)"
  fi

  info "--- 5) shlib-provides del pkgdb (no debe contener .so.2) ---"
  local pkgdb
  pkgdb=$(ls /var/db/xbps/pkgdb-*.plist 2>/dev/null | head -n1 || true)
  if [[ -n ${pkgdb:-} ]] && grep -q 'libdisplay-info.so.2' "$pkgdb" 2>/dev/null; then
    # Puede quedar como shlib-requires residual: revisar solo shlib-provides.
    local prov
    prov=$(python3 - "$pkgdb" <<'PYEOF'
import plistlib, sys
with open(sys.argv[1], 'rb') as fh:
    db = plistlib.load(fh)
print(' '.join((db.get('libdisplay-info') or {}).get('shlib-provides') or []))
PYEOF
)
    if printf '%s\n' "$prov" | grep -qF 'libdisplay-info.so.2'; then
      warn "pkgdb: libdisplay-info aún declara .so.2 en shlib-provides ($prov)"; fail=1
    else
      ok "pkgdb: shlib-provides limpio ($prov)"
    fi
  else
    ok "pkgdb sin rastro de libdisplay-info.so.2"
  fi

  info "--- 6) holds ---"
  local h hold_re
  h=$(xbps-query -H 2>/dev/null || true)
  hold_re=$(printf '%s\n' "${HOLD_PKGS[@]}" | paste -sd'|' -)
  if printf '%s\n' "$h" | grep -qE "^(${hold_re})-"; then
    warn "Quedan holds del stack: $(printf '%s\n' "$h" | grep -E "^(${hold_re})-" | tr '\n' ' ')"; fail=1
  else
    ok "Sin holds en el stack hyprland"
  fi

  info "--- 7) integridad del pkgdb ---"
  if run_root xbps-pkgdb --check; then
    ok "xbps-pkgdb --check sin errores"
  else
    warn "xbps-pkgdb --check reportó problemas"; fail=1
  fi

  echo
  if ((fail)); then
    printf '%s[VERIFY]%s hay comprobaciones pendientes (revisa arriba).\n' "$C_Y" "$C_RST"
    return 1
  fi
  printf '%s[VERIFY]%s todo en verde. Recuerda reiniciar la sesión Hyprland.\n' "$C_G" "$C_RST"
}

# ----------------------------------------------------------------- main
do_all() {
  do_build
  do_repo
  do_unhold
  do_install
  do_cleanup
  do_verify
}

main() {
  need_user
  local cmd="${1:-all}"
  case $cmd in
    build)   do_build ;;
    repo)    do_repo ;;
    unhold)  do_unhold ;;
    install) do_install ;;
    cleanup) do_cleanup ;;
    verify)  do_verify ;;
    all)     do_all ;;
    -h|--help|help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "Subcomando desconocido: $cmd (usa: build|repo|unhold|install|cleanup|verify|all)" ;;
  esac
}

main "$@"
