# Ryoku Shell — Port para Void Linux / Neko Void

Adaptación comunitaria del entorno gráfico **Ryoku** (Hyprland + Quickshell + Daemons en Go + Matugen) optimizada para sistemas **Void Linux** basados en **runit** y **xbps**.

---

## 🚀 ¿Qué es Ryoku?

Ryoku es un entorno de escritorio moderno, altamente personalizable y fluido construido sobre **Hyprland** (Wayland) y **Quickshell** (QML/Qt6), diseñado originalmente para Arch Linux / CachyOS. Este port adapta todo el ecosistema para funcionar de manera nativa en Void Linux sin dependencias de `systemd`.

---

## 🛠️ Componentes del Port

| Componente | Origen / Adaptación |
|---|---|
| **Compositor (Hyprland)** | Paquetes precompilados de Void Linux (repositorios comunitarios / `xbps-src`) |
| **Quickshell** | Reconstruido localmente con soporte `-DHYPRLAND=ON` (`xbps-src`, fijado en hold `_2`) |
| **Daemons y CLI** | `ryoku-shell`, `ryoku-hub`, `ryogami`, y `ryoku` (CLI) compilados en Go |
| **Widgets y QML** | `ryoku-blobs`, `Ryoku.Ui`, `Ryoku.FrameBars`, `Ryoku.PluginKit` (Qt6 QML plugins) |
| **Gestión de Servicios** | Sustitución de unidades de usuario de `systemd` por lanzamientos en segundo plano vía `setsid` y supervisión por `runit` |

---

## 📦 Guía de Instalación Paso a Paso

### Precondiciones
1. Tener una instalación base de **Void Linux** (glibc) funcionando con un usuario con privilegios `sudo`.
2. Conexión a internet activa.

### Paso 1: Clonar el repositorio del port
```sh
git clone https://github.com/RepX1233/ryoku-void-port.git
cd ryoku-void-port
```

### Paso 2: Instalación masiva de aplicaciones y base de sistema (`void-setup.sh`)
Este script habilita los repositorios `nonfree` y `multilib`, e instala la suite recomendada de aplicaciones (navegadores, multimedia, emuladores y herramientas de desarrollo) tanto por `xbps` como por `flatpak`:
```sh
sudo chmod +x void-setup.sh
sudo ./void-setup.sh
```

### Paso 3: Ejecutar el instalador de la Shell de Ryoku (`ryoku-void-install.sh`)
El script principal clona el monorepo oficial de Ryoku, compila los binarios, recompila Quickshell con soporte Wayland/Hyprland y materializa las configuraciones en tu usuario:
```sh
chmod +x ryoku-void-install.sh
sudo bash ryoku-void-install.sh
```
*   *Nota opcional:* Si deseas especificar un usuario objetivo que no sea el actual: `--user=tu_usuario`. Si ya tienes quickshell compilado: `--skip-quickshell`.

### Paso 4: Iniciar Sesión
1. Cierra sesión en tu gestor actual (SDDM con quiosco Weston recomendado).
2. Selecciona la sesión **Ryoku** en el menú de Wayland.
3. ¡Disfruta del entorno!

---

## 🎨 Wallpapers, Rices y Personalización

El ecosistema de Ryoku incluye potentes herramientas de personalización visual integradas:

*   **Ryogami (Daemon de Wallpapers & Temas):** Administra los fondos de pantalla y genera paletas dinámicas automáticas mediante `matugen` para toda la interfaz (barra, barras laterales, terminales y aplicaciones GTK/Qt).
*   **Comandos de Wallpaper:**
    *   `ryogami wallpaper ui` -> Abre el selector visual de fondos de pantalla.
    *   `ryogami wallpaper random` -> Selecciona y aplica un wallpaper aleatorio re-mapeando los colores del sistema al instante.
*   **Rices y Temas de la Comunidad:** Ryoku soporta perfiles visuales completos (como *Aperiture*, *Evangelion*, *Lumen*, etc.) gestionados a través de la tienda y el Hub de ajustes (`ryoku-hub` o Super+,).

---

## ⚙️ Mantenimiento y Comandos Útiles

*   **Actualizar/Recompilar la shell desde el monorepo:**
    ```sh
    cd ~/ryoku/ryoku/shell/ipc
    go build -o ~/.local/bin/ryoku-shell .
    ryoku materialize
    ryoku reload
    ```
*   **Diagnóstico del sistema:**
    ```sh
    ryoku doctor
    ```
*   **Reconstrucción del stack de Hyprland (si hay cambios de librerías .so):**
    ```sh
    cd ~/ryoku-void-build
    ./rebuild-hypr-stack.sh all
    ```

---

## 📄 Licencia

Este port y los scripts auxiliares se distribuyen bajo licencia **GPL-3.0**, en concordancia con el monorepo oficial de Ryoku (`github.com/ryoku-dev/ryoku`).
