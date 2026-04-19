#!/usr/bin/env bash
# bootstrap.sh — plain CLI interface for ark-cluster-ansible.
#
# Run this on your target Linux host (the one that will run the cluster).
# No ncurses, no TUI dependency — just read/echo prompts.
#
# Main menu:
#   1) Deploy    — wizard, write config, run the playbook
#   2) Redeploy  — re-run the playbook with the existing config
#   3) Dry-run   — ansible-playbook --check --diff (no writes)
#   4) Status    — arkmanager status @all
#   5) Edit      — open the config in $EDITOR
#   6) Destroy   — stop everything and remove arkmanager state
#   7) Exit

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR"
CONFIG_FILE="$REPO_DIR/group_vars/gameservers.yml"
EXAMPLE_CONFIG="$REPO_DIR/group_vars/gameservers.yml.example"
INVENTORY_FILE="$REPO_DIR/inventory_remote"
EXAMPLE_INVENTORY="$REPO_DIR/inventory_remote.example"

# --- supported maps -----------------------------------------------------------
# ark_name | display_name | rcon_port | ark_port | steam_port | disk_gb
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

# --- hardware baseline --------------------------------------------------------
BASE_RAM_GB=4
BASE_DISK_GB=55
PER_MAP_RAM_GB=6
PER_MAP_DISK_GB=12

# --- styling ------------------------------------------------------------------
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
    BOLD=$(tput bold); DIM=$(tput dim)
    RED=$(tput setaf 1); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4); CYAN=$(tput setaf 6); RESET=$(tput sgr0)
else
    BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; RESET=""
fi

RULE="============================================================================"

hr()      { printf '%s\n' "$RULE"; }
title()   { echo; printf '%s%s%s\n' "$BOLD" "$1" "$RESET"; hr; }
section() { echo; printf '%s--- %s ---%s\n' "$BOLD" "$1" "$RESET"; }
ok()      { printf '  %s[ok]%s   %s\n' "$GREEN" "$RESET" "$1"; }
info()    { printf '  %s[..]%s   %s\n' "$CYAN" "$RESET" "$1"; }
warn()    { printf '  %s[!!]%s   %s\n' "$YELLOW" "$RESET" "$1"; }
fail()    { printf '  %s[x]%s    %s\n' "$RED" "$RESET" "$1" >&2; }
die()     { fail "$1"; exit 1; }

# --- prompts ------------------------------------------------------------------
# ask VAR "Prompt text" ["default"]
ask() {
    local __var=$1 __prompt=$2 __default=${3:-} __input=""
    if [[ -n "$__default" ]]; then
        read -r -p "  $__prompt [$__default]: " __input || true
        __input=${__input:-$__default}
    else
        read -r -p "  $__prompt: " __input || true
    fi
    printf -v "$__var" '%s' "$__input"
}

# ask_password VAR "Prompt"
ask_password() {
    local __var=$1 __prompt=$2 __p1="" __p2=""
    while true; do
        read -r -s -p "  $__prompt: " __p1 || true; echo
        if [[ -z "$__p1" ]]; then warn "Password cannot be empty."; continue; fi
        read -r -s -p "  Repeat: " __p2 || true; echo
        if [[ "$__p1" != "$__p2" ]]; then warn "Passwords do not match."; continue; fi
        printf -v "$__var" '%s' "$__p1"
        return 0
    done
}

# ask_yn "Prompt" ["Y"|"N"]  — returns 0 for yes, 1 for no
ask_yn() {
    local prompt=$1 default=${2:-N} suffix="" choice=""
    if [[ "$default" == "Y" ]]; then suffix="[Y/n]"; else suffix="[y/N]"; fi
    read -r -p "  $prompt $suffix " choice || true
    choice=${choice:-$default}
    case "${choice,,}" in y|yes) return 0 ;; *) return 1 ;; esac
}

press_enter() {
    read -r -p "  Press Enter to continue... " _ || true
}

# --- prerequisites ------------------------------------------------------------
require_root() {
    if [[ $EUID -ne 0 ]]; then
        die "Run as root (or via sudo). The playbook writes to /etc/ and /home/."
    fi
}

ensure_pkg() {
    local pkg=$1 cmd=$2
    if command -v "$cmd" >/dev/null 2>&1; then return 0; fi
    warn "$cmd is required but not installed."
    if ! ask_yn "Install $pkg via apt now?" Y; then
        die "Cannot continue without $pkg."
    fi
    info "Running apt-get update..."
    apt-get update
    info "Installing $pkg..."
    apt-get install -y "$pkg"
}

check_prereqs() {
    require_root
    ensure_pkg ansible-core ansible-playbook
    if [[ ! -f "$INVENTORY_FILE" ]]; then
        cp "$EXAMPLE_INVENTORY" "$INVENTORY_FILE"
        ok "Created inventory_remote from example."
    fi
}

# --- host probe ---------------------------------------------------------------
probe_cpu_cores() { nproc 2>/dev/null || echo "?"; }
probe_ram_gb() {
    if [[ -r /proc/meminfo ]]; then
        awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo
    else
        echo "?"
    fi
}
probe_disk_gb() {
    df -BG --output=avail / 2>/dev/null \
        | awk 'NR==2{gsub("G",""); print $1+0}' \
        || echo "?"
}

host_capacity_line() {
    printf "CPU: %s cores  |  RAM: %s GB  |  Free disk (/): %s GB" \
        "$(probe_cpu_cores)" "$(probe_ram_gb)" "$(probe_disk_gb)"
}

required_ram_gb()  { echo $(( BASE_RAM_GB  + PER_MAP_RAM_GB  * $1 )); }
required_disk_gb() { echo $(( BASE_DISK_GB + PER_MAP_DISK_GB * $1 )); }

# --- wizard state -------------------------------------------------------------
WIZ_LOC=""
WIZ_TAG=""
WIZ_MODE=""
WIZ_CLUSTER=""
declare -a WIZ_MAPS=()
WIZ_PASS=""
WIZ_DISCORD=""
WIZ_ADMINS=""

# --- wizard screens -----------------------------------------------------------
wizard_identity() {
    section "Cluster identity"
    ask WIZ_LOC "Region code (2 letters, e.g. US, EU, ZA)" "US"

    ask WIZ_TAG "Cluster tag (short name shown in Steam browser)" "MyCluster"

    while true; do
        ask WIZ_MODE "Server mode (PvE or PvP)" "PvE"
        WIZ_MODE=${WIZ_MODE^^}   # uppercase
        # normalise: pve -> PvE, pvp -> PvP
        case "$WIZ_MODE" in
            PVE) WIZ_MODE="PvE"; break ;;
            PVP) WIZ_MODE="PvP"; break ;;
            *) warn "Enter PvE or PvP." ;;
        esac
    done

    ask WIZ_CLUSTER "Cluster ID for cross-map tame/item transfers" "${WIZ_TAG}_${WIZ_MODE}"
}

wizard_maps() {
    section "Map selection"
    echo "  Available maps (ports shown as game / query / RCON):"
    echo
    local i=1 entry ark_name display rcon_p ark_p steam_p
    for entry in "${MAP_CATALOG[@]}"; do
        IFS='|' read -r ark_name display rcon_p ark_p steam_p _ <<<"$entry"
        printf "   %s%2d)%s  %-18s  %5s / %5s / %5s\n" \
            "$BOLD" "$i" "$RESET" "$display" "$ark_p" "$steam_p" "$rcon_p"
        i=$((i+1))
    done
    echo
    echo "  Enter map numbers separated by spaces (e.g. '1 2 3'), or 'all'."

    while true; do
        local input=""
        ask input "Maps" "1"
        WIZ_MAPS=()

        if [[ "$input" == "all" ]]; then
            for entry in "${MAP_CATALOG[@]}"; do
                IFS='|' read -r ark_name _ _ _ _ _ <<<"$entry"
                WIZ_MAPS+=("$ark_name")
            done
            break
        fi

        local n bad=0 total=${#MAP_CATALOG[@]}
        for n in $input; do
            if ! [[ "$n" =~ ^[0-9]+$ ]] || (( n < 1 || n > total )); then
                warn "Invalid map number: '$n' (valid: 1-$total)"
                bad=1
                break
            fi
            IFS='|' read -r ark_name _ _ _ _ _ <<<"${MAP_CATALOG[$((n-1))]}"
            WIZ_MAPS+=("$ark_name")
        done

        if (( bad == 0 )) && (( ${#WIZ_MAPS[@]} > 0 )); then
            break
        fi
        if (( ${#WIZ_MAPS[@]} == 0 )); then
            warn "Select at least one map."
        fi
    done

    echo
    ok "Selected ${#WIZ_MAPS[@]} map(s): ${WIZ_MAPS[*]}"
}

check_hardware() {
    section "Hardware check"
    local map_count=${#WIZ_MAPS[@]}
    local need_ram need_disk have_ram have_disk
    need_ram=$(required_ram_gb "$map_count")
    need_disk=$(required_disk_gb "$map_count")
    have_ram=$(probe_ram_gb)
    have_disk=$(probe_disk_gb)

    printf "  Selected maps:  %d\n" "$map_count"
    printf "\n  %-30s %10s %10s   %s\n" "" "needed" "host" "status"

    local ram_status disk_status fail_any=0
    if [[ "$have_ram" =~ ^[0-9]+$ ]] && (( have_ram < need_ram )); then
        ram_status="${RED}INSUFFICIENT${RESET}"; fail_any=1
    else
        ram_status="${GREEN}OK${RESET}"
    fi
    if [[ "$have_disk" =~ ^[0-9]+$ ]] && (( have_disk < need_disk )); then
        disk_status="${RED}INSUFFICIENT${RESET}"; fail_any=1
    else
        disk_status="${GREEN}OK${RESET}"
    fi

    printf "  %-30s %7s GB %7s GB   %b\n" "RAM"  "$need_ram"  "$have_ram"  "$ram_status"
    printf "  %-30s %7s GB %7s GB   %b\n" "Disk" "$need_disk" "$have_disk" "$disk_status"
    echo

    if (( fail_any )); then
        warn "Host is below the recommended minimum for $map_count map(s)."
        if ! ask_yn "Proceed anyway?" N; then
            return 1
        fi
    else
        ok "Host meets the recommended minimum."
    fi
    return 0
}

wizard_admin_password() {
    section "Admin password"
    echo "  This password is set as ServerAdminPassword on every map."
    echo "  It lives in $CONFIG_FILE (mode 0600)."
    ask_password WIZ_PASS "RCON admin password"
}

wizard_discord() {
    section "Discord notifications (optional)"
    if ask_yn "Post lifecycle events (up/down/restart) to Discord?" N; then
        ask WIZ_DISCORD "Webhook URL" ""
    else
        WIZ_DISCORD=""
    fi
}

wizard_admins() {
    section "Admin SteamIDs (optional)"
    echo "  Players granted in-game admin (cheat commands). 17-digit SteamIDs,"
    echo "  space-separated. Leave blank to skip."
    ask WIZ_ADMINS "SteamIDs" ""
}

confirm_config() {
    section "Review"
    printf "  Region:   %s\n"    "$WIZ_LOC"
    printf "  Tag:      %s\n"    "$WIZ_TAG"
    printf "  Mode:     %s\n"    "$WIZ_MODE"
    printf "  Cluster:  %s\n"    "$WIZ_CLUSTER"
    printf "  Maps:     %s\n"    "${WIZ_MAPS[*]}"
    printf "  Admins:   %s\n"    "${WIZ_ADMINS:-(none)}"
    printf "  Discord:  %s\n"    "${WIZ_DISCORD:+enabled}"
    [[ -z "$WIZ_DISCORD" ]] && printf "  Discord:  disabled\n"
    echo
    ask_yn "Write config and run the playbook?" Y
}

# --- config writer ------------------------------------------------------------
write_config() {
    info "Writing $CONFIG_FILE (mode 0600)"

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

        local ark_name entry an display rcon_p ark_p steam_p
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
    ok "Wrote $CONFIG_FILE"
}

# --- actions ------------------------------------------------------------------
run_playbook() {
    local log_file; log_file="/tmp/ark-deploy-$(date +%Y%m%d-%H%M%S).log"
    title "Running ansible-playbook"
    info "First deploy downloads ~45 GB of ARK content; be patient."
    info "Full output: $log_file"
    echo
    ansible-playbook -i "$INVENTORY_FILE" main.yml 2>&1 | tee "$log_file"
    local rc=${PIPESTATUS[0]}
    echo
    if (( rc == 0 )); then
        ok "Playbook completed successfully."
        info "Log: $log_file"
    else
        fail "Playbook failed with exit code $rc."
        info "Log: $log_file"
    fi
}

do_deploy() {
    title "Deploy ARK cluster"
    printf "  %s\n" "$(host_capacity_line)"

    if [[ -f "$CONFIG_FILE" ]]; then
        echo
        warn "Existing config found at $CONFIG_FILE"
        if ! ask_yn "Overwrite it by running the wizard?" N; then
            info "Skipping wizard — running Redeploy with existing config."
            do_redeploy
            return
        fi
    fi

    wizard_identity        || { warn "Aborted."; return; }
    wizard_maps            || { warn "Aborted."; return; }
    check_hardware         || { warn "Aborted."; return; }
    wizard_admin_password  || { warn "Aborted."; return; }
    wizard_discord
    wizard_admins

    if ! confirm_config; then
        warn "Aborted before writing config."
        return
    fi

    write_config
    run_playbook
}

do_redeploy() {
    title "Redeploy"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        fail "$CONFIG_FILE not found. Run Deploy first."
        return
    fi
    info "Using $CONFIG_FILE"
    if ! ask_yn "Re-run the playbook with this config?" Y; then
        return
    fi
    run_playbook
}

do_dryrun() {
    title "Dry-run (--check --diff)"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        fail "$CONFIG_FILE not found. Run Deploy first."
        return
    fi
    local log_file; log_file="/tmp/ark-dryrun-$(date +%Y%m%d-%H%M%S).log"
    info "No changes will be applied. Full output: $log_file"
    echo
    ansible-playbook --check --diff -i "$INVENTORY_FILE" main.yml 2>&1 | tee "$log_file" || true
    echo
    info "Dry-run finished. Full output: $log_file"
}

do_status() {
    title "Cluster status"
    if ! command -v arkmanager >/dev/null 2>&1; then
        warn "arkmanager is not installed yet — run Deploy first."
        return
    fi
    # Strip ANSI color so copy/paste is clean.
    su - ark -c "arkmanager status @all" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
}

do_edit() {
    title "Edit $CONFIG_FILE"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        cp "$EXAMPLE_CONFIG" "$CONFIG_FILE"
        ok "Seeded from $EXAMPLE_CONFIG"
    fi
    "${EDITOR:-nano}" "$CONFIG_FILE"
}

do_destroy() {
    title "DESTROY cluster"
    cat <<'DWARN'
  This will:
    - Stop every ARK server
    - Remove /etc/arkmanager/ and /etc/logrotate.d/arkmanager
    - Remove /etc/sudoers.d/ark
    - Remove /usr/local/bin/arkmanager and /etc/cron.d/arkmanager
    - Remove the ark user's crontab
    - Delete /home/ark/ARK (game install + saves) and /home/ark/ARK-Backups
    - Delete helper scripts in /home/ark/

  Back up /home/ark/ARK-Backups first if you want to keep your saves.
  This cannot be undone.
DWARN
    echo
    if ! ask_yn "Step 1 of 3: continue?" N; then return; fi
    if ! ask_yn "Step 2 of 3: are you absolutely sure?" N; then return; fi

    local confirm=""
    ask confirm "Step 3 of 3: type DESTROY (capitals) to confirm"
    if [[ "$confirm" != "DESTROY" ]]; then
        warn "Typed string did not match. Nothing removed."
        return
    fi

    info "Stopping every map..."
    if command -v arkmanager >/dev/null 2>&1; then
        su - ark -c "arkmanager stop @all" 2>&1 | tail -20 || true
    fi

    info "Removing ark user's crontab..."
    crontab -u ark -r 2>/dev/null || true

    info "Removing arkmanager, configs, save data..."
    rm -rf /etc/arkmanager
    rm -f  /etc/logrotate.d/arkmanager
    rm -f  /etc/sudoers.d/ark
    rm -f  /usr/local/bin/arkmanager
    rm -f  /etc/cron.d/arkmanager
    rm -rf /home/ark/ARK /home/ark/ARK-Backups /home/ark/.arkmanager
    rm -f  /home/ark/ark_*.sh /home/ark/crontab.txt

    echo
    ok "Cluster torn down."
    info "The 'ark' system user still exists. Remove with: userdel -r ark"
}

# --- main menu ----------------------------------------------------------------
main_menu() {
    clear 2>/dev/null || echo
    hr
    printf '%s  ark-cluster-ansible%s  —  interactive deploy\n' "$BOLD" "$RESET"
    hr
    printf '  %s\n' "$(host_capacity_line)"
    echo
    cat <<'MENU'
    1)  Deploy       — run the wizard, write config, deploy the cluster
    2)  Redeploy     — re-run the playbook with the existing config
    3)  Dry-run      — show what would change without applying
    4)  Status       — arkmanager status @all
    5)  Edit config  — open gameservers.yml in $EDITOR
    6)  Destroy      — stop everything and remove arkmanager state
    7)  Exit
MENU
    echo
    local choice=""
    read -r -p "  Choice [1]: " choice || true
    choice=${choice:-1}
    case "$choice" in
        1|d|deploy)   do_deploy;   press_enter ;;
        2|r|redeploy) do_redeploy; press_enter ;;
        3|dryrun)     do_dryrun;   press_enter ;;
        4|s|status)   do_status;   press_enter ;;
        5|e|edit)     do_edit ;;
        6|destroy)    do_destroy;  press_enter ;;
        7|q|exit|quit) exit 0 ;;
        *) warn "Unrecognised choice: $choice"; press_enter ;;
    esac
}

# --- entry --------------------------------------------------------------------
trap 'echo; info "Interrupted. Exiting."; exit 130' INT

check_prereqs

while :; do
    main_menu
done
