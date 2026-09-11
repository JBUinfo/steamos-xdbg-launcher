#!/usr/bin/env bash

# Run a sibling x32dbg/x64dbg through a Proton prefix on SteamOS.
# Keep this script outside Flatpak when attaching to a Steam game so the game
# and debugger share the same wineserver.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
uid=$(id -u)

appid="${XDBG_APPID:-${SteamAppId:-${SteamGameId:-}}}"
debugger_override=""
proton_override="${XDBG_PROTON_PATH:-}"
steam_root_override="${XDBG_STEAM_ROOT:-}"
compat_override="${XDBG_COMPATDATA_PATH:-}"
prefix_override="${XDBG_WINEPREFIX:-}"
launch_exe=""
target_cmdline=""
target_cwd=""
launch_mode=0
standalone_prefix_mode=0
interactive_menu=0
start_game=0
check_only=0
wait_seconds=90
log_file=""
disable_scyllahide="${XDBG_DISABLE_SCYLLAHIDE:-1}"
debugger_args=()

usage() {
    cat <<'EOF'
Usage:
  ./launch-xdbg.sh [--appid APPID] [options] [-- XDBG_ARGS...]
  ./launch-xdbg.sh --launch [EXE] [options]

Attach mode (default) expects a game running in native Steam. The script
detects its Proton prefix and launches the sibling debugger with runinprefix.
If --appid is omitted, running Steam games are detected and grouped by AppID;
the matching Windows PID is passed to xdbg when it can be identified.
Use --launch to open a standalone Windows executable in xdbg paused before its
entry point; that mode does not start Steam games. Steam games must be started
through Steam and debugged with Attach. Standalone targets use a private Proton
prefix automatically; pass --compatdata/--prefix only when a custom prefix is
needed.
When run with no arguments in a terminal, the script first asks whether to
attach or launch. Launch opens a KDE/Zenity file picker when available; cancel
it to type or drag a path. `--launch` may also omit `EXE` to open that picker;
flags skip the mode menu.

Options:
  --appid APPID       Steam AppID (also the first positional argument)
  --debugger FILE     Sibling x32dbg.exe or x64dbg.exe (auto-detected)
  --proton PATH       Proton directory or proton script
  --steam-root PATH   Alternate Steam root
  --compatdata DIR    Override the auto-detected compatdata directory
  --prefix DIR        Proton prefix directory (must be compatdata/pfx)
  --launch [EXE]      Open a non-game EXE paused before it runs; if omitted,
                      choose one with the file picker
  --target-cmdline S  Command-line string for --launch
  --target-cwd DIR    Working directory for --launch
  --start-game        Start the AppID with Steam when it is not running
  --wait SECONDS      Wait for --start-game (default: 90, max: 600)
  --log FILE          Append launcher and Proton output to FILE
  --no-scyllahide     Skip ScyllaHide for this run (useful under Proton)
  --scyllahide        Enable ScyllaHide hooks for this run (may be unstable)
  --check             Inspect only; do not launch xdbg
  -h, --help          Show this help

Examples:
  ./launch-xdbg.sh --appid 123456
  ./launch-xdbg.sh 123456 --debugger x32dbg.exe
  ./launch-xdbg.sh --appid 123456 --debugger x64dbg.exe --start-game
  ./launch-xdbg.sh --launch 'C:\Windows\System32\notepad.exe'
  ./launch-xdbg.sh --launch ./tool.exe \
      --compatdata "$HOME/.local/share/Steam/steamapps/compatdata/123456" \
      --proton "$HOME/.local/share/Steam/steamapps/common/Proton 11.0"

Find an AppID in the Steam Store URL (/app/<id>/) or in
steamapps/appmanifest_<id>.acf.

Arguments after -- are passed unchanged to xdbg in attach mode. Match the
debugger bitness to the Windows process (32-bit -> x32dbg.exe, 64-bit ->
x64dbg.exe); launch mode validates this automatically. In --launch mode use
--target-cmdline and --target-cwd for the target's arguments and working
directory. A host-path target defaults to its own directory as the working
directory. Unquoted path words are joined until the next option; quote Windows
backslashes or use forward slashes because Bash removes unquoted backslashes.
EOF
}

die() {
    printf 'Error: %s\n' "$*" >&2
    if [[ "${XDBG_PAUSE_ON_ERROR:-0}" == 1 && -t 0 ]]; then
        read -r -p 'Press Enter to close this terminal... ' _ || true
    fi
    exit 1
}
warn() { printf 'Warning: %s\n' "$*" >&2; }
say()  { printf '%s\n' "$*"; }

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
norm() { local v=${1:-}; v=${v%/}; printf '%s' "$v"; }
expand_user_path() {
    local v=${1:-}
    case "$v" in
        '~') v=${HOME:-} ;;
        '~/'*) v="${HOME:-}${v#\~}" ;;
    esac
    printf '%s' "$v"
}

env_value() {
    local blob=$1 key=$2
    awk -F= -v k="$key" '$1 == k { print substr($0, index($0, "=") + 1); exit }' <<<"$blob"
}

proc_env() { cat -- "$1" 2>/dev/null | tr '\0' '\n' || true; }
proc_cmd() { cat -- "$1" 2>/dev/null | tr '\0' ' ' || true; }

proton_from_cmdline() {
    local file=$1 arg next i
    local -a args=()
    [[ -r "$file" ]] || return 0
    while IFS= read -r -d '' arg; do
        args+=("$arg")
    done < <(cat -- "$file" 2>/dev/null)
    for ((i=0; i + 1 < ${#args[@]}; i++)); do
        arg=${args[i]}
        next=${args[i + 1]}
        [[ "$arg" == */proton ]] || continue
        case "$next" in
            waitforexitandrun|runinprefix|run) printf '%s' "$arg"; return ;;
        esac
    done
}

resolve_proton() {
    local p=$1
    [[ -d "$p" && -f "$p/proton" ]] && p="$p/proton"
    [[ -f "$p" ]] || return 1
    printf '%s' "$p"
}

to_wine_path() {
    local path=$1 converted
    # x64dbg calls CreateProcess inside Wine, so use the prefix's DOS drive
    # mapping (for example S:\\steamapps\\common\\Game) instead of passing
    # a host path as the Windows working directory.
    [[ "$path" == /* ]] || { printf '%s' "$path"; return 0; }
    converted=$(WINEDEBUG=-all "$proton_script" runinprefix winepath -w "$path" 2>/dev/null) || return 1
    converted=${converted//$'\r'/}
    converted=${converted%%$'\n'*}
    [[ -n "$converted" ]] || return 1
    printf '%s' "$converted"
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

app_name_for_id() {
    local wanted=$1 root manifest name
    for root in "${steam_roots[@]}"; do
        manifest="$root/steamapps/appmanifest_${wanted}.acf"
        [[ -f "$manifest" ]] || continue
        name=$(awk -F'"' '$2 == "name" { print $4; exit }' "$manifest")
        [[ -n "$name" ]] && { printf '%s' "$name"; return; }
    done
    printf 'AppID %s' "$wanted"
}

app_install_dir_for_id() {
    local wanted=$1 root manifest installdir
    for root in "${steam_roots[@]}"; do
        manifest="$root/steamapps/appmanifest_${wanted}.acf"
        [[ -f "$manifest" ]] || continue
        installdir=$(awk -F'"' '$2 == "installdir" { print $4; exit }' "$manifest")
        [[ -n "$installdir" ]] && { printf '%s' "$installdir"; return; }
    done
    return 1
}

infer_steam_appid() {
    local target=$1 target_real root root_real manifest id installdir game_dir game_real
    [[ "$target" == /* && -f "$target" ]] || return 1

    # A target copied from a Steam prefix is already tied to that AppID.  Check
    # the path before resolving symlinks: Proton's builtin EXEs (for example
    # pfx/drive_c/windows/system32/notepad.exe) point into Proton's own
    # steamapps/common directory, which must not be mistaken for a game.
    if [[ "$target" =~ /steamapps/compatdata/([0-9]+)/pfx(/|$) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return 0
    fi

    target_real=$(readlink -f -- "$target" 2>/dev/null || printf '%s' "$target")

    for root in "${steam_roots[@]}"; do
        [[ -d "$root/steamapps/common" ]] || continue
        root_real=$(readlink -f -- "$root" 2>/dev/null || printf '%s' "$root")
        for manifest in "$root"/steamapps/appmanifest_*.acf; do
            [[ -f "$manifest" ]] || continue
            id=${manifest##*/appmanifest_}; id=${id%.acf}
            is_uint "$id" || continue
            installdir=$(awk -F'"' '$2 == "installdir" { print $4; exit }' "$manifest")
            [[ -n "$installdir" ]] || continue
            game_dir="$root_real/steamapps/common/$installdir"
            [[ -d "$game_dir" ]] || continue
            game_real=$(readlink -f -- "$game_dir" 2>/dev/null || printf '%s' "$game_dir")
            case "$target_real/" in
                "$game_real/"*) printf '%s' "$id"; return 0 ;;
            esac
        done
    done
    return 1
}

running_ids=() running_names=() running_counts=()
collect_running_apps() {
    running_ids=() running_names=() running_counts=()
    local -A counts=()
    local file pid owner blob compat comm cmd id

    for file in /proc/[0-9]*/environ; do
        [[ -r "$file" ]] || continue
        pid=${file#/proc/}; pid=${pid%/environ}
        [[ "$pid" == "$$" ]] && continue
        owner=$(stat -c '%u' "/proc/$pid" 2>/dev/null || printf '%s' -1)
        [[ "$owner" == "$uid" ]] || continue
        blob=$(proc_env "$file")
        compat=$(norm "$(env_value "$blob" STEAM_COMPAT_DATA_PATH)")
        [[ "$compat" =~ /steamapps/compatdata/([0-9]+)(/|$) ]] || continue
        id=${BASH_REMATCH[1]}
        comm=$(cat -- "/proc/$pid/comm" 2>/dev/null || true)
        case "${comm,,}" in
            wineserver*|wineboot*|x32dbg*|x64dbg*) continue ;;
        esac
        cmd=$(proc_cmd "/proc/$pid/cmdline")
        case "${cmd,,}" in
            *x32dbg.exe*|*x64dbg.exe*) continue ;;
        esac
        counts["$id"]=$(( ${counts[$id]:-0} + 1 ))
    done

    local sorted_id
    ((${#counts[@]} > 0)) || return 1
    while IFS= read -r sorted_id; do
        [[ -n "$sorted_id" ]] || continue
        running_ids+=("$sorted_id")
        running_names+=("$(app_name_for_id "$sorted_id")")
        running_counts+=("${counts[$sorted_id]}")
    done < <(printf '%s\n' "${!counts[@]}" | sort -n)
}

choose_running_appid() {
    collect_running_apps || return 1
    local count=${#running_ids[@]} i choice
    if (( count == 1 )); then
        appid=${running_ids[0]}
        say "Detected running Steam game: ${running_names[0]} (AppID $appid)."
        return
    fi
    say "Running Steam games (processes grouped by AppID):"
    for ((i=0; i<count; i++)); do
        printf '  %2d) %s (AppID %s, %s Wine processes)\n' \
            "$((i + 1))" "${running_names[i]}" "${running_ids[i]}" "${running_counts[i]}"
    done
    [[ -t 0 ]] || die "Multiple Steam games are running; pass --appid APPID"
    while :; do
        read -r -p "Choose a running game [1-$count, 0=cancel]: " choice || die "No selection made"
        [[ "$choice" == 0 ]] && exit 0
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
            appid=${running_ids[choice - 1]}
            say "Selected ${running_names[choice - 1]} (AppID $appid)."
            return
        fi
        warn "Choose a number from 1 to $count, or 0 to cancel."
    done
}

attach_windows_pid="" attach_windows_exe=""
attach_candidate_pids=() attach_candidate_exes=()
select_attach_process() {
    attach_windows_pid="" attach_windows_exe=""
    attach_candidate_pids=() attach_candidate_exes=()
    (( launch_mode == 0 )) || return 0
    [[ -n "$appid" && -n "${proton_script:-}" ]] || return 0

    local installdir listing line wpid_hex wpid exe normalized fragment choice i
    installdir=$(app_install_dir_for_id "$appid" || true)
    [[ -n "$installdir" ]] || return 0
    fragment=${installdir//\\//}
    fragment=${fragment,,}
    fragment="/steamapps/common/${fragment#/}/"
    if command -v timeout >/dev/null 2>&1; then
        listing=$(WINEDEBUG=-all timeout 15s "$proton_script" runinprefix winedbg --command 'info proc' 2>&1 || true)
    else
        listing=$(WINEDEBUG=-all "$proton_script" runinprefix winedbg --command 'info proc' 2>&1 || true)
    fi

    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*([0-9A-Fa-f]+)[[:space:]]+[0-9]+[[:space:]]+(.+)$ ]] || continue
        wpid_hex=${BASH_REMATCH[1]}
        exe=${BASH_REMATCH[2]}
        exe=${exe#*\'}
        exe=${exe%\'}
        normalized=${exe//\\//}
        normalized=${normalized,,}
        [[ "$normalized" == *"$fragment"* ]] || continue
        wpid=$(printf '%d' "0x$wpid_hex" 2>/dev/null || true)
        [[ -n "$wpid" ]] || continue
        attach_candidate_pids+=("$wpid")
        attach_candidate_exes+=("$exe")
    done <<<"$listing"

    local count=${#attach_candidate_pids[@]}
    (( count > 0 )) || return 0
    if (( count == 1 )); then
        attach_windows_pid=${attach_candidate_pids[0]}
        attach_windows_exe=${attach_candidate_exes[0]}
        say "Detected Windows process: $attach_windows_exe (PID $attach_windows_pid)."
        return
    fi

    say "Matching Windows processes for $(app_name_for_id "$appid") (grouped by game path):"
    for ((i=0; i<count; i++)); do
        printf '  %2d) PID %s  %s\n' "$((i + 1))" "${attach_candidate_pids[i]}" "${attach_candidate_exes[i]}"
    done
    if [[ ! -t 0 ]]; then
        warn "Multiple matching processes found; xdbg Attach will remain available."
        return
    fi
    while :; do
        read -r -p "Choose a process to attach [1-$count, 0=skip]: " choice || die "No selection made"
        [[ "$choice" == 0 ]] && return
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
            attach_windows_pid=${attach_candidate_pids[choice - 1]}
            attach_windows_exe=${attach_candidate_exes[choice - 1]}
            say "Selected $attach_windows_exe (PID $attach_windows_pid)."
            return
        fi
        warn "Choose a number from 1 to $count, or 0 to skip."
    done
}

choose_appid() {
    collect_installed_apps
    local count=${#installed_ids[@]} i choice
    if (( launch_mode )); then
        (( count > 0 )) || die "No installed Steam apps found; pass --compatdata DIR"
    else
        (( count > 0 )) || die "No installed Steam apps found; pass --appid APPID"
    fi
    if (( count == 1 )); then
        appid=${installed_ids[0]}
        if (( launch_mode )); then
            say "Selected ${installed_names[0]} as the Proton prefix (AppID $appid)."
        else
            say "Selected ${installed_names[0]} (AppID $appid)."
        fi
        return
    fi

    if (( launch_mode )); then
        say "Choose a Steam Proton prefix for the target:"
    else
        say "Installed Steam apps:"
    fi
    for ((i=0; i<count; i++)); do
        printf '  %2d) %s (AppID %s)\n' "$((i + 1))" "${installed_names[i]}" "${installed_ids[i]}"
    done
    if (( launch_mode )); then
        [[ -t 0 ]] || die "Multiple prefixes found; pass --compatdata DIR or --appid APPID"
    else
        [[ -t 0 ]] || die "Multiple apps found; pass --appid APPID in non-interactive use"
    fi
    while :; do
        if (( launch_mode )); then
            read -r -p "Choose a prefix [1-$count, 0=cancel]: " choice || die "No selection made"
        else
            read -r -p "Choose a game [1-$count, 0=cancel]: " choice || die "No selection made"
        fi
        [[ "$choice" == 0 ]] && exit 0
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
            appid=${installed_ids[choice - 1]}
            if (( launch_mode )); then
                say "Selected ${installed_names[choice - 1]} as the Proton prefix (AppID $appid)."
            else
                say "Selected ${installed_names[choice - 1]} (AppID $appid)."
            fi
            return
        fi
        warn "Choose a number from 1 to $count, or 0 to cancel."
    done
}

choose_launch_target() {
    local start_dir selected target
    start_dir="${HOME:-$PWD}/Downloads"
    [[ -d "$start_dir" ]] || start_dir="${HOME:-$PWD}"

    say "Select a Windows executable (cancel the file picker to type a path)."
    selected=""
    if [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
        if command -v kdialog >/dev/null 2>&1; then
            selected=$(kdialog --getopenfilename "$start_dir" '*.exe' 2>/dev/null || true)
        elif command -v zenity >/dev/null 2>&1; then
            selected=$(zenity --file-selection \
                --title='Select a Windows executable' \
                --filename="$start_dir/" \
                --file-filter='Windows executables | *.exe' 2>/dev/null || true)
        fi
    fi
    if [[ -n "$selected" ]]; then
        launch_exe=$(expand_user_path "$selected")
        return
    fi

    while :; do
        read -r -e -p "Windows EXE path (or drag a file here): " target || die "No target path supplied"
        target=$(expand_user_path "$target")
        [[ -n "$target" ]] && { launch_exe=$target; return; }
        warn "Enter a path to a Windows executable."
    done
}

choose_mode() {
    local choice
    say "xdbg launcher mode:"
    say "  1) Attach to a running Steam game"
    say "  2) Open a Windows executable before it runs"
    while :; do
        read -r -p "Choose a mode [1-2, 0=cancel]: " choice || die "No selection made"
        case "$choice" in
            1)
                launch_mode=0
                return
                ;;
            2)
                launch_mode=1
                choose_launch_target
                return
                ;;
            0) exit 0 ;;
            *) warn "Choose 1 for Attach, 2 for Launch, or 0 to cancel." ;;
        esac
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
        proton=$(proton_from_cmdline "/proc/$pid/cmdline" || true)
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

locate_explicit_prefix() {
    compat_path="" prefix_path="" steam_root=""

    if [[ -n "$compat_override" ]]; then
        compat_path=$(norm "$compat_override")
        prefix_path=$(norm "${prefix_override:-$compat_path/pfx}")
        [[ "$prefix_path" == "$compat_path/pfx" ]] || \
            die "--prefix must be exactly --compatdata/pfx when both are supplied"
    elif [[ -n "$prefix_override" ]]; then
        prefix_path=$(norm "$prefix_override")
        [[ "$prefix_path" == */pfx ]] || \
            die "--prefix must point to Proton's compatdata/pfx directory; use --compatdata for its parent"
        compat_path=${prefix_path%/pfx}
    else
        return 1
    fi

    [[ -d "$compat_path" ]] || die "Compatdata not found: $compat_path"
    [[ -d "$prefix_path" ]] || die "Wine prefix not found: $prefix_path"

    # Recover a Steam root/AppID when the path follows Steam's normal layout.
    if [[ "$compat_path" =~ ^(.+)/steamapps/compatdata/([0-9]+)$ ]]; then
        local inferred_root=${BASH_REMATCH[1]} inferred_appid=${BASH_REMATCH[2]}
        if [[ -n "$appid" && "$appid" != "$inferred_appid" ]]; then
            die "AppID $appid does not match compatdata path $inferred_appid"
        fi
        appid=$inferred_appid
        steam_root=$(norm "${steam_root_override:-$inferred_root}")
    else
        steam_root=$(norm "$steam_root_override")
    fi
}

find_default_proton() {
    local root candidate name
    local -a stable=() fallback=()
    for root in "${steam_roots[@]}"; do
        for candidate in "$root"/steamapps/common/Proton*/proton; do
            [[ -f "$candidate" ]] || continue
            name=${candidate%/proton}
            name=${name##*/}
            case "$name" in
                Proton\ [0-9]*.[0-9]*) stable+=("$candidate") ;;
                *) fallback+=("$candidate") ;;
            esac
        done
    done

    if ((${#stable[@]} > 0)); then
        printf '%s\n' "${stable[@]}" | sort -V | tail -n 1
    elif ((${#fallback[@]} > 0)); then
        printf '%s\n' "${fallback[@]}" | sort -V | tail -n 1
    fi
}

locate_standalone_prefix() {
    local data_home
    if [[ -n "${XDG_DATA_HOME:-}" ]]; then
        data_home=$XDG_DATA_HOME
    else
        data_home="${HOME:-$PWD}/.local/share"
    fi
    compat_path=$(norm "$data_home/xdbg/proton-prefix")
    prefix_path="$compat_path/pfx"
    if [[ -n "$steam_root_override" ]]; then
        steam_root=$(norm "$steam_root_override")
    else
        steam_root=$(norm "${steam_roots[0]:-}")
    fi
    mkdir -p -- "$compat_path" || die "Cannot create standalone Proton prefix: $compat_path"
    standalone_prefix_mode=1
    [[ -n "$proton_override" ]] || proton_override=$(find_default_proton || true)
    [[ -n "$proton_override" ]] || \
        die "Cannot find an installed Proton version; pass --proton /path/to/Proton"
    say "Using standalone Proton prefix: $compat_path"
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

pe_bitness() {
    local info
    command -v file >/dev/null 2>&1 || return 1
    # -L follows Proton's symlinks to builtin Windows executables.
    info=$(file -L -b -- "$1" 2>/dev/null || true)
    case "$info" in
        *PE32+*) printf '64' ;;
        *PE32*) printf '32' ;;
        *) return 1 ;;
    esac
}

prefix_path_to_wine() {
    local path=$1 relative
    [[ "$path" == "$prefix_path/"* ]] || return 1
    relative=${path#"$prefix_path/"}
    case "$relative" in
        drive_c/*)
            relative=${relative#drive_c/}
            relative=${relative//\//\\}
            printf 'C:\\%s' "$relative"
            ;;
        drive_c)
            printf 'C:\\'
            ;;
        *)
            return 1
            ;;
    esac
}

if (($# == 0)) && [[ -t 0 ]]; then
    interactive_menu=1
fi

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
        --compatdata|--compat-data) (($# >= 2)) || die "$1 needs a value"; compat_override=$2; shift 2 ;;
        --compatdata=*|--compat-data=*) compat_override=${1#*=}; shift ;;
        --prefix|--wineprefix) (($# >= 2)) || die "$1 needs a value"; prefix_override=$2; shift 2 ;;
        --prefix=*|--wineprefix=*) prefix_override=${1#*=}; shift ;;
        --launch|--target)
            launch_mode=1
            if (($# < 2)) || [[ "$2" == -* ]]; then
                shift
            else
                launch_exe=$2
                shift 2
                # If a path with spaces was left unquoted, the shell split it
                # into several words. Join them until the next option.
                while (($#)) && [[ "$1" != -* ]]; do
                    launch_exe+=" $1"
                    shift
                done
            fi
            ;;
        --launch=*|--target=*)
            launch_exe=${1#*=}
            launch_mode=1
            shift
            while (($#)) && [[ "$1" != -* ]]; do
                launch_exe+=" $1"
                shift
            done
            ;;
        --target-cmdline) (($# >= 2)) || die "--target-cmdline needs a value"; target_cmdline=$2; shift 2 ;;
        --target-cmdline=*) target_cmdline=${1#*=}; shift ;;
        --target-cwd) (($# >= 2)) || die "--target-cwd needs a directory"; target_cwd=$2; shift 2 ;;
        --target-cwd=*) target_cwd=${1#*=}; shift ;;
        --start-game) start_game=1; shift ;;
        --wait) (($# >= 2)) || die "--wait needs a number"; wait_seconds=$2; shift 2 ;;
        --wait=*) wait_seconds=${1#*=}; shift ;;
        --log) (($# >= 2)) || die "--log needs a file"; log_file=$2; shift 2 ;;
        --log=*) log_file=${1#*=}; shift ;;
        --no-scyllahide) disable_scyllahide=1; shift ;;
        --scyllahide) disable_scyllahide=0; shift ;;
        --check) check_only=1; shift ;;
        --) shift; debugger_args=("$@"); break ;;
        -*) die "Unknown option: $1 (put xdbg arguments after --)" ;;
        *) [[ -z "$appid" ]] || die "Unexpected argument: $1"; appid=$1; shift ;;
    esac
done

if (( interactive_menu )); then
    choose_mode
fi

if (( launch_mode )) && [[ -z "$launch_exe" ]]; then
    if [[ -t 0 || -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
        choose_launch_target
    else
        die "--launch needs an executable path when no graphical file picker is available"
    fi
fi

is_uint "$wait_seconds" || die "--wait must be an integer"
(( wait_seconds <= 600 )) || die "--wait cannot exceed 600 seconds"
[[ "$disable_scyllahide" == 0 || "$disable_scyllahide" == 1 ]] || \
    die "XDBG_DISABLE_SCYLLAHIDE must be 0 or 1"

if (( launch_mode )); then
    [[ -n "$launch_exe" ]] || die "--launch needs an executable"
    # Accept a host path (the usual case) and also a Wine-style Windows path.
    if [[ "$launch_exe" =~ ^[A-Za-z]: && "$launch_exe" != [A-Za-z]:[\\/]* ]]; then
        die "Windows paths need a separator; quote backslashes or use forward slashes (for example C:/Windows/System32/notepad.exe)"
    fi
    if [[ "$launch_exe" != /* && ! "$launch_exe" =~ ^[A-Za-z]:[\\/].* ]]; then
        launch_exe="$PWD/$launch_exe"
    fi
    if [[ "$launch_exe" != *:* ]]; then
        [[ -f "$launch_exe" ]] || die "Launch target not found: $launch_exe"
    fi
    if [[ -n "$target_cwd" && "$target_cwd" != *:* ]]; then
        [[ "$target_cwd" == /* ]] || target_cwd="$PWD/$target_cwd"
        [[ -d "$target_cwd" ]] || die "Target working directory not found: $target_cwd"
    fi
    if [[ -z "$target_cwd" && "$launch_exe" == /* ]]; then
        target_cwd=$(dirname -- "$launch_exe")
    fi
    (( start_game == 0 )) || die "--start-game cannot be combined with --launch"
    ((${#debugger_args[@]} == 0)) || \
        die "Do not pass xdbg arguments after -- with --launch; use --target-cmdline/--target-cwd"
fi

debugger_path=$(find_debugger)
[[ -f "$debugger_path" ]] || die "Debugger not found: $debugger_path"
debugger_dir=$(cd -- "$(dirname -- "$debugger_path")" && pwd -P) || die "Cannot access debugger directory"

scyllahide_plugin=""
scyllahide_backup=""
disable_scyllahide_for_run() {
    local candidate
    (( disable_scyllahide == 1 )) || return 0
    for candidate in \
        "$debugger_dir/plugins/ScyllaHideX64DBGPlugin.dp32" \
        "$debugger_dir/plugins/ScyllaHideX64DBGPlugin.dp64"; do
        [[ -f "$candidate" ]] || continue
        local backup="${candidate}.lxdbg-disabled-${BASHPID}"
        [[ ! -e "$backup" ]] || die "ScyllaHide backup already exists: $backup"
        mv -- "$candidate" "$backup" || \
            die "Could not disable ScyllaHide: $candidate"
        scyllahide_plugin=$candidate
        scyllahide_backup=$backup
        say "ScyllaHide disabled for this run (set XDBG_DISABLE_SCYLLAHIDE=0 to enable it)."
        return 0
    done
}

restore_scyllahide() {
    [[ -n "$scyllahide_plugin" && -n "$scyllahide_backup" ]] || return 0
    if [[ -e "$scyllahide_backup" ]]; then
        mv -- "$scyllahide_backup" "$scyllahide_plugin" || \
            warn "Could not restore ScyllaHide: $scyllahide_plugin"
    fi
    scyllahide_plugin=""
    scyllahide_backup=""
}

if (( launch_mode )); then
    target_bits=$(pe_bitness "$launch_exe" || true)
    debugger_bits=$(pe_bitness "$debugger_path" || true)
    if [[ -n "$target_bits" && -n "$debugger_bits" && "$target_bits" != "$debugger_bits" ]]; then
        die "Architecture mismatch: target is ${target_bits}-bit but debugger is ${debugger_bits}-bit; use x${target_bits}dbg.exe"
    fi
fi

if [[ -n "$log_file" ]]; then
    mkdir -p "$(dirname -- "$log_file")"
    exec > >(tee -a "$log_file") 2>&1
fi

discover_roots
if (( launch_mode )); then
    if [[ -n "$compat_override" || -n "$prefix_override" ]]; then
        locate_explicit_prefix
    else
        if [[ -z "$appid" ]]; then
            inferred_appid=$(infer_steam_appid "$launch_exe" || true)
            if [[ -n "$inferred_appid" ]]; then
                appid=$inferred_appid
                say "Detected Steam game: $(app_name_for_id "$appid") (AppID $appid)."
            fi
        fi
        if [[ -n "$appid" ]]; then
            is_uint "$appid" || die "AppID must be numeric: $appid"
            locate_prefix || die "Compatdata not found for AppID $appid; pass --compatdata DIR"
        else
            locate_standalone_prefix
        fi
    fi
else
    if [[ -z "$appid" ]]; then
        if (( start_game )); then
            choose_appid
        else
            choose_running_appid || \
                die "No running Steam games detected; start a game first or pass --appid APPID"
        fi
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
fi
recover_gui

[[ -z "$appid" ]] || is_uint "$appid" || die "AppID must be numeric: $appid"

say "Debugger: $debugger_path"
if (( launch_mode )); then
    say "Mode: launch before entry point"
    say "Launch target: $launch_exe"
else
    say "Mode: attach to running game"
fi
[[ -n "$appid" ]] && say "AppID: $appid"
if [[ -n "$game_pid" ]]; then
    say "Detected Wine process: Linux PID $game_pid"
elif (( launch_mode )); then
    say "Game process: not required"
else
    say "Game process: not found"
fi
[[ -n "$compat_path" ]] && say "Compatdata: $compat_path"
[[ -n "$prefix_path" ]] && say "WINEPREFIX: $prefix_path"
[[ -n "$steam_root" ]] && say "Steam root: $steam_root"
if (( launch_mode )); then
    [[ -n "$target_cwd" ]] && say "Target working directory: $target_cwd"
fi
[[ -n "$game_proton" ]] && say "Detected Proton: $game_proton"
[[ -n "$game_container" ]] && say "Container: $game_container"
say "DISPLAY: ${gui_display:-<empty>}"
say "WAYLAND_DISPLAY: ${gui_wayland:-<empty>}"
say "XDG_RUNTIME_DIR: ${gui_runtime:-<empty>}"

if (( check_only )); then
    if (( launch_mode )); then
        say "Check: launch target and Proton prefix are ready."
    else
        [[ -n "$game_pid" ]] && say "Check: game is running." || say "Check: game is not running."
    fi
    [[ -n "$compat_path" ]] && say "Check: compatdata found." || warn "No compatdata found; install the game in Steam or pass --compatdata."
    exit 0
fi

if [[ -z "$compat_path" || ! -d "$compat_path" ]]; then
    if (( launch_mode )); then
        die "Compatdata not found; pass --compatdata DIR or --prefix DIR"
    fi
    die "Compatdata not found for AppID $appid"
fi
if [[ ! -d "$prefix_path" ]]; then
    if (( launch_mode && standalone_prefix_mode )); then
        say "The standalone Proton prefix will be initialized on first run."
    else
        die "Wine prefix not found: $prefix_path"
    fi
fi
if (( ! launch_mode )); then
    [[ -n "$game_pid" ]] || die "Game is not running; launch it in Steam or use --start-game"
fi

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
if [[ -n "$steam_root" ]]; then
    export STEAM_COMPAT_CLIENT_INSTALL_PATH="$steam_root"
else
    unset STEAM_COMPAT_CLIENT_INSTALL_PATH || true
fi
if [[ -n "$appid" ]]; then
    export SteamAppId="$appid" SteamGameId="$appid"
else
    unset SteamAppId SteamGameId || true
fi
[[ -z "$gui_display" ]] || export DISPLAY="$gui_display"
[[ -z "$gui_wayland" ]] || export WAYLAND_DISPLAY="$gui_wayland"
[[ -z "$gui_xauth" ]] || export XAUTHORITY="$gui_xauth"
[[ -z "$gui_runtime" ]] || export XDG_RUNTIME_DIR="$gui_runtime"
[[ -z "$gui_dbus" ]] || export DBUS_SESSION_BUS_ADDRESS="$gui_dbus"
[[ -z "$gui_session" ]] || export XDG_SESSION_TYPE="$gui_session"

if (( ! launch_mode )); then
    select_attach_process
fi

launch_target_arg="$launch_exe"
launch_cwd_arg="$target_cwd"
if (( launch_mode )); then
    # Keep paths inside an explicit Steam prefix on its C: drive.  This is
    # important for Proton builtin EXEs: winepath may otherwise follow their
    # symlink into Proton's installation and produce a Z: path.
    if [[ "$launch_exe" == "$prefix_path/"* ]]; then
        launch_target_arg=$(prefix_path_to_wine "$launch_exe") || \
            die "Could not map launch target into the Wine prefix: $launch_exe"
    else
        launch_target_arg=$(to_wine_path "$launch_exe") || \
            die "Could not convert launch target to a Wine path: $launch_exe"
    fi
    if [[ -n "$target_cwd" ]]; then
        if [[ "$target_cwd" == "$prefix_path/"* ]]; then
            launch_cwd_arg=$(prefix_path_to_wine "$target_cwd") || \
                die "Could not map target working directory into the Wine prefix: $target_cwd"
        else
            launch_cwd_arg=$(to_wine_path "$target_cwd") || \
                die "Could not convert target working directory to a Wine path: $target_cwd"
        fi
    fi
fi

before=$(count_wineservers "$prefix_path")
say "wineserver(s) before xdbg: $before"
if (( launch_mode )); then
    say "Launching target through xdbg before its entry point."
    launch_args=()
    [[ -z "$launch_cwd_arg" ]] || launch_args+=(-workingDir "$launch_cwd_arg")
    launch_args+=("$launch_target_arg")
    if [[ -n "$target_cmdline" ]]; then
        # Modern x64dbg accepts target arguments after the -- delimiter.
        launch_args+=(-- "$target_cmdline")
    fi
else
    say "Launching host Proton with runinprefix; keep the game open."
    if [[ -n "$attach_windows_pid" && ${#debugger_args[@]} -eq 0 ]]; then
        say "Starting xdbg with automatic attach (-p $attach_windows_pid)."
        launch_args=(-p "$attach_windows_pid")
    else
        launch_args=("${debugger_args[@]}")
    fi
fi

proton_pid=""
stop_debugger() {
    local code=${1:-130}
    if [[ -n "${proton_pid:-}" ]] && kill -0 "$proton_pid" 2>/dev/null; then
        kill -TERM "$proton_pid" 2>/dev/null || true
        wait "$proton_pid" 2>/dev/null || true
    fi
    restore_scyllahide
    exit "$code"
}
trap 'restore_scyllahide' EXIT
trap 'stop_debugger 130' INT
trap 'stop_debugger 143' HUP TERM

disable_scyllahide_for_run

set +e
(cd -- "$debugger_dir" && exec "$proton_script" runinprefix "$debugger_path" "${launch_args[@]}") &
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
restore_scyllahide
exit "$status"
