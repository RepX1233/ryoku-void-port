// Package sys — integración NATIVA de Ryoku con runit/turnstile en Void.
//
// Esta es la evolución de la abstracción InitManager del port: en lugar de
// engañar a las aplicaciones con un shim global de /usr/local/bin/systemctl,
// los módulos Go consultan y controlan los servicios de USUARIO a través de
// `sv` con SVDIR apuntando al dir supervisado por turnstile
// (~/.config/service, enlazado como $XDG_RUNTIME_DIR/service por
// bin/ryoku-session-init). Todo SIN sudo.
//
// La energía (poweroff/reboot/suspend) va por `loginctl` (elogind) o por los
// binarios directos (`zzz` para suspender) — nunca por un systemctl falso.
//
// Parche equivalente en el monorepo: patches/0001-void-runit-init.patch
package sys

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// InitManager es la interfaz que usan CLI, hub/backend y shell/ipc.
type InitManager interface {
	// IsActive reporta si un servicio de usuario está en marcha.
	IsActive(service string) bool
	// Start/Restart/Stop controlan servicios de usuario SIN privilegios.
	Start(service string) error
	Restart(service string) error
	Stop(service string) error
	// Power ejecuta poweroff|reboot|suspend del sistema.
	Power(action string) error
}

// ---------------------------------------------------------------------------
// systemd (Arch/Fedora): se mantiene igual que antes.
// ---------------------------------------------------------------------------

type SystemdManager struct{}

func (s *SystemdManager) IsActive(service string) bool {
	return exec.Command("systemctl", "--user", "is-active", "--quiet", service).Run() == nil
}
func (s *SystemdManager) Start(service string) error {
	return exec.Command("systemctl", "--user", "start", service).Run()
}
func (s *SystemdManager) Restart(service string) error {
	return exec.Command("systemctl", "--user", "restart", service).Run()
}
func (s *SystemdManager) Stop(service string) error {
	return exec.Command("systemctl", "--user", "stop", service).Run()
}
func (s *SystemdManager) Power(action string) error {
	return exec.Command("systemctl", action).Run()
}

// ---------------------------------------------------------------------------
// runit + turnstile (Void): servicios de usuario, sin sudo, sin systemctl.
// ---------------------------------------------------------------------------

// ErrNoUserServices indica que no hay dir de servicios de usuario (turnstile
// sin sesión activa). Los llamadores lo tratan como "servicio no disponible",
// no como crash.
var ErrNoUserServices = errors.New("runit: sin dir de servicios de usuario (¿turnstile/ sesión gráfica?)")

type RunitManager struct{}

// UserServicesDir resuelve el dir de servicios de usuario en este orden:
//  1. $SVDIR                        (control explícito del llamador)
//  2. $XDG_RUNTIME_DIR/service      (enlace que hace ryoku-session-init)
//  3. ~/.config/service             (dir real supervisado por turnstile)
func (r *RunitManager) UserServicesDir() string {
	if d := os.Getenv("SVDIR"); d != "" {
		return d
	}
	if x := os.Getenv("XDG_RUNTIME_DIR"); x != "" {
		p := filepath.Join(x, "service")
		if fi, err := os.Lstat(p); err == nil && (fi.IsDir() || fi.Mode()&os.ModeSymlink != 0) {
			return p
		}
	}
	if h, err := os.UserHomeDir(); err == nil {
		return filepath.Join(h, ".config", "service")
	}
	return ""
}

// sv ejecuta `sv <verb> <servicio>` con SVDIR del usuario. Nota: `sv` devuelve
// 0 si el servicio está en marcha para verbos de estado; para start/stop la
// ausencia de error basta.
func (r *RunitManager) sv(verb, service string) error {
	dir := r.UserServicesDir()
	if dir == "" {
		return ErrNoUserServices
	}
	if _, err := os.Stat(filepath.Join(dir, service)); err != nil {
		return fmt.Errorf("runit: servicio desconocido %q en %s: %w", service, dir, err)
	}
	cmd := exec.Command("sv", verb, service)
	// SVDIR manda: sv lee esta variable para localizar el dir de control.
	cmd.Env = append(os.Environ(), "SVDIR="+dir)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("sv %s %s: %w (%s)", verb, service, err, strings.TrimSpace(string(out)))
	}
	return nil
}

func (r *RunitManager) IsActive(service string) bool {
	dir := r.UserServicesDir()
	if dir == "" {
		return false
	}
	// `sv status` imprime "run: ..." si está en marcha y sale con 0 también
	// en algunos versiones; el texto es la fuente de verdad.
	cmd := exec.Command("sv", "status", service)
	cmd.Env = append(os.Environ(), "SVDIR="+dir)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return false
	}
	return strings.HasPrefix(string(out), "run:")
}
func (r *RunitManager) Start(service string) error   { return r.sv("up", service) }
func (r *RunitManager) Restart(service string) error { return r.sv("restart", service) }
func (r *RunitManager) Stop(service string) error    { return r.sv("down", service) }

// Power actúa sobre el Sistema, no sobre servicios:
//   - poweroff/reboot: `loginctl` (elogind) y, si no, el binario directo.
//   - suspend: `loginctl suspend`; en Void sin elogind, `zzz` (util-linux).
func (r *RunitManager) Power(action string) error {
	switch action {
	case "poweroff", "reboot", "suspend":
	default:
		return fmt.Errorf("runit: acción de energía no soportada %q", action)
	}
	// 1) loginctl (elogind): es lo que usa el resto del ecosistema Ryoku.
	if _, err := exec.LookPath("loginctl"); err == nil {
		if err := exec.Command("loginctl", action).Run(); err == nil {
			return nil
		}
	}
	// 2) Fallbacks directos.
	switch action {
	case "poweroff":
		return exec.Command("poweroff").Run()
	case "reboot":
		return exec.Command("reboot").Run()
	case "suspend":
		return exec.Command("zzz").Run()
	}
	return nil
}

// IsRunit reporta si el sistema NO corre systemd como init (mismo criterio que
// el seam `ryoku-host`: /run/systemd/system solo existe con systemd).
func IsRunit() bool {
	if v := os.Getenv("RYOKU_HOST_INIT"); v != "" {
		return v == "runit"
	}
	_, err := os.Stat("/run/systemd/system")
	return err != nil
}

// GetInitManager devuelve el manager adecuado para este sistema.
func GetInitManager() InitManager {
	if IsRunit() {
		return &RunitManager{}
	}
	return &SystemdManager{}
}
