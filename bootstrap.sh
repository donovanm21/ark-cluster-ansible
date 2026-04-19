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
#   Destroy   — stop every map and remove arkmanager state (guarded, three confirmations)
#
# Destroy really does nuke the cluster — back up saves first.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR"
CONFIG_FILE="$REPO_DIR/group_vars/gameservers.yml"
EXAMPLE_CONFIG="$REPO_DIR/group_vars/gameservers.yml.example"
INVENTORY_FILE="$REPO_DIR/inventory_remote"
EXAMPLE_INVENTORY="$REPO_DIR/inventory_remote.example"

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
# ARK engine install is ~45 GB and shared across every map. Each *running* map
# then uses ~6 GB RAM and ~12 GB additional disk for saves, mods, and backups.
BASE_RAM_GB=4
BASE_DISK_GB=55
PER_MAP_RAM_GB=6
PER_MAP_DISK_GB=12

# --- TUI chrome ----------------------------------------------------------------
WT_TITLE="ark-cluster-ansible"
WT_BACKTITLE="Deploy a production-ready ARK cluster · one host · one command"
WT_H=22
WT_W=78

# --- helpers -------------------------------------------------------------------
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
log()  { printf '\n[*] %s\n' "$*"; }
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
    apt-get update -qq
    apt-get install -y -qq "$pkg"
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
probe_cpu_cores() { nproc; }
probe_ram_gb()    { awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo; }
probe_disk_gb()   { df -BG --output=avail / | awk 'NR==2{gsub("G",""); print $1+0}'; }

host_capacity_line() {
    printf "Host capacity  —  CPU: %s cores  ·  RAM: %s GB  ·  Free disk (/): %s GB" \
        "$(probe_cpu_cores)" "$(probe_ram_gb)" "$(probe_disk_gb)"
}

required_ram_gb()  { echo $(( BASE_RAM_GB  + PER_MAP_RAM_GB  * $1 )); }
required_disk_gb() { echo $(( BASE_DISK_GB + PER_MAP_DISK_GB * $1 )); }

# --- TUI screens ---------------------------------------------------------------
welcome_screen() {
    whiptail --title "$WT_TITLE" --backtitle "$WT_BACKTITLE" \
        --msgbox "\n\
Welcome.\n\n\
This wizard will:\n\
  1. Check your host meets minimum specs for the maps you choose\n\
  2. Collect cluster identity, maps, admin password, optional Discord\n\
  3. Write group_vars/gameservers.yml (gitignored — stays local)\n\
  4. Run ansible-playbook to deploy\n\n\
$(host_capacity_line)\n\n\
You can re-run this tool any time for redeploys, status, or teardown." \
        $WT_H $WT_W
}

main_menu() {
    whiptail --title "$WT_TITLE" --backtitle "$WT_BACKTITLE" \
        --cancel-button "Exit" \
        --menu "\n$(host_capacity_line)\n\nWhat would you like to do?\n" \
        $WT_H $WT_W 7 \
        "deploy"   "Deploy a new cluster (wizard + playbook)" \
        "redeploy" "Redeploy (re-run playbook with existing config)" \
        "dryrun"   "Dry-run (--check --diff, no writes)" \
        "status"   "Status (arkmanager status @all)" \
        "edit"     "Edit group_vars/gameservers.yml" \
        "destroy"  "Destroy cluster (stop + remove everything)" \
        "exit"     "Exit" \
        3>&1 1>&2 2>&3
}

wizard_identity() {
    local loc tag mode cluster_name
    loc=$(whiptail --title "Identity (1/4)" --backtitle "$WT_BACKTITLE" \
        --inputbox "\nTwo-letter region code for the session name (US, EU, ZA, …):" \
        12 $WT_W "US" 3>&1 1>&2 2>&3) || return 1

    tag=$(whiptail --title "Identity (2/4)" --backtitle "$WT_BACKTITLE" \
        --inputbox "\nShort cluster tag shown in the Steam browser:" \
        12 $WT_W "MyCluster" 3>&1 1>&2 2>&3) || return 1

    mode=$(whiptail --title "Identity (3/4)" --backtitle "$WT_BACKTITLE" \
        --menu "\nServer mode:" 14 $WT_W 2 \
        "PvE" "Player vs Environment — cooperative, no raiding" \
        "PvP" "Player vs Player — raiding, offline raid protection" \
        3>&1 1>&2 2>&3) || return 1

    cluster_name=$(whiptail --title "Identity (4/4)" --backtitle "$WT_BACKTITLE" \
        --inputbox "\nCluster ID for cross-map tame/item transfers:" \
        12 $WT_W "${tag}_${mode}" 3>&1 1>&2 2>&3) || return 1

    printf '%s\n%s\n%s\n%s\n' "$loc" "$tag" "$mode" "$cluster_name"
}

wizard_maps() {
    local choices=()
    for entry in "${MAP_CATALOG[@]}"; do
        IFS='|' read -r ark_name display rcon_p ark_p steam_p _ <<<"$entry"
        local default="OFF"
        [[ "$ark_name" == "Ragnarok" ]] && default="ON"
        choices+=("$ark_name" "$display  (ports $ark_p / $steam_p / $rcon_p)" "$default")
    done
    whiptail --title "Maps" --backtitle "$WT_BACKTITLE" \
        --checklist "\nSelect the maps you want in your cluster.\nSPACE toggles · ENTER confirms.\n" \
        $WT_H $WT_W 12 "${choices[@]}" \
        3>&1 1>&2 2>&3
}

check_hardware() {
    local map_count="$1"
    local need_ram=$(required_ram_gb "$map_count")
    local need_disk=$(required_disk_gb "$map_count")
    local have_ram=$(probe_ram_gb)
    local have_disk=$(probe_disk_gb)

    local ram_ok="OK"
    (( have_ram < need_ram ))  && ram_ok="INSUFFICIENT (need ${need_ram})"
    local disk_ok="OK"
    (( have_disk < need_disk )) && disk_ok="INSUFFICIENT (need ${need_disk})"

    local msg
    msg=$(printf "\
Selected maps: %s\n\n\
Recommended minimum (concurrent run):\n\
  RAM   : %s GB\n\
  Disk  : %s GB\n\n\
This host has:\n\
  RAM   : %s GB  [%s]\n\
  Disk  : %s GB  [%s]" \
        "$map_count" "$need_ram" "$need_disk" \
        "$have_ram" "$ram_ok" "$have_disk" "$disk_ok")

    if [[ "$ram_ok" != "OK" ]] || [[ "$disk_ok" != "OK" ]]; then
        whiptail --title "Hardware check — below recommended" --backtitle "$WT_BACKTITLE" \
            --defaultno --yesno "$msg\n\nProceed anyway?" $WT_H $WT_W || return 1
    else
        whiptail --title "Hardware check — OK" --backtitle "$WT_BACKTITLE" \
            --msgbox "$msg\n\nHost meets the recommended minimum." $WT_H $WT_W
    fi
}

wizard_admin_password() {
    local p1 p2
    while true; do
        p1=$(whiptail --title "Admin password" --backtitle "$WT_BACKTITLE" \
            --passwordbox "\nRCON admin password (applied to every map).\nThis will be written to group_vars/gameservers.yml (mode 0600)." \
            12 $WT_W 3>&1 1>&2 2>&3) || return 1
        p2=$(whiptail --title "Admin password" --backtitle "$WT_BACKTITLE" \
            --passwordbox "\nRepeat:" 12 $WT_W 3>&1 1>&2 2>&3) || return 1
        [[ "$p1" == "$p2" ]] || { whiptail --msgbox "Passwords do not match." 10 60; continue; }
        [[ -n "$p1" ]]        || { whiptail --msgbox "Password cannot be empty." 10 60; continue; }
        printf '%s' "$p1"; return 0
    done
}

wizard_discord() {
    whiptail --title "Discord notifications (optional)" --backtitle "$WT_BACKTITLE" \
        --defaultno --yesno "\nPost lifecycle events (up/down/restart) to Discord?" \
        12 $WT_W || { printf ''; return; }
    whiptail --title "Discord webhook URL" --backtitle "$WT_BACKTITLE" \
        --inputbox "\nPaste the full webhook URL:" 12 $WT_W "" 3>&1 1>&2 2>&3
}

wizard_admins() {
    whiptail --title "Admin SteamIDs (optional)" --backtitle "$WT_BACKTITLE" \
        --inputbox "\n17-digit SteamIDs granted in-game admin (cheat commands).\nSpace-separated. Leave blank to skip.\n" \
        14 $WT_W "" 3>&1 1>&2 2>&3
}

# --- config writer -------------------------------------------------------------
write_config() {
    local location="$1" tag="$2" mode="$3" cluster_name="$4"
    local admin_pass="$5" discord="$6" admins="$7"
    shift 7
    local -a selected_maps=("$@")

    log "Writing $CONFIG_FILE (mode 0600)"

    {
        cat <<HEADER
---
# Generated by bootstrap.sh. Edit freely — it's just YAML.
# Re-run bootstrap.sh > Deploy any time to regenerate.

location: "$location"
server_tag: "$tag"
server_mode: "$mode"
HEADER

        [[ -n "$discord" ]] && printf '\ndiscord_webhook_url: "%s"\n' "$discord"

        cat <<'COMMON'

# Lifecycle automation — defaults shown, override as desired.
enable_daily_restart: true
daily_update_hour: 4
enable_watchdog: true
watchdog_interval_minutes: 5

maps:
COMMON

        for ark_name in "${selected_maps[@]}"; do
            ark_name="${ark_name//\"/}"
            for entry in "${MAP_CATALOG[@]}"; do
                IFS='|' read -r an display rcon_p ark_p steam_p _ <<<"$entry"
                if [[ "$an" == "$ark_name" ]]; then
                    cat <<MAP
  - map_name_ark: "$an"
    map_name: "$display"
    map_rcon_port: $rcon_p
    map_ark_port: $ark_p
    map_steam_port: $steam_p
    map_admin_password: "$admin_pass"
    map_max_players: 25
    map_mods_enabled: ""
    cluster_name: "$cluster_name"
MAP
                    break
                fi
            done
        done

        printf '\nadmins:\n'
        if [[ -n "$admins" ]]; then
            for id in $admins; do printf '  - %s\n' "$id"; done
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
    ansible-playbook -i "$INVENTORY_FILE" main.yml 2>&1 | tee "$log_file"
    local rc=${PIPESTATUS[0]}
    popd >/dev/null
    if (( rc == 0 )); then
        whiptail --title "Success" --msgbox \
            "Playbook completed.\n\nLog: $log_file\n\nNext: pick 'Status' from the main menu to see arkmanager status." \
            $WT_H $WT_W
    else
        whiptail --title "Failed (rc=$rc)" --msgbox \
            "Playbook failed.\nLog: $log_file" $WT_H $WT_W
    fi
}

do_deploy() {
    welcome_screen
    if [[ -f "$CONFIG_FILE" ]]; then
        whiptail --title "Existing config" --backtitle "$WT_BACKTITLE" \
            --yesno "\n$CONFIG_FILE already exists.\n\nOverwrite it by running the wizard?\n(No = skip to Redeploy with the existing file)" \
            14 $WT_W || { do_redeploy; return; }
    fi

    local id_out; id_out=$(wizard_identity) || return
    mapfile -t id <<<"$id_out"

    local maps_raw; maps_raw=$(wizard_maps) || return
    local -a selected
    eval "selected=($maps_raw)"
    (( ${#selected[@]} == 0 )) && { whiptail --msgbox "No maps selected." 10 60; return; }

    check_hardware "${#selected[@]}" || return

    local admin_pass; admin_pass=$(wizard_admin_password) || return
    local discord;    discord=$(wizard_discord)
    local admins;     admins=$(wizard_admins)

    local preview
    preview=$(printf "Location : %s\nTag      : %s\nMode     : %s\nCluster  : %s\nMaps     : %s\nAdmins   : %s\nDiscord  : %s" \
        "${id[0]}" "${id[1]}" "${id[2]}" "${id[3]}" \
        "${selected[*]}" "${admins:-none}" "${discord:+enabled}")
    whiptail --title "Confirm" --backtitle "$WT_BACKTITLE" \
        --yesno "$preview\n\nWrite config and run playbook?" $WT_H $WT_W || return

    write_config "${id[0]}" "${id[1]}" "${id[2]}" "${id[3]}" \
        "$admin_pass" "$discord" "$admins" "${selected[@]}"
    run_playbook
}

do_redeploy() {
    [[ -f "$CONFIG_FILE" ]] || { whiptail --msgbox "$CONFIG_FILE not found. Run 'Deploy' first." 10 60; return; }
    whiptail --title "Redeploy" --backtitle "$WT_BACKTITLE" \
        --yesno "\nRe-run ansible-playbook with the existing config?\n($CONFIG_FILE)" 12 $WT_W || return
    run_playbook
}

do_dryrun() {
    [[ -f "$CONFIG_FILE" ]] || { whiptail --msgbox "$CONFIG_FILE not found. Run 'Deploy' first." 10 60; return; }
    local log_file="/tmp/ark-dryrun-$(date +%Y%m%d-%H%M%S).log"
    pushd "$REPO_DIR" >/dev/null
    ansible-playbook --check --diff -i "$INVENTORY_FILE" main.yml 2>&1 | tee "$log_file" || true
    popd >/dev/null
    whiptail --title "Dry-run complete" --msgbox \
        "ansible-playbook --check --diff finished.\n\nFull output: $log_file" $WT_H $WT_W
}

do_status() {
    if ! command -v arkmanager >/dev/null 2>&1; then
        whiptail --msgbox "arkmanager is not installed yet. Run 'Deploy' first." 10 60
        return
    fi
    local out
    out=$(su - ark -c "arkmanager status @all" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
    whiptail --title "arkmanager status @all" --scrolltext --msgbox "$out" $WT_H $WT_W
}

do_edit() {
    [[ -f "$CONFIG_FILE" ]] || cp "$EXAMPLE_CONFIG" "$CONFIG_FILE"
    "${EDITOR:-nano}" "$CONFIG_FILE"
}

do_destroy() {
    whiptail --title "DESTROY — step 1/3" --backtitle "$WT_BACKTITLE" \
        --defaultno --yesno "\n\
This action will:\n\
  • Stop every ARK server\n\
  • Remove /etc/arkmanager/ and /etc/logrotate.d/arkmanager\n\
  • Remove /etc/sudoers.d/ark\n\
  • Remove /usr/local/bin/arkmanager\n\
  • Remove the ark user's crontab\n\
  • Delete /home/ark/ARK (game install + saves) and /home/ark/ARK-Backups\n\
  • Delete the helper scripts in /home/ark/\n\n\
This cannot be undone. Back up /home/ark/ARK-Backups first if you want your saves.\n\n\
Continue?" $WT_H $WT_W || return

    whiptail --title "DESTROY — step 2/3" --backtitle "$WT_BACKTITLE" \
        --defaultno --yesno "\nAre you absolutely sure?" 10 $WT_W || return

    local confirm
    confirm=$(whiptail --title "DESTROY — step 3/3" --backtitle "$WT_BACKTITLE" \
        --inputbox "\nType DESTROY (capitals) to confirm:" 10 $WT_W "" 3>&1 1>&2 2>&3) || return
    [[ "$confirm" == "DESTROY" ]] || { whiptail --msgbox "Typed string did not match. Aborting." 10 60; return; }

    log "Stopping every map..."
    command -v arkmanager >/dev/null 2>&1 && { su - ark -c "arkmanager stop @all" 2>&1 | tail -20 || true; }

    log "Removing ark user's crontab..."
    crontab -u ark -r 2>/dev/null || true

    log "Removing arkmanager + configs + save data..."
    rm -rf /etc/arkmanager
    rm -f  /etc/logrotate.d/arkmanager
    rm -f  /etc/sudoers.d/ark
    rm -f  /usr/local/bin/arkmanager
    rm -f  /etc/cron.d/arkmanager
    rm -rf /home/ark/ARK /home/ark/ARK-Backups /home/ark/.arkmanager
    rm -f  /home/ark/ark_*.sh /home/ark/crontab.txt

    whiptail --title "Destroyed" --backtitle "$WT_BACKTITLE" --msgbox \
        "The cluster has been torn down.\n\nThe 'ark' system user still exists (so new deploys reuse its SSH key and UID).\nTo remove it entirely: userdel -r ark" $WT_H $WT_W
}

# --- main loop -----------------------------------------------------------------
check_prereqs

while :; do
    case $(main_menu) in
        deploy)   do_deploy ;;
        redeploy) do_redeploy ;;
        dryrun)   do_dryrun ;;
        status)   do_status ;;
        edit)     do_edit ;;
        destroy)  do_destroy ;;
        *)        exit 0 ;;
    esac
done
