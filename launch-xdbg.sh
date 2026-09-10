#!/usr/bin/env bash

# Run a sibling x32dbg/x64dbg through the Proton instance used by a Steam game.
# Keep this script outside Flatpak: the game and debugger must share wineserver.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
uid=$(id -u)

appid="${XDBG_APPID:-${SteamAppId:-${SteamGameId:-}}}"
debugger_override=""
proton_override="${XDBG_PROTON_PATH:-}"
steam_root_override="${XDBG_STEAM_ROOT:-}"
start_game=0
check_only=0
wait_seconds=90
log_file=""
debugger_args=()

usage() {
    cat <<'EOF'
Usage: ./launch-xdbg.sh --appid APPID [options] [-- XDBG_ARGS...]

The game should be running in native Steam. The script detects its Proton
prefix and launches the sibling x32dbg.exe or x64dbg.exe with runinprefix.
The AppID selects the exact compatdata/prefix and wineserver to share.
If --appid is omitted, installed Steam apps are listed for interactive choice.

Options:
  --appid APPID       Steam AppID (also the first positional argument)
  --debugger FILE     Sibling x32dbg.exe or x64dbg.exe (auto-detected)
  --proton PATH       Proton directory or proton script
  --steam-root PATH   Alternate Steam root
  --start-game        Start the AppID with Steam when it is not running
  --wait SECONDS      Wait for --start-game (default: 90, max: 600)
  --log FILE          Append launcher and Proton output to FILE
  --check             Inspect only; do not launch xdbg
  -h, --help          Show this help

Examples:
  ./launch-xdbg.sh --appid 123456
  ./launch-xdbg.sh 123456 --debugger x32dbg.exe
  ./launch-xdbg.sh --appid 123456 --debugger x64dbg.exe --start-game

Find an AppID in the Steam Store URL (/app/<id>/) or in
steamapps/appmanifest_<id>.acf.

Arguments after -- are passed unchanged to xdbg. Match the debugger bitness
to the Windows process (32-bit game -> x32dbg.exe, 64-bit game -> x64dbg.exe).
EOF
}

die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
say()  { printf '%s\n' "$*"; }

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
norm() { local v=${1:-}; v=${v%/}; printf '%s' "$v"; }

env_value() {
    local blob=$1 key=$2
    awk -F= -v k="$key" '$1 == k { print substr($0, index($0, "=") + 1); exit }' <<<"$blob"
}

proc_env() { cat -- "$1" 2>/dev/null | tr '\0' '\n' || true; }
proc_cmd() { cat -- "$1" 2>/dev/null | tr '\0' ' ' || true; }

proton_from_cmd() {
    local cmd=$1
    if [[ "$cmd" =~ (/.*/proton)[[:space:]]+(waitforexitandrun|runinprefix|run)([[:space:]]|$) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    fi
}

resolve_proton() {
    local p=$1
    [[ -d "$p" && -f "$p/proton" ]] && p="$p/proton"
    [[ -f "$p" ]] || return 1
    printf '%s' "$p"
}

steam_roots=()
add_root() {
    local v=${1:-} r
    [[ -n "$v" && -d "$v" ]] || return 0
    v=$(norm "$v")
    for r in "${steam_roots[@]}"; do [[ "$r" == "$v" ]] && return 0; done
    steam_roots+=("$v")
}

discover_roots() {
    steam_roots=()
    add_root "$steam_root_override"
    add_root "${STEAM_COMPAT_CLIENT_INSTALL_PATH:-}"
    add_root "${HOME:-}/.local/share/Steam"
    add_root "${HOME:-}/.steam/steam"
    add_root "${HOME:-}/.var/app/com.valvesoftware.Steam/data/Steam"

    local i=0 root line path
    while (( i < ${#steam_roots[@]} )); do
        root=${steam_roots[i++]}
        [[ -r "$root/steamapps/libraryfolders.vdf" ]] || continue
        while IFS= read -r line; do
            [[ "$line" =~ \"path\"[[:space:]]+\"([^\"]+)\" ]] || continue
            path=${BASH_REMATCH[1]}
            path=${path//\\\\/\\}
            path=${path//\\\"/\"}
            add_root "$path"
        done < "$root/steamapps/libraryfolders.vdf"
    done
}

installed_ids=() installed_names=()
collect_installed_apps() {
    installed_ids=() installed_names=()
    local -A seen=()
    local root manifest id name
    for root in "${steam_roots[@]}"; do
        for manifest in "$root"/steamapps/appmanifest_*.acf; do
            [[ -f "$manifest" ]] || continue
            id=${manifest##*/appmanifest_}; id=${id%.acf}
            is_uint "$id" || continue
            [[ ${seen[$id]+yes} ]] && continue
            name=$(awk -F'"' '$2 == "name" { print $4; exit }' "$manifest")
            [[ -n "$name" ]] || name="(unnamed app)"
            case "$name" in
                Proton*|"Steam Linux Runtime"*|"Steamworks Common Redistributables") continue ;;
            esac
            seen["$id"]=1
            installed_ids+=("$id") installed_names+=("$name")
        done
    done
}

choose_appid() {
    collect_installed_apps
    local count=${#installed_ids[@]} i choice
    (( count > 0 )) || die "No installed Steam apps found; pass --appid APPID"
    if (( count == 1 )); then
        appid=${installed_ids[0]}
        say "Selected ${installed_names[0]} (AppID $appid)."
        return
    fi

    say "Installed Steam apps:"
    for ((i=0; i<count; i++)); do
        printf '  %2d) %s (AppID %s)\n' "$((i + 1))" "${installed_names[i]}" "${installed_ids[i]}"
    done
    [[ -t 0 ]] || die "Multiple apps found; pass --appid APPID in non-interactive use"
    while :; do
        read -r -p "Choose a game [1-$count, 0=cancel]: " choice || die "No selection made"
        [[ "$choice" == 0 ]] && exit 0
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
            appid=${installed_ids[choice - 1]}
            say "Selected ${installed_names[choice - 1]} (AppID $appid)."
            return
        fi
        warn "Choose a number from 1 to $count, or 0 to cancel."
    done
}

game_pid="" game_compat="" game_prefix="" game_steam_root="" game_proton=""
game_container="" game_display="" game_wayland="" game_xauth=""
game_runtime="" game_dbus="" game_session=""

scan_game() {
    game_pid="" game_compat="" game_prefix="" game_steam_root="" game_proton=""
    game_container="" game_display="" game_wayland="" game_xauth=""
    game_runtime="" game_dbus="" game_session=""

    local best=-1 file pid owner blob compat cmd comm score prefix root proton
    for file in /proc/[0-9]*/environ; do
        [[ -r "$file" ]] || continue
        pid=${file#/proc/}; pid=${pid%/environ}
        [[ "$pid" == "$$" ]] && continue
        owner=$(stat -c '%u' "/proc/$pid" 2>/dev/null || printf '%s' -1)
        [[ "$owner" == "$uid" ]] || continue

        blob=$(proc_env "$file")
        compat=$(norm "$(env_value "$blob" STEAM_COMPAT_DATA_PATH)")
        case "$compat" in */"$appid") ;; *) continue ;; esac

        cmd=$(proc_cmd "/proc/$pid/cmdline")
        comm=$(cat -- "/proc/$pid/comm" 2>/dev/null || true)
        [[ "$comm" == wineserver* ]] && continue
        score=0
        [[ "$cmd" == *"SteamLaunch AppId=$appid"* ]] && score=$((score + 10))
        [[ "$cmd" =~ /proton[[:space:]] ]] && score=$((score + 5))
        score=$((score + 2))
        [[ "$comm" == reaper ]] && score=$((score + 2))
        (( score > best )) || continue

        prefix=$(norm "$(env_value "$blob" WINEPREFIX)")
        [[ -n "$prefix" ]] || prefix="$compat/pfx"
        root=$(env_value "$blob" STEAM_COMPAT_CLIENT_INSTALL_PATH)
        [[ -n "$root" ]] || root=${compat%"/steamapps/compatdata/$appid"}
        proton=$(proton_from_cmd "$cmd" || true)
        if [[ -z "$proton" ]]; then
            proton=$(env_value "$blob" PROTON_PATH)
            [[ -d "$proton" ]] && proton="$proton/proton"
        fi

        best=$score
        game_pid=$pid game_compat=$compat game_prefix=$prefix
        game_steam_root=$(norm "$root") game_proton=$proton
        game_container=$(env_value "$blob" container)
        game_display=$(env_value "$blob" DISPLAY)
        game_wayland=$(env_value "$blob" WAYLAND_DISPLAY)
        game_xauth=$(env_value "$blob" XAUTHORITY)
        game_runtime=$(env_value "$blob" XDG_RUNTIME_DIR)
        game_dbus=$(env_value "$blob" DBUS_SESSION_BUS_ADDRESS)
        game_session=$(env_value "$blob" XDG_SESSION_TYPE)
    done
}

compat_path="" prefix_path="" steam_root=""
locate_prefix() {
    compat_path="" prefix_path="" steam_root=""
    if [[ -n "$game_compat" && -d "$game_compat" ]]; then
        compat_path=$game_compat
        prefix_path=${game_prefix:-$game_compat/pfx}
        steam_root=${game_steam_root:-${game_compat%"/steamapps/compatdata/$appid"}}
    else
        local root candidate
        for root in "${steam_roots[@]}"; do
            candidate="$root/steamapps/compatdata/$appid"
            [[ -d "$candidate" ]] || continue
            compat_path=$candidate prefix_path="$candidate/pfx" steam_root=$root
            break
        done
    fi
    [[ -n "$compat_path" ]] || return 1
    compat_path=$(norm "$compat_path") prefix_path=$(norm "$prefix_path")
    steam_root=$(norm "$steam_root")
}

config_proton() {
    local f="$compat_path/config_info" hint root
    [[ -r "$f" ]] || return 0
    hint=$(sed -n '2p' "$f" 2>/dev/null || true)
    [[ "$hint" == */files/share/fonts/* ]] || return 0
    root=${hint%%/files/share/fonts/*}
    printf '%s/proton' "$root"
}

gui_display="${DISPLAY:-}" gui_wayland="${WAYLAND_DISPLAY:-}" gui_xauth="${XAUTHORITY:-}"
gui_runtime="${XDG_RUNTIME_DIR:-}" gui_dbus="${DBUS_SESSION_BUS_ADDRESS:-}"
gui_session="${XDG_SESSION_TYPE:-}"

fill_gui() {
    local blob=$1 v
    [[ -n "$gui_display" ]] || { v=$(env_value "$blob" DISPLAY); [[ -z "$v" ]] || gui_display=$v; }
    [[ -n "$gui_wayland" ]] || { v=$(env_value "$blob" WAYLAND_DISPLAY); [[ -z "$v" ]] || gui_wayland=$v; }
    if [[ -z "$gui_xauth" || ! -e "$gui_xauth" ]]; then
        v=$(env_value "$blob" XAUTHORITY)
        [[ -z "$v" || ! -e "$v" ]] || gui_xauth=$v
    fi
    [[ -n "$gui_runtime" ]] || { v=$(env_value "$blob" XDG_RUNTIME_DIR); [[ -z "$v" ]] || gui_runtime=$v; }
    [[ -n "$gui_dbus" ]] || { v=$(env_value "$blob" DBUS_SESSION_BUS_ADDRESS); [[ -z "$v" ]] || gui_dbus=$v; }
    [[ -n "$gui_session" ]] || { v=$(env_value "$blob" XDG_SESSION_TYPE); [[ -z "$v" ]] || gui_session=$v; }
}

recover_gui() {
    local file pid comm blob owner
    [[ -n "$game_pid" && -r "/proc/$game_pid/environ" ]] && fill_gui "$(proc_env "/proc/$game_pid/environ")"
    for file in /proc/[0-9]*/environ; do
        [[ -r "$file" ]] || continue
        pid=${file#/proc/}; pid=${pid%/environ}
        owner=$(stat -c '%u' "/proc/$pid" 2>/dev/null || printf '%s' -1)
        [[ "$owner" == "$uid" ]] || continue
        comm=$(cat -- "/proc/$pid/comm" 2>/dev/null || true)
        case "$comm" in steam|steamwebhelper|plasmashell|gamescope|kwin_wayland|startplasma-*|Xwayland) ;; *) continue ;; esac
        blob=$(proc_env "$file")
        fill_gui "$blob"
        [[ -n "$gui_display" || -n "$gui_wayland" ]] && \
            [[ -n "$gui_xauth" || -z "$gui_display" ]] && break
    done
}

count_wineservers() {
    local wanted=$(norm "$1") n=0 file pid comm blob prefix
    for file in /proc/[0-9]*/environ; do
        [[ -r "$file" ]] || continue
        pid=${file#/proc/}; pid=${pid%/environ}
        comm=$(cat -- "/proc/$pid/comm" 2>/dev/null || true)
        [[ "$comm" == wineserver* ]] || continue
        blob=$(proc_env "$file")
        prefix=$(norm "$(env_value "$blob" WINEPREFIX)")
        [[ -n "$prefix" && "$prefix" == "$wanted" ]] || continue
        n=$((n + 1))
    done
    printf '%s' "$n"
}

find_debugger() {
    local p name candidates=()
    if [[ -n "$debugger_override" ]]; then
        p=$debugger_override
        [[ "$p" == /* ]] || p="$SCRIPT_DIR/$p"
        printf '%s' "$p"
        return
    fi
    for name in x32dbg.exe x64dbg.exe; do
        [[ -f "$SCRIPT_DIR/$name" ]] && candidates+=("$SCRIPT_DIR/$name")
    done
    case ${#candidates[@]} in
        1) printf '%s' "${candidates[0]}" ;;
        0) die "No x32dbg.exe or x64dbg.exe found beside the script" ;;
        *) die "Both debuggers were found; use --debugger x32dbg.exe or x64dbg.exe" ;;
    esac
}

while (($#)); do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --appid) (($# >= 2)) || die "--appid needs a value"; appid=$2; shift 2 ;;
        --appid=*) appid=${1#*=}; shift ;;
        --debugger) (($# >= 2)) || die "--debugger needs a value"; debugger_override=$2; shift 2 ;;
        --debugger=*) debugger_override=${1#*=}; shift ;;
        --proton|--proton-path) (($# >= 2)) || die "$1 needs a value"; proton_override=$2; shift 2 ;;
        --proton=*|--proton-path=*) proton_override=${1#*=}; shift ;;
        --steam-root) (($# >= 2)) || die "--steam-root needs a value"; steam_root_override=$2; shift 2 ;;
        --steam-root=*) steam_root_override=${1#*=}; shift ;;
        --start-game) start_game=1; shift ;;
        --wait) (($# >= 2)) || die "--wait needs a number"; wait_seconds=$2; shift 2 ;;
        --wait=*) wait_seconds=${1#*=}; shift ;;
        --log) (($# >= 2)) || die "--log needs a file"; log_file=$2; shift 2 ;;
        --log=*) log_file=${1#*=}; shift ;;
        --check) check_only=1; shift ;;
        --) shift; debugger_args=("$@"); break ;;
        -*) die "Unknown option: $1 (put xdbg arguments after --)" ;;
        *) [[ -z "$appid" ]] || die "Unexpected argument: $1"; appid=$1; shift ;;
    esac
done

is_uint "$wait_seconds" || die "--wait must be an integer"
(( wait_seconds <= 600 )) || die "--wait cannot exceed 600 seconds"

debugger_path=$(find_debugger)
[[ -f "$debugger_path" ]] || die "Debugger not found: $debugger_path"
debugger_dir=$(cd -- "$(dirname -- "$debugger_path")" && pwd -P) || die "Cannot access debugger directory"

if [[ -n "$log_file" ]]; then
    mkdir -p "$(dirname -- "$log_file")"
    exec > >(tee -a "$log_file") 2>&1
fi

discover_roots
if [[ -z "$appid" ]]; then
    choose_appid
fi
[[ -n "$appid" ]] || die "Set --appid APPID"
is_uint "$appid" || die "AppID must be numeric: $appid"
scan_game
if [[ -z "$game_pid" && "$start_game" == 1 ]]; then
    recover_gui
    steam_cmd=$(command -v steam || true)
    [[ -n "$steam_cmd" ]] || die "steam command not found for --start-game"
    [[ -n "$gui_display" || -n "$gui_wayland" ]] || die "No graphical session found"
    say "Starting Steam AppID $appid..."
    "$steam_cmd" -applaunch "$appid" >/dev/null 2>&1 &
    for (( waited=1; waited<=wait_seconds; waited++ )); do
        sleep 1
        scan_game
        [[ -n "$game_pid" ]] && break
        (( waited % 5 == 0 )) && say "Waiting for the game ($waited/$wait_seconds s)..."
    done
fi

discover_roots
scan_game
locate_prefix || true
recover_gui

say "Debugger: $debugger_path"
say "AppID: $appid"
[[ -n "$game_pid" ]] && say "Detected Wine process: Linux PID $game_pid" || say "Game process: not found"
[[ -n "$compat_path" ]] && say "Compatdata: $compat_path"
[[ -n "$prefix_path" ]] && say "WINEPREFIX: $prefix_path"
[[ -n "$steam_root" ]] && say "Steam root: $steam_root"
[[ -n "$game_proton" ]] && say "Detected Proton: $game_proton"
[[ -n "$game_container" ]] && say "Container: $game_container"
say "DISPLAY: ${gui_display:-<empty>}"
say "WAYLAND_DISPLAY: ${gui_wayland:-<empty>}"
say "XDG_RUNTIME_DIR: ${gui_runtime:-<empty>}"

if (( check_only )); then
    [[ -n "$game_pid" ]] && say "Check: game is running." || say "Check: game is not running."
    [[ -n "$compat_path" ]] && say "Check: compatdata found." || warn "No compatdata found; install the game in Steam."
    exit 0
fi

[[ -n "$game_pid" ]] || die "Game is not running; launch it in Steam or use --start-game"
[[ -n "$compat_path" && -d "$compat_path" ]] || die "Compatdata not found for AppID $appid"
[[ -d "$prefix_path" ]] || die "Wine prefix not found: $prefix_path"

[[ -n "$proton_override" ]] || proton_override=$game_proton
[[ -n "$proton_override" ]] || proton_override=$(config_proton || true)
[[ -n "$proton_override" ]] || die "Cannot determine Proton; use --proton /path/to/Proton"
proton_script=$(resolve_proton "$proton_override") || die "Proton script not found: $proton_override"

if [[ "$steam_root" == *"/.var/app/com.valvesoftware.Steam"* ]]; then
    die "Steam Flatpak isolates wineserver; use native Steam for a shared session"
fi
[[ -n "$gui_display" || -n "$gui_wayland" ]] || die "DISPLAY/WAYLAND_DISPLAY not found"
if [[ -n "$gui_display" && -n "$gui_xauth" && ! -e "$gui_xauth" ]]; then
    warn "XAUTHORITY does not exist: $gui_xauth"
fi

export WINEPREFIX="$prefix_path" STEAM_COMPAT_DATA_PATH="$compat_path"
export STEAM_COMPAT_CLIENT_INSTALL_PATH="$steam_root" SteamAppId="$appid" SteamGameId="$appid"
[[ -z "$gui_display" ]] || export DISPLAY="$gui_display"
[[ -z "$gui_wayland" ]] || export WAYLAND_DISPLAY="$gui_wayland"
[[ -z "$gui_xauth" ]] || export XAUTHORITY="$gui_xauth"
[[ -z "$gui_runtime" ]] || export XDG_RUNTIME_DIR="$gui_runtime"
[[ -z "$gui_dbus" ]] || export DBUS_SESSION_BUS_ADDRESS="$gui_dbus"
[[ -z "$gui_session" ]] || export XDG_SESSION_TYPE="$gui_session"

before=$(count_wineservers "$prefix_path")
say "wineserver(s) before xdbg: $before"
say "Launching host Proton with runinprefix; keep the game open."

set +e
(cd -- "$debugger_dir" && "$proton_script" runinprefix "$debugger_path" "${debugger_args[@]}") &
proton_pid=$!
set -e
sleep 2
if kill -0 "$proton_pid" 2>/dev/null; then
    say "xdbg is running (Proton PID $proton_pid). Open Attach/Alt+A."
else
    warn "Proton exited during the 2-second check; see the output above."
fi

after=$(count_wineservers "$prefix_path")
say "wineserver(s) after xdbg: $after"
if (( before > 0 && after > before )); then
    warn "A second wineserver appeared; the debugger may be isolated."
elif (( before > 0 )); then
    say "Existing wineserver count was reused; sharing is likely."
fi

set +e
wait "$proton_pid"
status=$?
set -e
exit "$status"
