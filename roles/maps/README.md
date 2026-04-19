# Role: maps

Renders per-map configuration and the cluster-wide `Game.ini`:

- `{{ arkmanager_config_dir }}/instances/<map>.cfg` — arkmanager instance config (ports, session name, mods, cluster ID, MultiHome)
- `{{ arkmanager_config_dir }}/files/<map>/GameUserSettings.ini` — per-map gameplay settings
- `{{ arkmanager_config_dir }}/files/Game.ini` — cluster-wide gameplay mechanics
- `{{ ark_server_root }}/ShooterGame/Saved/AllowedCheaterSteamIDs.txt` — admin SteamID list
- Installs/updates enabled mods per map via `arkmanager update --update-mods`

## Required variables

Set in `group_vars/gameservers.yml` (see [docs/examples/](../../docs/examples/) for full examples):

- `location`, `server_tag`, `server_mode` (`PvE` or `PvP`)
- `maps:` list, each entry with `map_name_ark`, `map_name`, `map_rcon_port`, `map_ark_port`, `map_steam_port`, `map_admin_password`, `map_max_players`, `map_mods_enabled`, `cluster_name`
- `admins:` list of 17-digit SteamIDs (may be empty)

## Tunable gameplay defaults

Defined in `defaults/main.yml`, overrideable per deployment:

`taming_speed_multiplier`, `harvest_amount_multiplier`, `harvest_health_multiplier`, `xp_multiplier`, `max_tamed_dinos`, `override_official_difficulty`, `player_damage_multiplier`, `pve_dino_decay_period_multiplier`, `pve_structure_decay_period_multiplier`, `resources_respawn_period_multiplier`, `motd_duration`.

## Overlays: bring your own .ini

Drop files into a local `config/` directory at the playbook root to overlay the rendered templates:

```
config/
  Game.ini                               # cluster-wide (optional)
  maps/
    <MapName>/GameUserSettings.ini       # per-map (optional)
```

Renders happen first; overlays copy on top. `config/` is gitignored. Great for Beacon.app exports or hand-tuned configs.

## Handlers

- `restart map` — runs `arkmanager restart @<map_name>` for every map, notified when any of the config files or mods change.

## Known quirk: Game.ini template is opinionated

The bundled [Game.ini.j2](templates/Game.ini.j2) ships with an extensive tuning preset — custom item stacks (ammo, berries, resources), supply crate loot tables, and per-level engram-point allocations. This reflects the originating cluster's feel, not a neutral default.

If you want stock ARK behaviour, drop your own `config/Game.ini` (even an empty one will reset to engine defaults). The overlay mechanism applies it after the template, so your file wins.

A cleaner split (minimal base template + opt-in preset files under `presets/`) is open for contributions — see [GH issue tracker].
