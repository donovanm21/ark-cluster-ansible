# Role: provision

Bootstraps the target host for running arkmanager:

1. Installs the base dependencies arkmanager + steamcmd need: `htop`, `git`, `perl-modules`, `curl`, `lsof`, `libc6-i386`, `lib32gcc-s1`, `bzip2`.
2. Creates the ark server user (`{{ ark_user }}`, default `ark`) with home `{{ ark_home }}` and a fresh `~/.ssh/id_rsa`.
3. Drops a NOPASSWD sudo rule into `/etc/sudoers.d/{{ ark_user }}` (gated on `manage_sudoers`).
4. Purges UFW (gated on `manage_firewall`).

## Variables

| Variable | Default | Source | Purpose |
|---|---|---|---|
| `ark_user` | `ark` | `group_vars/all.yml` | System user that owns the server install |
| `ark_home` | `/home/{{ ark_user }}` | `group_vars/all.yml` | Home directory for that user |
| `manage_sudoers` | `true` | `defaults/main.yml` | Create `/etc/sudoers.d/<ark_user>` NOPASSWD entry |
| `manage_firewall` | `true` | `defaults/main.yml` | Apt-remove UFW (legacy default) |

## Security notes

- **NOPASSWD sudo** is a blunt tool. It grants the ark user unrestricted privilege escalation, which arkmanager uses freely. If your site has its own sudoers management, set `manage_sudoers: false`.
- **UFW removal** is retained for backwards compatibility with the original playbook. Consider setting `manage_firewall: false` and adding explicit UFW rules for the ARK ports instead.
