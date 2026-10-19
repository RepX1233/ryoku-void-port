package sys

import (
	"os/exec"
)

type InitManager interface {
	IsActive(service string) bool
	Restart(service string) error
	Stop(service string) error
}

type SystemdManager struct{}
func (s *SystemdManager) IsActive(service string) bool { return exec.Command("systemctl", "--user", "is-active", "--quiet", service).Run() == nil }
func (s *SystemdManager) Restart(service string) error { return exec.Command("systemctl", "--user", "restart", service).Run() }
func (s *SystemdManager) Stop(service string) error    { return exec.Command("systemctl", "--user", "stop", service).Run() }

type RunitManager struct{}
func (r *RunitManager) IsActive(service string) bool { return exec.Command("sv", "status", service).Run() == nil }
func (r *RunitManager) Restart(service string) error { return exec.Command("sudo", "sv", "restart", service).Run() }
func (r *RunitManager) Stop(service string) error    { return exec.Command("sudo", "sv", "stop", service).Run() }

func GetInitManager() InitManager {
	if Has("systemctl") { return &SystemdManager{} }
	return &RunitManager{}
}
