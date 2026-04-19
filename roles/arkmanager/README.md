# Role: arkmanager

Installs [arkmanager](https://github.com/arkmanager/ark-server-tools) via its upstream `netinstall.sh`. Idempotent — skips the netinstall if `arkmanager` is already on PATH, and skips the `arkmanager install` (steamcmd + base tree) if that's also present.

## Variables

| Variable | Default | Source | Purpose |
|---|---|---|---|
| `arkmanager_installer_url` | upstream `master` | `defaults/main.yml` | Pin to a commit/tag for reproducibility |
| `ark_user` | `ark` | `group_vars/all.yml` | The `arkmanager install` runs as this user |

## Notes

- Network-dependent: the netinstall fetches directly from GitHub. For air-gapped setups, mirror `netinstall.sh` internally and point `arkmanager_installer_url` at your mirror.
- The `arkmanager install` step downloads the ~50 GB ARK server bundle from Steam — first run takes a while.
