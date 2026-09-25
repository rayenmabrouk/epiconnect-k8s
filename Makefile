# Entry point for every lab operation. Run from WSL, in the repository root.
#   make help
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

NODES    := $(shell jq -r '.nodes[].name' infra/lab.json)
HYPERV   := infra/hyperv
# Windows PowerShell, called through WSL interop; scripts are passed as Windows paths
PS       := powershell.exe -NoProfile -ExecutionPolicy Bypass -File
LABVM    = $(PS) "$$(wslpath -w $(HYPERV)/Invoke-LabVM.ps1)"
NODE     ?=
SNAPSHOT ?= fresh
node_arg  = $(if $(NODE),-Node $(NODE),)

##@ Control machine
bootstrap: ## Install pinned tooling in WSL (Ansible, kubectl, helm, image tools, SSH key)
	scripts/bootstrap-wsl.sh

##@ Lab VMs (Hyper-V)
image: ## Download + verify the Ubuntu cloud image; build base VHDX and cloud-init seed ISOs
	$(HYPERV)/prepare-image.sh

vms: ## Create and start the VMs, wait for SSH
	$(PS) "$$(wslpath -w $(HYPERV)/New-LabVMs.ps1)"

status: ## VM state, uptime, memory, checkpoints
	$(LABVM) -Action status

start: ## Start VMs (NODE=k3s-worker1 for one)
	$(LABVM) -Action start $(node_arg)

stop: ## Graceful shutdown (NODE=... for one)
	$(LABVM) -Action stop $(node_arg)

poweroff: ## Hard power-off, simulates a crash (NODE=... for one)
	$(LABVM) -Action poweroff $(node_arg)

checkpoint: ## Shut down, checkpoint as SNAPSHOT (default: fresh), start
	$(LABVM) -Action checkpoint -Snapshot $(SNAPSHOT)

restore: ## Roll every VM back to SNAPSHOT (default: fresh)
	$(LABVM) -Action restore -Snapshot $(SNAPSHOT)

destroy-vms: ## Delete the VMs and their disks (asks first)
	$(PS) "$$(wslpath -w $(HYPERV)/Remove-Lab.ps1)"

##@ Connectivity
ping: ## SSH to every node: hostname, IP, uptime, cloud-init status
	@for n in $(NODES); do \
	  ssh -o ConnectTimeout=5 -o BatchMode=yes "$$n" \
	    'printf "%-12s %-15s %-22s cloud-init: %s\n" "$$(hostname)" "$$(hostname -I | cut -d" " -f1)" "$$(uptime -p)" "$$(cloud-init status | cut -d" " -f2)"' \
	    || echo "$$n: UNREACHABLE"; \
	done

forget-hosts: ## Remove lab host keys from known_hosts (after recreating VMs)
	@for n in $(NODES) $$(jq -r '.nodes[].ip' infra/lab.json); do ssh-keygen -R "$$n" >/dev/null 2>&1 || true; done; echo "known_hosts cleaned"

##@ Help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"} /^##@/ {printf "\n%s\n", substr($$0, 5)} /^[a-z-]+:.*##/ {printf "  %-14s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: bootstrap image vms status start stop poweroff checkpoint restore destroy-vms ping forget-hosts help
