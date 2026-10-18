# Ryoku en Void / Neko Void — port de la shell

Instalador adaptado (`ryoku-void-install.sh`) que pone la **shell de Ryoku**
(bar, pill, launcher, frame, hub de ajustes, wallpapers con matugen) encima de
una instalación **Void Linux** (o su derivado Neko Void, xbps + runit).

Ryoku oficialmente solo instala sobre Arch/CachyOS (o el port comunitario a
NixOS). Esto **no es un port oficial**: es una adaptación que compila los
componentes desde el monorepo y sustituye las partes que dependen de Arch.

## Qué instala

| Componente | Origen |
|---|---|
| Hyprland + hypridle/lock/sunset, protocolos | repo binario comunitario `void-land/hyprland-void-packages` |
| Quickshell con soporte Hyprland | reconstruido desde `void-packages` con `-DHYPRLAND=ON` (xbps-src) |
| matugen, pipewire, portal, grim/slurp/cliphist, runtime | repos oficiales de Void |
| `ryoku-shell`, `ryoku-hub`, `ryogami`, `ryoku` (CLI) | compilados del monorepo con Go (vendor incluido) |
| `ryoku-blobs`, `Ryoku.Ui`, `Ryoku.FrameBars`, `Ryoku.PluginKit` | CMake + QML, instalados en `/usr/lib/qt6/qml` |
| Config base → `~/.config` | `ryoku materialize` (o copia manual equivalente) |
| Autostart sin systemd | parche en `hypr/modules/autostart.lua` (arranca la shell con `setsid ... &`) |
| Sesión "Ryoku" | `/usr/share/wayland-sessions/ryoku.desktop` |

## Uso

En la máquina Void (a esta instalación de prueba — dual boot), como root:

```sh
sudo bash ryoku-void-install.sh
```

- `--user=pepe` → otro usuario objetivo (por defecto `$SUDO_USER`).
- `--update` → `git pull` + recompila + re-materializa (actualización manual).
- `--skip-quickshell` → si ya tienes un quickshell con Hyprland, evita el build
  pesado (queda en `hold` con revisión `_2`).

### Tiempos

- `binary-bootstrap` (una vez): descarga la base del chroot, ~minutos.
- **Compilar quickshell con `HYPRLAND=ON`: 10–30 min** (Qt6/C++), es el paso lento.
- Compilar los binarios Go: 1–3 min.

## Lo que NO funciona aquí (límites del port)

- **Actualizaciones**: no hay repo firmado `[ryoku]`. Actualizar = `--update`
  (git pull + rebuild). `ryoku update/rollback/snapshots` no sirven en Void.
- **Units de systemd**: sin `ryoku-boot-guard`, los servicios del escritorio los
  lanza Hyprland en el autostart (parche incluido). `ryoku doctor` parcial.
- **Snapshots** (snapper), **gpk**, **greeter SDDM de weston**, **theme de
  browser** por defecto y **plugins de Hyprland** (sensibles a versión).
- **Iconos**: la barra usa *Material Symbols Rounded*; el script lo descarga a
  `~/.local/share/fonts`. Sin él los iconos se ven como ligaduras de texto.
- `ryoku CLI` necesita `pacman` para `update`; `materialize`, `reload`, `version`
  sí funcionan.

## Solución de problemas

- **`xbps-install -S` pide la huella del repo Hyprland** → acepta con `Y` (es el
  repo binario comunitario `void-land`).
- **binary-bootstrap falla por user namespaces** → compílalo a mano:
  ```sh
  cd ~/ryoku-void-build/void-packages
  sudo ./xbps-src binary-bootstrap      # o habilita user namespaces
  ./xbps-src pkg quickshell
  sudo xbps-install -R hostdir/binpkgs quickshell
  ```
- **`Quickshell.Hyprland` no se encuentra** al arrancar → el quickshell instalado
  no tiene soporte Hyprland; reinstala el portado (`--skip-quickshell` NO), o
  verifica: `xbps-query -p pkgver quickshell` debe ser `..._2` y estar en hold.
- **El DM no muestra la sesión "Ryoku"** → algunos gestores (LightDM GTK, MDM) no
  leen `/usr/share/wayland-sessions`. Alternativa: inicia sesión en MATE y en
  una terminal ejecuta `Hyprland` (con `setsid` si quieres despegarla del TTY).
- **Escritorio negro sin barra** → mira `~/.local/state/ryoku/` / `ps aux |
  grep ryoku-shell`. Si `ryoku-shell` no corre, reinicia la sesión; el autostart
  parcheado lo levanta con el compositor.
- **Log de instalación**: el propio script imprime el avance; guarda la salida
  con `sudo bash ryoku-void-install.sh 2>&1 | tee /tmp/ryoku-void-install.log`.

## Estructura

```
/tu-home/
├── ryoku/                       # checkout del monorepo (main)
└── ryoku-void-build/            # pool xbps-src (void-packages + hostdir/binpkgs)
└── ryoku-void-stage/            # binarios compilados (antes de instalarlos)
/usr/share/ryoku/config          # base que materializa en ~/.config
/usr/lib/qt6/qml/Ryoku/         # Blobs, Ui, FrameBars, PluginKit
```

## Nota legal

Ryoku es GPL-3.0 (monorepo en github.com/ryoku-dev/ryoku). Este port no está
afiliado a Ryoku; es una adaptación de terceros para cubrir Void/Neko Void.