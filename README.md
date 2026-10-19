# Ryoku Shell — Port para Void Linux / Neko Void

Adaptación comunitaria del entorno gráfico **Ryoku** (Hyprland + Quickshell + Daemons en Go + Matugen) optimizada para sistemas **Void Linux** basados en **runit** y **xbps**.

---

## 🚀 ¿Qué es Ryoku?

Ryoku es un entorno de escritorio moderno, altamente personalizable y fluido construido sobre **Hyprland** (Wayland) y **Quickshell** (QML/Qt6), diseñado originalmente para Arch Linux. Este port adapta todo el ecosistema para funcionar de manera nativa en Void Linux sin dependencias de `systemd`.

---

## 🛠️ Componentes del Port

| Componente | Origen / Adaptación |
|---|---|
| **Compositor (Hyprland)** | Paquetes de Void Linux (`hyprland-void-packages` / `xbps-src`) |
| **Quickshell** | Reconstruido con soporte `-DHYPRLAND=ON` (`xbps-src`, fijado en hold) |
| **Daemons y CLI** | `ryoku-shell`, `ryoku-hub`, `ryogami`, y `ryoku` (CLI) compilados en Go |
| **Gestión de Servicios** | **Shim inteligente de systemctl** que traduce llamadas a `runit` y `setsid` |

---

## 📦 Guía de Instalación Paso a Paso

### 1. Clonar el repositorio
```sh
git clone https://github.com/RepX1233/ryoku-void-port.git
cd ryoku-void-port
```

### 2. Base del Sistema (`void-setup.sh`)
Habilita repositorios `nonfree` y `multilib`, e instala la suite recomendada:
```sh
sudo ./void-setup.sh
```

### 3. Instalación de la Shell (`ryoku-void-install.sh`)
Compila binarios, Quickshell y materializa configuraciones:
```sh
sudo bash ryoku-void-install.sh
```

### 4. Instalación del Shim de Compatibilidad (CRÍTICO)
Para que los controles de red, audio y servicios del Hub funcionen sin `systemd`:
```sh
sudo ln -sf $(pwd)/systemctl-shim.sh /usr/local/bin/systemctl
```

---

## 🛡️ Inmunidad ante Actualizaciones y Portabilidad

Uno de los retos de usar Ryoku en Void es que las actualizaciones de `xbps` pueden romper las librerías dinámicas (`.so`). Para solucionar esto, el port incluye herramientas de salud:

### Script de Autoreparación (`ryoku-void-heal.sh`)
Si tras un `xbps-install -Syu` la shell no inicia o notas errores, ejecuta este script. Detectará automáticamente qué binario tiene librerías rotas y lo recompilará al instante:
```sh
./ryoku-void-heal.sh
```
*   Usa `./ryoku-void-heal.sh --force` para forzar una recompilación limpia en cualquier momento.

### Portabilidad Multidispositivo
Este port utiliza auto-detección de GPU y monitores:
1.  **GPU:** No se declaran dispositivos fijos; se apoya en `ryoku-gpu-detect` para cargar los drivers correctos (AMD/Intel/Nvidia) al vuelo.
2.  **Pantallas:** Configuración dinámica `preferred,auto` para adaptarse a cualquier resolución (portátiles o monitores externos) sin romper el layout de Hyprland.

---

## 🎨 Wallpapers y Personalización

*   **Ryogami:** Daemon integrado que genera paletas dinámicas vía `matugen`.
*   **Selector Visual:** Usa `ryogami wallpaper ui` para cambiar el fondo.
*   **Temas (Rices):** Soporte total para perfiles como *Aperture*, *Evangelion* o *Lumen* desde la tienda de Ryoku.

---

## ⚙️ Mantenimiento Técnico

*   **Diagnóstico:** `ryoku doctor`
*   **Recargar Shell:** `ryoku reload`
*   **Sincronizar Stack:** `./rebuild-hypr-stack.sh all` (si hay cambios mayores en Hyprland).

---

## 📄 Licencia
Distribuido bajo **GPL-3.0**, siguiendo la licencia del monorepo oficial de Ryoku.

## 🛡️ Mejoras de Producción (Runit + Elogind)
Este port ahora cuenta con:
- **Daemon Inmortal:** `ryoku-shell` es supervisado por `runit` mediante un watchdog que cada 5 s hace `ryoku-shell ping`; si el daemon no responde, lo relanza **recuperando el env de la sesión Wayland viva** (toma `WAYLAND_DISPLAY` y `HYPRLAND_INSTANCE_SIGNATURE` de un cliente vivo de la sesión, con fallback a `/run/user/1000/hypr/` y al socket `wayland-*`). Evita así los típicos fallos `Failed to create wl_display`. Instálalo con:
  ```sh
  sudo mkdir -p /etc/sv/ryoku-shell
  sudo cp runit/ryoku-shell/run /etc/sv/ryoku-shell/run
  sudo chmod +x /etc/sv/ryoku-shell/run
  sudo ln -sf /etc/sv/ryoku-shell /var/service/
  ```
- **Shim `systemctl` inteligente** (`systemctl-shim.sh` → `/usr/local/bin/systemctl`): traduce a runit —
  `is-active` consulta los symlinks de `/var/service` (y `pgrep` en unidades `--user`), `stop`→`sv stop`/`pkill`,
  `reboot`/`poweroff`→ binarios reales, y `start`/`restart`/`daemon-reload` de usuario devuelven error a propósito
  para que los scripts upstream caigan en su fallback `setsid` (sin inventar lanzamientos falsos).
- **Gestión de Energía:** Integración nativa con `elogind` para manejar el cierre de tapa (suspend) de forma eficiente.
- **Referencia `refs/sys-init.go`:** abstracción `InitManager` (Systemd/Runit) lista para futura inclusión en el CLI
  cuando se decide no depender del shim. Nota: los módulos Go de Ryoku (`cli`, `hub/backend`, `shell/ipc`) son
  independientes — no se pueden importar entre sí; duplica o usa build tags dentro de cada módulo.

## 🔑 Actualizaciones sin contraseña (botón Update del Hub)

`ryoku update` necesita algunos `sudo` puntuales (instalar helpers en `/usr/bin`,
recargar el shim `systemctl`, aplicar el tema de arranque). Sin TTY esos pasos
fallan, así que el port incluye una regla sudoers acotada:

```sh
sudo install -m0440 sudoers/ryoku-update /etc/sudoers.d/zz-ryoku-update
```

*   **Comandos permitidos sin contraseña:** `install`, `cp`,
    `/usr/local/bin/systemctl` (el shim), `ryoku-boot-apply` y
    `xbps-install -Su` (solo para `ryoku update --system`).
*   **Nombre `zz-*`: sudo aplica la última regla que casa**; el archivo debe
    ordenarse después de `wheel` para que el NOPASSWD gane.
*   ⚠️ **Seguridad:** `install`/`cp` como root equivalen funcionalmente a dar
    privilegios de root al usuario. Aceptable en un equipo personal de un solo
    usuario — **no instalar en máquinas multiusuario**.
