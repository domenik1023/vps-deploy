# Ansible Playbook for VPS Hardening

## Description

Hardens a fresh Ubuntu VPS with:

- SSH key-only authentication on a custom port (22822), with port 22 denied after hardening
- UFW firewall with connection-rate limiting on the SSH port
- Fail2ban intrusion detection (bans after 5 failed attempts)
- CrowdSec agent (log processor) reporting to a central LAPI server, with firewall bouncer pulling shared ban decisions
- Root account locked (no password, no login shell)
- Kernel hardening via sysctl (SYN cookies, ASLR, ICMP filtering, anti-spoofing)
- Docker Engine with security daemon config (log rotation, live-restore, user namespace remap)
- Chrony NTP for accurate system time
- Daily unattended security upgrades

## Project Structure

```
vps-deploy/
├── main.yml                          # Entry point
├── inventory                         # Host definitions (vps / local groups)
├── ansible.cfg                       # Ansible settings
├── group_vars/
│   └── all/
│       └── vault.yml                 # Encrypted secrets (ansible-vault)
└── roles/
    └── config/
        ├── defaults/
        │   └── main.yml              # All configurable variables
        ├── handlers/
        │   └── main.yml              # Service restart handlers
        └── tasks/
            ├── main.yml              # Task orchestration
            ├── user.yml              # Admin user + sudo setup
            ├── hardening.yml         # SSH, UFW, Fail2ban, root lockdown
            ├── sysctl.yml            # Kernel parameter hardening
            ├── software.yml          # Docker, NTP, auto-updates
            └── crowdsec.yml          # CrowdSec agent + firewall bouncer
```

## Prerequisites

1. Target host is running Ubuntu (tested on 22.04/24.04/26.04)
2. SSH access as root (or a user with sudo) is available on port 22 for the initial run
3. Your public key is present in `~/.ssh/domenik1023.pub` (or adjust the private key path below)
4. Python 3 is installed on the target host
5. Ansible collections installed locally:
   ```bash
   ansible-galaxy collection install -r requirements.yml
   ```

## Secrets Setup (Ansible Vault)

The admin user password is stored in `group_vars/all/vault.yml` and **must be encrypted** before committing.

1. Generate a sha512-crypt password hash:
   ```bash
   python3 -c "from passlib.hash import sha512_crypt; print(sha512_crypt.hash('yourpassword'))"
   ```

2. Edit the vault file and set the hash:
   ```bash
   ansible-vault edit group_vars/all/vault.yml
   ```
   Set `vault_admin_password` to the hash generated above.

3. On first use, encrypt the file if it is still plaintext:
   ```bash
   ansible-vault encrypt group_vars/all/vault.yml
   ```

## Configuration

All tunable values live in `roles/config/defaults/main.yml`:

| Variable | Default | Description |
|---|---|---|
| `admin_user` | `domenik1023` | Admin username to create |
| `admin_password` | `{{ vault_admin_password }}` | sha512-crypt hash (from vault) |
| `ssh_port` | `22822` | Custom SSH port |
| `ssh_old_port` | `22` | Standard port to deny after hardening |
| `fail2ban_maxretry` | `5` | Failed attempts before ban |
| `fail2ban_findtime` | `10m` | Time window for failed attempts |
| `fail2ban_bantime` | `1h` | How long IPs stay banned |
| `docker_data_dir` | `/mnt/docker` | Mount point for Docker volumes |
| `crowdsec_collections` | `[crowdsecurity/linux]` | CrowdSec collections (parsers + scenarios) to install |
| `crowdsec_firewall_bouncer` | `crowdsec-firewall-bouncer-iptables` | Bouncer package (`-nftables` variant for pure-nftables hosts) |
| `crowdsec_lapi_url` | `https://lapi.example.com:8080` | Central LAPI server URL (override per environment) |
| `crowdsec_lapi_login` | `{{ inventory_hostname }}` | Machine login on the central LAPI |
| `crowdsec_lapi_password` | `{{ vault_crowdsec_lapi_password }}` | Machine password (from vault) |
| `crowdsec_bouncer_api_key` | `{{ vault_crowdsec_bouncer_api_key }}` | Bouncer API key (from vault) |

## Usage

### Initial run (port 22, root or sudo user)

```bash
ansible-playbook main.yml -i inventory \
  --private-key=~/.ssh/domenik1023 \
  --ask-vault-pass \
  -u root
```

### Subsequent runs (custom port, admin user)

After hardening, SSH is on port 22822 and root login is disabled:

```bash
ansible-playbook main.yml -i inventory \
  --private-key=~/.ssh/domenik1023 \
  --ask-vault-pass \
  -u domenik1023
```

Update the inventory `ansible_port` to `22822` for VPS hosts after the first run.

### Dry run (check mode)

```bash
ansible-playbook main.yml -i inventory --private-key=~/.ssh/domenik1023 --ask-vault-pass --check
```

## Notes

- The `[local]` inventory group skips SSH hardening to prevent self-lockout during testing
- CrowdSec is installed from the official packagecloud repository and runs alongside Fail2ban; both can ban independently. CrowdSec reads sshd events directly from journald, so it works on minimal images without rsyslog.
- CrowdSec runs in **agent-only mode**: the local API server is disabled and the agent pushes alerts to the central LAPI server (`crowdsec_lapi_url`). The firewall bouncer pulls decisions from the same central LAPI, so bans made anywhere in the fleet apply on this host too. Before the first run, provision credentials **on the LAPI server**:
  ```bash
  cscli machines add <inventory_hostname> --password '<password>'   # -> vault_crowdsec_lapi_password
  cscli bouncers add <host>-firewall-bouncer                        # -> vault_crowdsec_bouncer_api_key
  ```
  CAPI enrollment/console registration happens on the central LAPI server, not on the agents.
- `host_key_checking` is disabled in `ansible.cfg` for the initial connection; use `ssh-keyscan` to pre-populate `known_hosts` in production environments
