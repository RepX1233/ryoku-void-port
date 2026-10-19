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
- **Daemon Inmortal:** `ryoku-shell` es supervisado por `runit`. Si el proceso muere, se reinicia automáticamente.
- **Gestión de Energía:** Integración nativa con `elogind` para manejar el cierre de tapa (suspend) de forma eficiente.
