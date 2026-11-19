# ryoku-void-port

Port de la shell **[Ryoku](https://github.com/Ryoku-dev/ryoku)** a **Void Linux**
(xbps + runit + turnstile), con **Hyprland** como compositor y a la altura
arquitectónica del port oficial de Void (que se quedó en niri porque Void trae
GCC 14 y no compila el C++23/26 de Hyprland moderno).

> **Regla de oro de este repo:** todo el trabajo ocurre dentro de este árbol.
> Los scripts están pensados para ejecutarse **después**, en una partición limpia
> de pruebas. Nada se instala en este repositorio.

---

## Arquitectura

| Nivel | Qué cambia frente al port viejo |
|---|---|
| **Hyprland 0.50+ con Clang** | `rebuild-hypr-stack.sh` compila el stack **completo** (protocols → scanner → hyprutils → graphics/lang → cursor → aquamarine → picker → hyprland → idle/lock/sunset → portales → hyprpolkitagent → quickshell `-DHYPRLAND=ON`) con `CC=clang CXX=clang++` + `lld`, porque GCC 14 no llega al C++23/26. |
| **Config Lua como modo principal** | Con Hyprland ≥ 0.50, `~/.config/hypr/hyprland.lua` es el modo principal (launcher, overview, clipboard, quicksettings nativos). `hyprland.conf` queda sólo como respaldo (`--legacy-conf` o Hyprland < 0.50), identificable por su marcador `Ryoku on Void — port`. |
| **Servicios de usuario turnstile + runit** | Se elimina el watchdog root que raspeaba `/proc/$PID/environ`. `bin/ryoku-session-init` (lanzado desde `exec-once`) publica el entorno gráfico en `$XDG_RUNTIME_DIR/ryoku-env/` (envdir) y hace `sv up` de `~/.config/service/{ryoku-shell,ryogami}`; los servicios lo consumen con `chpst -e`. Runit reinicia los daemon si crashean y los cierra al deslogin (sin huérfanos). |
| **Runit nativo en Go, sin shim global** | `patches/0001-void-runit-init.patch` añade `cli/internal/sys/runit.go` (`IsRunit`, `UserServicesDir`, `SvUser` → `sv` con `SVDIR=$XDG_RUNTIME_DIR/service`, **sin sudo**; `UnitEnabled` init-aware que jamás llama a `systemctl`) y fallbacks de energía (`loginctl` → `reboot`/`poweroff`/`zzz`) en `host/power.go` y `shell/ipc/session.go`. El shim de `/usr/local/bin/systemctl` sólo se instala con `--with-systemctl-shim` (legado, desactivado por defecto). |
| **Paquete nativo `ryoku-desktop.xbps`** | `pkg/srcpkgs/ryoku-desktop/template` empaqueta binarios Go/C, helpers, plugin QML `Ryoku/Blobs`, módulos QML (PluginKit/Ui/FrameBars), scripts, servicios de usuario, desktop entries y config base. Instalado desde repo local (`hostdir/binpkgs`), auditable y desinstalable con `xbps-remove ryoku-desktop`. Nada suelto en `/usr/local/bin`. |
| **Overrides de configuración** | `/usr/share/ryoku/config` (base del paquete) vs `~/.config` (usuario) vs `~/.config/ryoku/overrides/<ruta>` (capa final que **nunca** se pisa ni se borra). El instalador jamás sobrescribe configs existentes salvo `--force-config` (con backup `.bak`). |
| **Snapshots + Boot Guard (opcional)** | `ryoku-void-snapshot.sh` toma snapshots pre/post en raíces Btrfs+snapper; `runit/system/ryoku-boot-guard` cuenta arranques fallidos de sesión (los incrementa `ryoku-session-init` y los pone a 0 cuando `ryoku-shell ping` responde) y, con `BOOT_GUARD_AUTO_REVERT=1`, revierte al último snapshot tras 2 fallos. |
| **elogind vs seatd** | Nunca ambos a la vez: si `elogind` ya corre se respeta; si no, estándar del port = `seatd` + `turnstile` (`manage_rundir=yes`). El wrapper de sesión `ryoku-session-exec` envuelve el compositor con `dbus-run-session` **sólo** si no hay bus activo. |
| **Anti-OOM** | `XBPS_MAKEJOBS=2` automático si la RAM total es ≤ 6 GB (compilar Qt6/Hyprland con 4 GB dispara el OOM killer). |
| **Sudoers acotado** | `/etc/sudoers.d/zz-ryoku-update` (generado con `@TUSER@` dinámico y validado con `visudo -cf`) permite **sólo** `ryoku-void-update`, `xbps-install -Syu/-Su`, el reindexado del repo local y la instalación de `ryoku-desktop`. Ya no hay `NOPASSWD` para `/usr/bin/install` ni `/usr/bin/cp` (eso era raíz encubierto). |
| **Heal honesto** | `ryoku-void-heal.sh` deja de usar `ldd` sobre binarios Go (son estáticos con `CGO_ENABLED=0`: `ldd` nunca detecta nada). Ahora verifica los **dinámicos** que sí se rompen: `*.so` de `Ryoku/Blobs`, `quickshell` e `Hyprland`; recompila blobs o reconstruye el stack según el fallo. |

### Layout del repo

```
ryoku-void-port/
├── ryoku-void-install.sh        # instalador/orquestador (6 etapas)
├── ryoku-void-update.sh         # update completo (snapshots + rebuild + xbps)
├── ryoku-void-heal.sh           # autoreparación (ldd real de .so dinámicos)
├── ryoku-void-snapshot.sh       # snapshots Btrfs pre/post (opcional)
├── rebuild-hypr-stack.sh        # stack Hyprland COMPLETO con Clang (xbps-src)
├── systemctl-shim.sh            # SOLO con --with-systemctl-shim (legado)
├── void-setup.sh                # apps masivas XBPS+Flatpak (independiente)
├── bin/
│   ├── ryoku-session-init       # exec-once: publica entorno + sv up
│   ├── ryoku-sv-provision       # sync /usr/lib/ryoku/runit/user -> ~/.config/service
│   └── ryoku-session-exec       # Exec= del .desktop (dbus-run-session condicional)
├── runit/
│   ├── user/{ryoku-shell,ryogami}/{run,finish}   # servicios de usuario
│   └── ryoku-boot-guard/{run,finish}             # guardia de arranque (Btrfs)
├── sudoers/ryoku-update         # plantilla con @TUSER@ (no instalar a mano)
├── pkg/srcpkgs/ryoku-desktop/   # template xbps-src del paquete nativo
├── patches/0001-void-runit-init.patch   # parche para el monorepo (git apply --check OK)
├── refs/sys-init.go             # referencia Go del seam runit
└── README.md
```

---

## Prueba desde cero en una partición limpia de Void

### 0. Requisitos

- Void Linux x86_64 (o Neko Void) instalado, init **runit**, usuario de
  escritorio en `wheel` con sudo. RAM recomendada ≥ 8 GB (con 4 GB funcionan
  los límites anti-OOM, pero compilar Qt6 tarda).
- Este repo copiado en la partición (USB, `git clone`, o `scp`).

### 1. Preparar el sistema

```sh
sudo xbps-install -Sy git curl go cmake ninja python3 clang lld base-devel
sudo xbps-install -y turnstile elogind seatd polkitd dbus
```

### 2. Instalación completa

```sh
git clone -b refactor/turnstile-xbps https://github.com/RepX1233/ryoku-void-port.git
cd ryoku-void-port
sudo bash ryoku-void-install.sh
```

Qué hace (etapas):

1. **Sistema**: repos Hyprland (void-land → fallback Makrennel) + runtime;
   si los bins no resuelven shlibs contra tu snapshot, **Hyprland desde source
   con Clang** (`stage_hyprland_source`).
2. **quickshell** reconstruido con `-DHYPRLAND=ON` (Clang, en hold).
3. **Build de Ryoku**: `git pull` del monorepo, aplica
   `patches/0001-void-runit-init.patch`, compila `ryoku-shell`, `ryoku`,
   `ryoku-hub`, `ryogami`, `ryoku-livewall`, `ryogami-live`, helpers Go y el
   plugin QML `ryoku-blobs` (todo a `$HOME/ryoku-void-stage`, nada a mano).
4. **Paquete**: staging FHS → `./xbps-src pkg ryoku-desktop` →
   `xbps-rindex` → `xbps-install -yR` desde `hostdir/binpkgs`.
5. **Materializa** `~/.config` sin pisar nada (capa de overrides al final).
6. **Sesión**: elogind/seatd mutuamente excluyentes + turnstile + servicios
   de usuario provisionados + sudoers acotado + boot-guard si hay Btrfs.

### 3. Cerrar sesión y entrar

Cierra sesión (o reinicia) y elige la sesión **Ryoku** en el display manager.
Si tu DM no la muestra, entra en otra sesión y ejecuta `ryoku-session-exec`.

Comprobación:

```sh
ryoku version                 # binario del paquete
sv status ~/.config/service/ryoku-shell   # run: ...
ls $XDG_RUNTIME_DIR/ryoku-env             # WAYLAND_DISPLAY publicado
xbps-query -f ryoku-desktop               # todo rastreable
```

### 4. Actualizar

```sh
sudo ryoku-void-update.sh              # sólo Ryoku (rebuild + reempaquete)
sudo ryoku-void-update.sh --system     # además base Void (con snapshots)
sudo ryoku-void-update.sh --stack      # además Hyprland/quickshell con Clang
```

En Btrfs con snapper, snapshots pre/post automáticos. Sin TTY (botón del Hub)
usa la regla sudoers acotada.

### 5. Reparar

```sh
ryoku-void-heal.sh            # audita .so rotos y repara lo necesario
ryoku-void-heal.sh --force    # repara aunque no haya fallos
```

### 6. Desinstalar limpio

```sh
sudo xbps-remove -R ryoku-desktop      # todo el payload, con dependencias
sudo rm -f /etc/sudoers.d/zz-ryoku-update \
          /etc/xbps.d/ryoku-local-repo.conf \
          /etc/xbps.d/ryoku-hyprland-repo.conf
sudo rm -rf /var/service/ryoku-boot-guard /etc/sv/ryoku-boot-guard
# limpieza de usuario (opcional):
rm -rf ~/.config/service/{ryoku-shell,ryogami} \
       ~/.config/ryoku/overrides ~/.local/state/ryoku/boot-guard
# El monorepo, el pool de xbps-src y los stacks instalados (Hyprland,
# quickshell) NO son de ryoku-desktop: bórralos a mano si quieres:
sudo xbps-remove -R hyprland quickshell && rm -rf ~/ryoku ~/ryoku-void-build
```

Quitar el shim legado si lo instalaste: `sudo rm /usr/local/bin/systemctl`.

---

## Verificación estática de este repo

```sh
for f in *.sh bin/* runit/*/*/run runit/*/*/finish; do bash -n "$f"; done
shellcheck -S warning *.sh bin/* runit/*/*/run runit/*/*/finish   # si está instalado
git apply --check patches/0001-void-runit-init.patch              # en el monorepo
```

## Estados que requieren validación manual en la partición de pruebas

1. **Compilación del stack Hyprland con Clang** en una Void real (tiempos,
   shlibs contra tu snapshot; `stage_hyprland_source` es el fallback largo).
2. **`hyprland.lua` ≥ 0.50**: el modo Lua depende de que Hyprland compila
   moderno; el respaldo `hyprland.conf` debe probarse por separado.
3. **Turnstile + servicios de usuario**: que `ryoku-session-init` en
   `exec-once` publique el entorno y que `sv restart ryoku-shell` recupere
   un crash de daemon durante la sesión.
4. **Paquete `.xbps`**: `./xbps-src pkg ryoku-desktop` en el árbol real y la
   instalación/actualización/desinstalación sin residuos
   (`xbps-query -f` antes/después).
5. **Sudoers**: `visudo -cf` pasa en la máquina y el botón Update del Hub
   funciona sin contraseña.
6. **Boot Guard** (sólo Btrfs+snapper): dos arranques fallidos seguidos
   producen alerta y, con `BOOT_GUARD_AUTO_REVERT=1`, rollback.
7. **Energía**: `loginctl` con elogind y `reboot`/`poweroff`/`zzz` sin él.
