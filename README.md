# ARK Cluster Ansible

Ansible playbook for bringing up a full ARK: Survival Evolved cluster on a single Linux host. Supports both **PvE** and **PvP** modes via a single config flag. Uses [arkmanager](https://github.com/arkmanager/ark-server-tools) under the hood.

## Features

- One-shot deployment of a multi-map ARK cluster
- PvE or PvP mode switch (`server_mode: "PvE" | "PvP"`) flips the relevant ini flags
- Sensible `Game.ini` and `GameUserSettings.ini` defaults, fully overridable per-map
- Daily update + restart + backup cron pipeline
- Optional scheduled wild dino wipes
- Optional Discord webhook notifications for server lifecycle events

## Repository layout

- `main.yml` — top-level playbook
- `group_vars/gameservers.yml.example` — copy this to `gameservers.yml` and edit for your cluster
- `roles/provision/` — base OS setup, creates the `ark` user (prerequisite)
- `roles/arkmanager/` — installs arkmanager (prerequisite)
- `roles/system/` — deploys update/startup scripts and the crontab
- `roles/maps/` — deploys per-map instance configs, `GameUserSettings.ini`, `Game.ini`, mods

## Prerequisites

- A fresh Linux host (Debian/Ubuntu tested) with SSH access as root
- Ansible 2.10+ on your workstation
- Enough disk for ARK (~50 GB per map) and RAM (~6 GB per running map)

## Quickstart

1. Clone the repo on the target host (or control node).
2. Copy the example config and inventory, then edit:
   ```sh
   cp group_vars/gameservers.yml.example group_vars/gameservers.yml
   cp inventory_remote.example inventory_remote
   ${EDITOR:-vim} group_vars/gameservers.yml
   ```
   Both real files are gitignored so your cluster-specific values stay out of the repo.
3. Set `server_mode`, pick your maps, set unique ports, set an admin password, and drop in admin SteamIDs.
4. Run:
   ```sh
   ansible-playbook -i inventory_remote main.yml
   ```

## Bringing your own ini files

If you already tune your server via [Beacon](https://usebeacon.app) or hand-edited configs, drop them into a local `config/` directory and they will overlay the templates:

```
config/
  Game.ini                              # cluster-wide (optional)
  maps/
    Ragnarok/GameUserSettings.ini       # per-map (optional)
    TheIsland/GameUserSettings.ini
```

The playbook always renders the default template first, then overwrites with your file if present.

## Optional variables

Set any of these in `group_vars/gameservers.yml`:

- `discord_webhook_url` — enables Discord notifications
- `banlist_url` — external banlist pulled by ARK on startup
- `taming_speed_multiplier`, `harvest_amount_multiplier`, `xp_multiplier`, etc. — gameplay tuning
- `enable_daily_restart` (default: `true`), `daily_update_hour` (default: `4`)
- `enable_dino_wipe` (default: `false`), `dino_wipe_hours` (default: `[0, 12]`)

## Contributing

Issues and pull requests welcome.

## License

See [LICENSE](LICENSE).
