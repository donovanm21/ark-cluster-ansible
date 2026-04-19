# Role: system

Lifecycle automation — what makes the cluster self-sustaining once deployed.

## What it installs

Under `{{ ark_home }}`:

- `ark_mod_checker.sh` — hourly cron, triggers a restart-update if any mod has a new version.
- `ark_update_checker.sh` — hourly cron, triggers a restart-update if the ARK server binary has a new version.
- `ark_rcon_cmd.sh` — invoked by the dino-wipe cron to send the RCON `destroywilddinos` command.
- `ark_system_update.sh` — master restart-update script: broadcasts, stops, backs up, updates, staggers restarts.
- `ark_map_start.sh` — invoked at `@reboot`, starts every configured map with a 30s stagger.
- `ark_watchdog.sh` — invoked every `watchdog_interval_minutes` (default 5), checks each map's arkmanager status and restarts any that aren't running.
- `crontab.txt` — rendered from templates, imported into the ark user's crontab.

Under `/etc/logrotate.d/arkmanager`:

- Rotates `{{ ark_server_root }}/ShooterGame/Saved/Logs/*.log` daily (14 days, compressed).
- Rotates `/var/log/arkmanager/**.log` weekly (8 weeks).

## Cron schedule

```
@reboot                                  ark_map_start.sh         # boot-time startup
59 * * * *                               ark_update_checker.sh    # hourly game update check
30 * * * *                               ark_mod_checker.sh       # hourly mod update check
*/5 * * * *                              ark_watchdog.sh          # crash recovery (5 min)
30/45/55 (update_hour-1) * * *           broadcast 30/15/5-min warnings
0  update_hour * * *                     arkmanager stop @all
2  update_hour * * *                     tar cluster save dir
5  update_hour * * *                     arkmanager backup @all
7  update_hour * * *                     arkmanager update
10 update_hour * * *                     arkmanager update --update-mods
14/16/18/… update_hour * * *             staggered arkmanager start @<map>
```

Dino wipes are optional (`enable_dino_wipe: true`) and use the same broadcast → wipe pattern.

## Variables

| Variable | Default | Purpose |
|---|---|---|
| `enable_daily_restart` | `true` | Daily restart + update + backup pipeline |
| `daily_update_hour` | `4` | Hour (24h) at which the daily pipeline runs |
| `enable_dino_wipe` | `false` | Scheduled wild dino wipes |
| `dino_wipe_hours` | `[0, 12]` | Hours at which wild dinos are wiped |
| `enable_watchdog` | `true` | Crash-recovery cron |
| `watchdog_interval_minutes` | `5` | How often the watchdog runs |

## Watchdog behaviour

The watchdog:

1. Skips its own window if `date +%H` is `(daily_update_hour - 1)` or `daily_update_hour` — don't fight the planned stop.
2. For each configured map, greps `arkmanager status @<map>` for `Server running.*Yes`.
3. If not running, posts to Discord (if `discord_webhook_url` is set) and backgrounds `arkmanager start @<map>`.
4. Logs via `logger -t ark-watchdog` to syslog.
