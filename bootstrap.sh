#!/usr/bin/env bash
# bootstrap.sh — interactive TUI for ark-cluster-ansible.
#
# Run this on your target Linux host (the one that will run the cluster).
# Requires whiptail (auto-installed on Debian/Ubuntu if missing).
#
# Main menu:
#   Deploy    — wizard that builds group_vars/gameservers.yml, then runs ansible-playbook
#   Redeploy  — re-run ansible-playbook with the existing config (no wizard)
#   Dry-run   — ansible-playbook --check --diff (no writes)
#   Status    — arkmanager status @all
#   Edit      — open $EDITOR on group_vars/gameservers.yml
#   Destroy   — stop every map and remove arkmanager state (guarded)
#
# Destroy really does nuke the cluster — back up saves first.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR"
CONFIG_FILE="$REPO_DIR/group_vars/gameservers.yml"
EXAMPLE_CONFIG="$REPO_DIR/group_vars/gameservers.yml.example"
INVENTORY_FILE="$REPO_DIR/inventory_remote"
EXAMPLE_INVENTORY="$REPO_DIR/inventory_remote.example"

# Shared scratch file for capturing whiptail results. whiptail writes the
# selected value to stderr; we capture via `2>"$WT_TMP"` and read back.
# This is more robust than the `3>&1 1>&2 2>&3` fd-juggling pattern, which
# can leak ANSI escape sequences into the captured value.
WT_TMP=$(mktemp)
trap 'rm -f "$WT_TMP"' EXIT

# --- supported maps ------------------------------------------------------------
# ark_name | display_name | rcon_port | ark_port | steam_port | disk_gb (per map)
MAP_CATALOG=(
  "Ragnarok|Ragnarok|32332|7779|27017|8"
  "TheIsland|TheIsland|32344|7791|27029|5"
  "ScorchedEarth_P|ScorchedEarth|32330|7777|27015|4"
  "Aberration_P|Aberration|32334|7781|27019|5"
  "Extinction|Extinction|32338|7785|27023|6"
  "Valguero_P|Valguero|32342|7789|27027|7"
  "TheCenter|TheCenter|32346|7793|27031|5"
  "CrystalIsles|CrystalIsles|32340|7787|27025|8"
  "Fjordur|Fjordur|32352|7799|27037|8"
  "Gen2|Genesis2|32348|7795|27033|8"
  "Genesis|Genesis|32336|7783|27021|6"
  "LostIsland|LostIsland|32350|7797|27035|7"
)

# --- hardware baseline ---------------------------------------------------------
BASE_RAM_GB=4
BASE_DISK_GB=55
PER_MAP_RAM_GB=6
PER_MAP_DISK_GB=12

# --- TUI chrome ----------------------------------------------------------------
WT_TITLE="ark-cluster-ansible"
WT_BACKTITLE="Deploy a production-ready ARK cluster · one host · one command"
WT_H=22
WT_W=78

# --- wizard state (set by wizard functions, read by write_config) --------------
WIZ_LOC=""
WIZ_TAG=""
WIZ_MODE=""
WIZ_CLUSTER=""
declare -a WIZ_MAPS=()
WIZ_PASS=""
WIZ_DISCORD=""
WIZ_ADMINS=""

# --- helpers -------------------------------------------------------------------
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
log()  { printf '\n[*] %s\n' "$*"; }
step() { printf '\n[>] %s\n' "$*"; }
warn() { printf '\n[!] %s\n' "$*" >&2; }

require_root() {
    if [[ $EUID -ne 0 ]]; then
        die "Run this as root (or via sudo). The playbook writes to /etc/ and /home/."
    fi
}

ensure_pkg() {
    local pkg="$1" cmd="$2"
    if command -v "$cmd" >/dev/null 2>&1; then return; fi
    warn "$cmd is required but not installed."
    read -r -p "Install $pkg via apt? [Y/n] " reply
    if [[ "${reply,,}" == "n" ]]; then die "Cannot continue without $pkg."; fi
    log "Updating apt index..."
    apt-get update
    log "Installing $pkg (this may take a minute)..."
    apt-get install -y "$pkg"
}

check_prereqs() {
    require_root
    ensure_pkg whiptail whiptail
    ensure_pkg ansible-core ansible-playbook
    if [[ ! -f "$INVENTORY_FILE" ]]; then
        cp "$EXAMPLE_INVENTORY" "$INVENTORY_FILE"
        log "Created inventory_remote from example."
    fi
}

# --- host probe ----------------------------------------------------------------
probe_cpu_cores() { nproc 2>/dev/null || echo "?"; }
probe_ram_gb() {
    if [[ -r /proc/meminfo ]]; then
        awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo
    else
        echo "?"
    fi
}
probe_disk_gb() {
    df -BG --output=avail / 2>/dev/null | awk 'NR==2{gsub("G",""); print $1+0}' || echo "?"
}

host_capacity_line() {
    printf "Host capacity  —  CPU: %s cores  ·  RAM: %s GB  ·  Free disk (/): %s GB" \
        "$(probe_cpu_cores)" "$(probe_ram_gb)" "$(probe_disk_gb)"
}

required_ram_gb()  { echo $(( BASE_RAM_GB  + PER_MAP_RAM_GB  * $1 )); }
required_disk_gb() { echo $(( BASE_DISK_GB + PER_MAP_DISK_GB * $1 )); }

# --- whiptail wrappers ---------------------------------------------------------
# Whiptail writes its ncurses drawing AND its result value to stderr. Capturing
# stderr with `2>file` therefore gets both — UI escape sequences leak into the
# "value". To separate them cleanly, we use whiptail's --output-fd flag: the
# result goes to fd 3, which we redirect to the temp file; the drawing stays
# on stderr and reaches the terminal normally.
#
# Callers read the result with `$(<"$WT_TMP")` after the helper returns.

wt_run() {
    # Internal: empty the temp file, run whiptail with --output-fd 3, return rc.
    : >"$WT_TMP"
    whiptail --output-fd 3 "$@" 3>"$WT_TMP"
}

wt_input() {
    # $1=title, $2=prompt, $3=default
    wt_run --title "$1" --backtitle "$WT_BACKTITLE" \
        --inputbox "$2" 12 $WT_W "$3"
}

wt_password() {
    # $1=title, $2=prompt
    wt_run --title "$1" --backtitle "$WT_BACKTITLE" \
        --passwordbox "$2" 12 $WT_W
}

wt_menu() {
    # $1=title, $2=prompt, $3=listheight, $4..=key/value pairs
    local title="$1" prompt="$2" h="$3"
    shift 3
    wt_run --title "$title" --backtitle "$WT_BACKTITLE" \
        --menu "$prompt" $WT_H $WT_W "$h" "$@"
}

wt_checklist() {
    # $1=title, $2=prompt, $3=listheight, $4..=items
    local title="$1" prompt="$2" h="$3"
    shift 3
    wt_run --title "$title" --backtitle "$WT_BACKTITLE" \
        --checklist "$prompt" $WT_H $WT_W "$h" "$@"
}

wt_yesno() {
    # $1=title, $2=prompt [$3=--defaultno flag]
    # yesno returns only via exit code; no result to capture.
    local extra=()
    [[ "${3:-}" == "--defaultno" ]] && extra=(--defaultno)
    whiptail --title "$1" --backtitle "$WT_BACKTITLE" \
        "${extra[@]}" --yesno "$2" $WT_H $WT_W
}

wt_msgbox() {
    # $1=title, $2=msg — no result to capture.
    whiptail --title "$1" --backtitle "$WT_BACKTITLE" \
        --msgbox "$2" $WT_H $WT_W
}

wt_scrollmsg() {
    # $1=title, $2=msg — scrollable msgbox, no result to capture.
    whiptail --title "$1" --backtitle "$WT_BACKTITLE" \
        --scrolltext --msgbox "$2" $WT_H $WT_W
}

# --- TUI screens ---------------------------------------------------------------
welcome_screen() {
    wt_msgbox "$WT_TITLE" "\
Welcome.

This wizard will:
  1. Check your host meets minimum specs for the maps you choose
  2. Collect cluster identity, maps, admin password, optional Discord
  3. Write group_vars/gameservers.yml (gitignored — stays local)
  4. Run ansible-playbook to deploy

$(host_capacity_line)

You can re-run this tool any time for redeploys, status, or teardown."
}

main_menu() {
    wt_menu "$WT_TITLE" \
        "$(host_capacity_line)

What would you like to do?" 7 \
        "deploy"   "Deploy a new cluster (wizard + playbook)" \
        "redeploy" "Redeploy (re-run playbook with existing config)" \
        "dryrun"   "Dry-run (--check --diff, no writes)" \
        "status"   "Status (arkmanager status @all)" \
        "edit"     "Edit group_vars/gameservers.yml" \
        "destroy"  "Destroy cluster (stop + remove everything)" \
        "exit"     "Exit"
    local rc=$?
    if (( rc != 0 )); then
        echo "exit"
    else
        cat "$WT_TMP"
    fi
}

wizard_identity() {
    wt_input "Identity (1/4)" \
        "Two-letter region code for the session name (US, EU, ZA, …):" "US" || return 1
    WIZ_LOC=$(<"$WT_TMP")

    wt_input "Identity (2/4)" \
        "Short cluster tag shown in the Steam browser:" "MyCluster" || return 1
    WIZ_TAG=$(<"$WT_TMP")

    wt_menu "Identity (3/4)" "Server mode:" 2 \
        "PvE" "Player vs Environment — cooperative, no raiding" \
        "PvP" "Player vs Player — raiding, offline raid protection" || return 1
    WIZ_MODE=$(<"$WT_TMP")

    wt_input "Identity (4/4)" \
        "Cluster ID for cross-map tame/item transfers:" "${WIZ_TAG}_${WIZ_MODE}" || return 1
    WIZ_CLUSTER=$(<"$WT_TMP")
}

wizard_maps() {
    local choices=()
    for entry in "${MAP_CATALOG[@]}"; do
        IFS='|' read -r ark_name display rcon_p ark_p steam_p _ <<<"$entry"
        local default="OFF"
        [[ "$ark_name" == "Ragnarok" ]] && default="ON"
        choices+=("$ark_name" "$display  (ports $ark_p / $steam_p / $rcon_p)" "$default")
    done
    wt_checklist "Maps" \
        "Select the maps you want in your cluster.
SPACE toggles · ENTER confirms." 12 "${choices[@]}" || return 1

    # whiptail emits space-separated, quoted entries like: "Ragnarok" "TheIsland"
    local raw
    raw=$(<"$WT_TMP")
    WIZ_MAPS=()
    # Strip any quote characters, then split on whitespace.
    local cleaned="${raw//\"/}"
    read -r -a WIZ_MAPS <<<"$cleaned"
}

check_hardware() {
    local map_count="${#WIZ_MAPS[@]}"
    local need_ram need_disk have_ram have_disk
    need_ram=$(required_ram_gb "$map_count")
    need_disk=$(required_disk_gb "$map_count")
    have_ram=$(probe_ram_gb)
    have_disk=$(probe_disk_gb)

    local ram_ok="OK" disk_ok="OK"
    if [[ "$have_ram" =~ ^[0-9]+$ ]] && (( have_ram < need_ram )); then
        ram_ok="INSUFFICIENT"
    fi
    if [[ "$have_disk" =~ ^[0-9]+$ ]] && (( have_disk < need_disk )); then
        disk_ok="INSUFFICIENT"
    fi

    local msg
    msg=$(printf "Selected maps: %s

Recommended minimum (concurrent run):
  RAM   : %s GB
  Disk  : %s GB

This host has:
  RAM   : %s GB  [%s]
  Disk  : %s GB  [%s]" \
        "$map_count" "$need_ram" "$need_disk" \
        "$have_ram" "$ram_ok" "$have_disk" "$disk_ok")

    if [[ "$ram_ok" != "OK" || "$disk_ok" != "OK" ]]; then
        wt_yesno "Hardware check — below recommended" \
            "$msg

Proceed anyway?" --defaultno || return 1
    else
        wt_msgbox "Hardware check — OK" "$msg

Host meets the recommended minimum."
    fi
    return 0
}

wizard_admin_password() {
    local p1 p2
    while true; do
        wt_password "Admin password" \
            "RCON admin password (applied to every map).
This will be written to group_vars/gameservers.yml (mode 0600)." || return 1
        p1=$(<"$WT_TMP")

        wt_password "Admin password" "Repeat:" || return 1
        p2=$(<"$WT_TMP")

        if [[ "$p1" != "$p2" ]]; then
            wt_msgbox "Mismatch" "Passwords do not match. Try again."
            continue
        fi
        if [[ -z "$p1" ]]; then
            wt_msgbox "Empty" "Password cannot be empty."
            continue
        fi
        WIZ_PASS="$p1"
        return 0
    done
}

wizard_discord() {
    if wt_yesno "Discord notifications (optional)" \
        "Post lifecycle events (up/down/restart) to Discord?" --defaultno; then
        wt_input "Discord webhook URL" "Paste the full webhook URL:" "" || { WIZ_DISCORD=""; return 0; }
        WIZ_DISCORD=$(<"$WT_TMP")
    else
        WIZ_DISCORD=""
    fi
}

wizard_admins() {
    wt_input "Admin SteamIDs (optional)" \
        "17-digit SteamIDs granted in-game admin (cheat commands).
Space-separated. Leave blank to skip." "" || { WIZ_ADMINS=""; return 0; }
    WIZ_ADMINS=$(<"$WT_TMP")
}

# --- config writer -------------------------------------------------------------
write_config() {
    log "Writing $CONFIG_FILE (mode 0600)"

    {
        cat <<HEADER
---
# Generated by bootstrap.sh. Edit freely — it's just YAML.
# Re-run bootstrap.sh > Deploy any time to regenerate.

location: "$WIZ_LOC"
server_tag: "$WIZ_TAG"
server_mode: "$WIZ_MODE"
HEADER

        if [[ -n "$WIZ_DISCORD" ]]; then
            printf '\ndiscord_webhook_url: "%s"\n' "$WIZ_DISCORD"
        fi

        cat <<'COMMON'

# Lifecycle automation — defaults shown, override as desired.
enable_daily_restart: true
daily_update_hour: 4
enable_watchdog: true
watchdog_interval_minutes: 5

maps:
COMMON

        local ark_name
        for ark_name in "${WIZ_MAPS[@]}"; do
            for entry in "${MAP_CATALOG[@]}"; do
                IFS='|' read -r an display rcon_p ark_p steam_p _ <<<"$entry"
                if [[ "$an" == "$ark_name" ]]; then
                    cat <<MAP
  - map_name_ark: "$an"
    map_name: "$display"
    map_rcon_port: $rcon_p
    map_ark_port: $ark_p
    map_steam_port: $steam_p
    map_admin_password: "$WIZ_PASS"
    map_max_players: 25
    map_mods_enabled: ""
    cluster_name: "$WIZ_CLUSTER"
MAP
                    break
                fi
            done
        done

        printf '\nadmins:\n'
        if [[ -n "$WIZ_ADMINS" ]]; then
            local id
            for id in $WIZ_ADMINS; do printf '  - %s\n' "$id"; done
        else
            printf '  []\n'
        fi
    } >"$CONFIG_FILE"

    chmod 0600 "$CONFIG_FILE"
}

# --- actions -------------------------------------------------------------------
run_playbook() {
    local log_file="/tmp/ark-deploy-$(date +%Y%m%d-%H%M%S).log"
    pushd "$REPO_DIR" >/dev/null
    log "Running ansible-playbook (first deploy downloads ~45 GB of ARK content; be patient)..."
    log "Full output: $log_file"
    echo
    ansible-playbook -i "$INVENTORY_FILE" main.yml 2>&1 | tee "$log_file"
    local rc=${PIPESTATUS[0]}
    popd >/dev/null
    if (( rc == 0 )); then
        wt_msgbox "Success" \
            "Playbook completed.

Log: $log_file

Next: pick 'Status' from the main menu to see arkmanager status."
    else
        wt_msgbox "Failed (rc=$rc)" \
            "Playbook failed.

Log: $log_file"
    fi
}

do_deploy() {
    welcome_screen
    if [[ -f "$CONFIG_FILE" ]]; then
        if ! wt_yesno "Existing config" \
            "$CONFIG_FILE already exists.

Overwrite it by running the wizard?
(No = skip to Redeploy with the existing file)"; then
            do_redeploy
            return
        fi
    fi

    step "Running wizard..."
    wizard_identity || { step "Wizard cancelled."; return; }
    step "Map selection..."
    wizard_maps || { step "Wizard cancelled."; return; }
    if (( ${#WIZ_MAPS[@]} == 0 )); then
        wt_msgbox "No maps" "You must select at least one map."
        return
    fi
    step "Hardware check (${#WIZ_MAPS[@]} maps selected)..."
    check_hardware || { step "Hardware check cancelled."; return; }
    step "Admin password..."
    wizard_admin_password || { step "Wizard cancelled."; return; }
    step "Discord webhook..."
    wizard_discord
    step "Admin SteamIDs..."
    wizard_admins

    local preview
    preview=$(printf "Location : %s
Tag      : %s
Mode     : %s
Cluster  : %s
Maps     : %s
Admins   : %s
Discord  : %s" \
        "$WIZ_LOC" "$WIZ_TAG" "$WIZ_MODE" "$WIZ_CLUSTER" \
        "${WIZ_MAPS[*]}" "${WIZ_ADMINS:-none}" "${WIZ_DISCORD:+enabled}")

    if ! wt_yesno "Confirm" "$preview

Write config and run playbook?"; then
        step "Aborted before writing config."
        return
    fi

    write_config
    run_playbook
}

do_redeploy() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        wt_msgbox "Not found" "$CONFIG_FILE not found. Run 'Deploy' first."
        return
    fi
    if ! wt_yesno "Redeploy" \
        "Re-run ansible-playbook with the existing config?
($CONFIG_FILE)"; then
        return
    fi
    run_playbook
}

do_dryrun() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        wt_msgbox "Not found" "$CONFIG_FILE not found. Run 'Deploy' first."
        return
    fi
    local log_file="/tmp/ark-dryrun-$(date +%Y%m%d-%H%M%S).log"
    pushd "$REPO_DIR" >/dev/null
    log "Running ansible-playbook --check --diff..."
    echo
    ansible-playbook --check --diff -i "$INVENTORY_FILE" main.yml 2>&1 | tee "$log_file" || true
    popd >/dev/null
    wt_msgbox "Dry-run complete" \
        "ansible-playbook --check --diff finished.

Full output: $log_file"
}

do_status() {
    if ! command -v arkmanager >/dev/null 2>&1; then
        wt_msgbox "Not deployed" "arkmanager is not installed yet. Run 'Deploy' first."
        return
    fi
    local out
    out=$(su - ark -c "arkmanager status @all" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
    wt_scrollmsg "arkmanager status @all" "$out"
}

do_edit() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        cp "$EXAMPLE_CONFIG" "$CONFIG_FILE"
    fi
    "${EDITOR:-nano}" "$CONFIG_FILE"
}

do_destroy() {
    if ! wt_yesno "DESTROY — step 1/3" "\
This action will:
  - Stop every ARK server
  - Remove /etc/arkmanager/ and /etc/logrotate.d/arkmanager
  - Remove /etc/sudoers.d/ark
  - Remove /usr/local/bin/arkmanager
  - Remove the ark user's crontab
  - Delete /home/ark/ARK (game install + saves) and /home/ark/ARK-Backups
  - Delete the helper scripts in /home/ark/

This cannot be undone. Back up /home/ark/ARK-Backups first if you want your saves.

Continue?" --defaultno; then
        return
    fi

    if ! wt_yesno "DESTROY — step 2/3" "Are you absolutely sure?" --defaultno; then
        return
    fi

    wt_input "DESTROY — step 3/3" "Type DESTROY (capitals) to confirm:" "" || return
    local confirm; confirm=$(<"$WT_TMP")
    if [[ "$confirm" != "DESTROY" ]]; then
        wt_msgbox "Aborted" "Typed string did not match. Nothing was removed."
        return
    fi

    log "Stopping every map..."
    if command -v arkmanager >/dev/null 2>&1; then
        su - ark -c "arkmanager stop @all" 2>&1 | tail -20 || true
    fi

    log "Removing ark user's crontab..."
    crontab -u ark -r 2>/dev/null || true

    log "Removing arkmanager, configs, save data..."
    rm -rf /etc/arkmanager
    rm -f  /etc/logrotate.d/arkmanager
    rm -f  /etc/sudoers.d/ark
    rm -f  /usr/local/bin/arkmanager
    rm -f  /etc/cron.d/arkmanager
    rm -rf /home/ark/ARK /home/ark/ARK-Backups /home/ark/.arkmanager
    rm -f  /home/ark/ark_*.sh /home/ark/crontab.txt

    wt_msgbox "Destroyed" \
        "The cluster has been torn down.

The 'ark' system user still exists (so new deploys reuse its UID and SSH key).
To remove it entirely: userdel -r ark"
}

# --- main loop -----------------------------------------------------------------
check_prereqs

while :; do
    choice=$(main_menu)
    case "$choice" in
        deploy)   do_deploy ;;
        redeploy) do_redeploy ;;
        dryrun)   do_dryrun ;;
        status)   do_status ;;
        edit)     do_edit ;;
        destroy)  do_destroy ;;
        exit|'')  exit 0 ;;
        *)        exit 0 ;;
    esac
done
