# ARK Cluster Ansible

Ansible playbook for bringing up a full **ARK: Survival Evolved** cluster on a single Linux host. Supports both **PvE** and **PvP** via one config flag. Uses [arkmanager](https://github.com/arkmanager/ark-server-tools) under the hood.

## What you get

- **One-shot deployment** of a multi-map ARK cluster — pick any combination of Ragnarok, TheIsland, ScorchedEarth, Aberration, Extinction, Valguero, TheCenter, CrystalIsles, Fjordur, Genesis, Genesis 2, Lost Island.
- **PvE or PvP** selected by a single `server_mode` flag; the relevant `.ini` switches flip automatically.
- **Sensible `Game.ini` and `GameUserSettings.ini` defaults**, fully overridable per-map via a `config/` overlay.
- **Self-sustaining lifecycle automation** — runs without hand-holding once deployed:
  - Daily restart + game update + mod update + backup pipeline (03:30 warnings, 04:00 stop, 04:10 update).
  - Hourly game-update and mod-update checks (triggers an unscheduled restart if needed).
  - 5-minute crash watchdog — any map that dies between restarts comes back automatically.
  - Optional scheduled wild dino wipes.
  - Optional Discord webhook notifications for lifecycle events.
  - logrotate config for ShooterGameServer + arkmanager logs.
- **Built-in CI/CD** — Gitea Actions (and GitHub Actions mirror) run yamllint, ansible-lint, `ansible-playbook --syntax-check`, and gitleaks on every push. A Gitea deploy workflow applies to your target host on successful test.

## Repository layout

```
.
├── main.yml                          top-level playbook
├── group_vars/
│   ├── all.yml                       project-wide defaults (ark_user, ark_home, etc.)
│   └── gameservers.yml.example       copy to gameservers.yml and edit
├── inventory_remote.example          copy to inventory_remote and edit
├── roles/
│   ├── provision/                    OS deps, ark user, sudoers, firewall
│   ├── arkmanager/                   arkmanager netinstall
│   ├── maps/                         per-map instance.cfg, Game.ini, mods
│   └── system/                       crontab, watchdog, logrotate, helper scripts
├── .gitea/workflows/                 test.yml + deploy.yml (Gitea Actions)
├── .github/workflows/                test.yml (GitHub Actions mirror)
└── docs/
    ├── examples/gameservers.pve.yml  full PvE cluster example
    └── examples/gameservers.pvp.yml  full PvP cluster example
```

## Prerequisites

- A fresh Linux host (Ubuntu 20.04+ / Debian 11+ tested) with SSH access.
- Ansible 2.10+ on your workstation (or the target host, if you're running locally).
- ~50 GB disk per map for ARK content.
- ~6 GB RAM per *running* map (the host can have more maps configured than running concurrently).
- Open TCP/UDP for each map's game port, query port, and RCON port (default scheme in the example config avoids conflicts).

## Quickstart

```sh
# 1. Clone
git clone https://your.gitea/Homelab/ark-cluster-ansible.git
cd ark-cluster-ansible

# 2. Copy and edit the example config + inventory
cp group_vars/gameservers.yml.example group_vars/gameservers.yml
cp inventory_remote.example inventory_remote
${EDITOR:-vim} group_vars/gameservers.yml

# 3. Run
ansible-playbook -i inventory_remote main.yml
```

Both `group_vars/gameservers.yml` and `inventory_remote` are gitignored so your cluster-specific values (admin passwords, SteamIDs, map topology) never leak to the repo.

For ready-to-go templates, see [docs/examples/](docs/examples/):
- [gameservers.pve.yml](docs/examples/gameservers.pve.yml) — PvE cluster, faster progression
- [gameservers.pvp.yml](docs/examples/gameservers.pvp.yml) — PvP cluster, offline raid protection

## Bringing your own ini files

If you tune via [Beacon](https://usebeacon.app) or have hand-edited `.ini` files, drop them into a local `config/` directory and they'll overlay the rendered templates:

```
config/
  Game.ini                              # cluster-wide (optional)
  maps/
    Ragnarok/GameUserSettings.ini       # per-map (optional)
    TheIsland/GameUserSettings.ini
```

The playbook renders the default template first, then overwrites with your file if present. The `config/` directory is gitignored.

## Key variables

All variables below live in `group_vars/gameservers.yml`. See [group_vars/all.yml](group_vars/all.yml) for the project-wide identity vars (`ark_user`, `ark_home`, `ark_server_root`, `arkmanager_config_dir`).

### Identity
| Variable | Default | Purpose |
|---|---|---|
| `location` | — | 2-letter region code shown in SessionName (`US`, `EU`, `ZA`, …) |
| `server_tag` | — | Short cluster tag |
| `server_mode` | — | `PvE` or `PvP` — flips the relevant `.ini` switches |

### Gameplay tuning (maps role defaults)
| Variable | Default | Purpose |
|---|---|---|
| `taming_speed_multiplier` | `4.5` | How fast taming progresses |
| `harvest_amount_multiplier` | `2` | Resources per harvest |
| `harvest_health_multiplier` | `2` | Node HP before depletion |
| `xp_multiplier` | `1` | Player XP gain |
| `max_tamed_dinos` | `10000` | Cluster-wide tame cap |
| `override_official_difficulty` | `5` | Wild dino level scaling |
| `player_damage_multiplier` | `1.0` | Player damage dealt |
| `pve_dino_decay_period_multiplier` | `5` | PvE: dino decay grace (days) |
| `pve_structure_decay_period_multiplier` | `2.5` | PvE: structure decay grace |
| `resources_respawn_period_multiplier` | `0.75` | How fast resource nodes respawn |

### Lifecycle automation (system role defaults)
| Variable | Default | Purpose |
|---|---|---|
| `enable_daily_restart` | `true` | Daily restart+update+backup pipeline |
| `daily_update_hour` | `4` | Hour (24h) to run the daily pipeline |
| `enable_dino_wipe` | `false` | Scheduled wild dino wipe |
| `dino_wipe_hours` | `[0, 12]` | Hours to wipe wild dinos |
| `enable_watchdog` | `true` | 5-min crash recovery cron |
| `watchdog_interval_minutes` | `5` | How often the watchdog runs |

### Provision role flags
| Variable | Default | Purpose |
|---|---|---|
| `manage_sudoers` | `true` | Create `/etc/sudoers.d/<ark_user>` with NOPASSWD |
| `manage_firewall` | `true` | Purge UFW (legacy behaviour; opt out if you manage your own firewall) |

### Map entries
Each map in the `maps:` list takes the same shape:

```yaml
- map_name_ark: "Ragnarok"          # internal ARK map ID
  map_name: "Ragnarok"               # display name
  map_rcon_port: 32332               # RCON port (unique per map)
  map_ark_port: 7779                 # game port (unique per map)
  map_steam_port: 27017              # Steam query port (unique per map)
  map_admin_password: "CHANGE_ME"    # RCON admin password
  map_max_players: 25                # player cap
  map_mods_enabled: ""               # comma-separated Steam Workshop IDs
  cluster_name: "MyCluster"          # shared across maps for cross-transfer
```

## PvE vs PvP

Setting `server_mode: PvE` vs `PvP` flips these automatically:

| Setting | PvE | PvP |
|---|---|---|
| `bAutoPvETimer` | `True` | `False` |
| `bDisableFriendlyFire` | `True` | `False` |
| `PreventOfflinePvP` | `False` | `True` |
| `PvPDinoDecay` / `PvPStructureDecay` | `False` | `True` |
| `ark_ServerPVE` | `True` | `False` |

Everything else is mode-agnostic. For deeper tuning, copy one of the [docs/examples/](docs/examples/) configs as a starting point.

## CI/CD

`.gitea/workflows/test.yml` (mirrored as `.github/workflows/test.yml`) runs on every push and PR:

1. **yamllint** — style + structural linting of every YAML file.
2. **ansible-lint** — advisory; flags anti-patterns but doesn't block the build.
3. **ansible-playbook --syntax-check** + `--list-tasks` — structural sanity.
4. **gitleaks** — scans the full history for leaked secrets.

`.gitea/workflows/deploy.yml` runs after a successful test workflow on `main` (or on manual `workflow_dispatch`):

1. SSHes to your target host (`ARK_DEPLOY_HOST`, `ARK_DEPLOY_USER`, `ARK_DEPLOY_SSH_KEY` secrets).
2. `git reset --hard origin/main` in `/root/ark-cluster-ansible` (your local `gameservers.yml` is gitignored and preserved).
3. Always runs `ansible-playbook --check --diff` for a visible dry-run report.
4. Applies unless `workflow_dispatch` was invoked with `mode=check`.
5. Smoke-test: `arkmanager status @all` + crontab spot-check.

To wire it up on your Gitea: set the three secrets above on the repo (Settings → Actions → Secrets) and ensure your runner has a label including `ubuntu-latest`.

## Security notes

- **NOPASSWD sudo**: the provision role creates `/etc/sudoers.d/<ark_user>` granting passwordless sudo to the ark user. This is required for `arkmanager` lifecycle operations. Set `manage_sudoers: false` if you want to manage sudoers yourself.
- **UFW removal**: historically the playbook purges UFW to avoid a silently-blocking firewall. This is opt-out (`manage_firewall: false`). A future improvement is explicit UFW rules for the ARK ports — PRs welcome.
- **Admin passwords**: the example config ships `map_admin_password: "CHANGE_ME"`. Change before first deploy.
- **Secrets in CI**: the deploy workflow requires the target host SSH private key as a Gitea secret. Treat that repo accordingly.

## Contributing

Issues and pull requests welcome. CI must be green before merge.

## License

[MIT](LICENSE).
