#cloud-config
# First-boot bootstrap ONLY: give Ansible a way in, nothing more.
# Packages, users, SSH hardening, firewall and k3s are Ansible's job, so they
# stay idempotent, reviewable and re-runnable (cloud-init runs once per VM).
hostname: ${NODE_NAME}
manage_etc_hosts: false        # Ansible owns /etc/hosts

users:                         # no "default" entry: the stock "ubuntu" user is not created
  - name: ansible
    gecos: Ansible automation account
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: false
    # Break-glass password for the Hyper-V console only (SSH password logins
    # are disabled below). Generated per lab by prepare-image.sh, never in Git.
    hashed_passwd: "${CONSOLE_PASSWORD_HASH}"
    ssh_authorized_keys:
      - ${SSH_PUBLIC_KEY}

ssh_pwauth: false
disable_root: true
package_update: false
package_upgrade: false
