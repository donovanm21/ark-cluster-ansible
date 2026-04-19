# Security notes

## What this playbook does that you should know about

### NOPASSWD sudo for the ark user

`roles/provision` creates `/etc/sudoers.d/<ark_user>` with:

```
ark ALL=(ALL) NOPASSWD: ALL
```

arkmanager needs broad privilege for steamcmd, crontab import, and lifecycle operations. NOPASSWD removes an interactive prompt from automated crons.

If your site has its own sudoers management, set `manage_sudoers: false` in `group_vars/gameservers.yml`. You're on the hook for giving the ark user whatever rights arkmanager needs.

### UFW removal

`roles/provision` apt-removes UFW. This is legacy behaviour retained so existing deployments don't suddenly block game traffic on upgrade.

If you manage your own firewall (UFW, nftables, hardware firewall), set `manage_firewall: false`. Required open ports per map:

- `map_ark_port` (TCP/UDP, e.g. 7779)
- `map_steam_port` (UDP, e.g. 27017)
- `map_rcon_port` (TCP, e.g. 32332) — internal only unless you're RCON'ing from off-box

### The playbook runs with `become: true`

`main.yml` uses `connection: local` and `become: true`, writing to `/etc/sudoers.d/`, `/etc/arkmanager/`, `/etc/logrotate.d/`, and `/home/<ark_user>/`. It's expected to run on the target host as root (or via sudo).

## Reporting a vulnerability

Open a private Gitea issue or email the repository owner. Do not disclose in a public channel first. I'll acknowledge within a few days.

## What you should check before going public

- **`map_admin_password`** in `group_vars/gameservers.yml` — never commit. The file is gitignored.
- **Discord webhook URL** — if posted publicly, anyone can spam your channel. Store in `gameservers.yml`, not in a tracked file.
- **CI deploy secrets** — `ARK_DEPLOY_SSH_KEY` grants root on your ARK host. Treat the repo's admin access accordingly.

## Known limitations

- No encryption at rest for save files (arkmanager default).
- No log shipping — logs live on disk, rotated by `logrotate`.
- No RBAC — anyone with the admin password can cheat on the server.
