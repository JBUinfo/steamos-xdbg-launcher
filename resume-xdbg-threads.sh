#!/usr/bin/env bash

# Emergency recovery helper for x64dbg-MCP Server.
# It resumes every thread reported by the active x64dbg MCP session.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
arch=auto
config_override="${XDBG_MCP_CONFIG:-}"
url_override="${XDBG_MCP_URL:-}"
token_override="${XDBG_MCP_TOKEN:-}"
request_timeout="${XDBG_MCP_TIMEOUT:-5}"
passes=1
dry_run=0
continue_after=1

usage() {
    cat <<'EOF'
Usage:
  ./resume-xdbg-threads.sh [options]

Resume all thread IDs exposed by the active x64dbg-MCP Server session.
The script reads the local mcp_config.json token automatically.

Options:
  --arch x64|x32      Prefer one debugger architecture (default: auto)
  --config FILE       Use this mcp_config.json directly
  --url URL           Override the MCP URL (for example http://127.0.0.1:9094/)
  --token TOKEN       Override the MCP bearer token
  --passes N          Resume each thread up to N times (default: 1)
  --dry-run           Inspect and list threads without changing anything
  --continue          Call the MCP `run` tool after resuming the threads (default)
  --threads-only      Resume threads but leave x64dbg paused
  -h, --help          Show this help

Examples:
  ./resume-xdbg-threads.sh
  ./resume-xdbg-threads.sh --arch x64 --passes 2
  ./resume-xdbg-threads.sh --dry-run
EOF
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf 'Warning: %s\n' "$*" >&2
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

expand_user_path() {
    local value=${1:-}
    case "$value" in
        '~') value=${HOME:-} ;;
        '~/'*) value="${HOME:-}${value#\~}" ;;
    esac
    printf '%s' "$value"
}

while (($#)); do
    case "$1" in
        --arch)
            (($# >= 2)) || die "--arch needs x64 or x32"
            arch=${2,,}
            [[ "$arch" == x64 || "$arch" == x32 || "$arch" == auto ]] || die "--arch must be x64, x32, or auto"
            shift 2
            ;;
        --config)
            (($# >= 2)) || die "--config needs a file"
            config_override=$(expand_user_path "$2")
            shift 2
            ;;
        --url)
            (($# >= 2)) || die "--url needs a URL"
            url_override=$2
            shift 2
            ;;
        --token)
            (($# >= 2)) || die "--token needs a value"
            token_override=$2
            shift 2
            ;;
        --passes)
            (($# >= 2)) || die "--passes needs a positive integer"
            passes=$2
            [[ "$passes" =~ ^[1-9][0-9]*$ ]] || die "--passes must be a positive integer"
            ((passes <= 10)) || die "--passes cannot exceed 10"
            shift 2
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        --continue|--run)
            continue_after=1
            shift
            ;;
        --threads-only)
            continue_after=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

require_command curl
require_command jq

configs=()
add_config() {
    local candidate=${1:-} existing
    [[ -n "$candidate" && -r "$candidate" ]] || return 0
    for existing in "${configs[@]}"; do
        [[ "$existing" == "$candidate" ]] && return 0
    done
    configs+=("$candidate")
}

if [[ -n "$config_override" ]]; then
    add_config "$config_override"
else
    case "$SCRIPT_DIR" in
        */x64|*/x32) add_config "$SCRIPT_DIR/mcp_config.json" ;;
    esac
    add_config "$SCRIPT_DIR/x64/mcp_config.json"
    add_config "$SCRIPT_DIR/x32/mcp_config.json"
    add_config "${HOME:-}/.local/share/xdbg/release/x64/mcp_config.json"
    add_config "${HOME:-}/.local/share/xdbg/release/x32/mcp_config.json"
fi

if [[ -n "$config_override" && ${#configs[@]} -eq 0 ]]; then
    die "MCP config not found: $config_override"
fi
if [[ -z "$url_override" && ${#configs[@]} -eq 0 ]]; then
    die "No mcp_config.json found. Use --config, --url/--token, or place this script beside x64dbg."
fi

url=""
token=""
selected_config=""
selected_state=""
rpc_id=0

load_config() {
    local config=$1 ip port config_token
    ip=$(jq -er '(.IpAddress // .ipAddress // .ip // "127.0.0.1") | tostring' "$config") || return 1
    port=$(jq -er '(.Port // .port) | tonumber' "$config") || return 1
    config_token=$(jq -er '(.AuthToken // .authToken // .token // "") | tostring' "$config") || return 1
    [[ -n "$token_override" || -n "$config_token" ]] || return 1

    [[ "$ip" == 0.0.0.0 || "$ip" == :: ]] && ip=127.0.0.1
    url=${url_override:-http://$ip:$port/}
    [[ "$url" == */ ]] || url="$url/"
    token=${token_override:-$config_token}
}

rpc() {
    local method=$1 arguments=${2-} payload response
    [[ -n "$arguments" ]] || arguments='{}'
    rpc_id=$((rpc_id + 1))
    payload=$(jq -cn \
        --argjson id "$rpc_id" \
        --arg method "$method" \
        --argjson arguments "$arguments" \
        '{jsonrpc:"2.0",id:$id,method:"tools/call",params:{name:$method,arguments:$arguments}}') || return 1

    if ! response=$(curl -sS --fail \
        --connect-timeout "$request_timeout" --max-time "$request_timeout" \
        -H "Authorization: Bearer $token" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json' \
        --data "$payload" "$url"); then
        return 1
    fi

    if jq -e '(.error != null) or (.result.isError == true)' >/dev/null <<<"$response"; then
        jq -r '
            if .error then (.error.message // "JSON-RPC error")
            else ([.result.content[]?.text] | join("\n"))
            end' <<<"$response" >&2
        return 2
    fi
    printf '%s' "$response"
}

response_text() {
    jq -r '[.result.content[]? | select(.type == "text") | .text] | join("\n")'
}

state_is_active() {
    [[ "$1" == *"isDebugging: true"* && "$1" != *"NO_TARGET"* ]]
}

select_server() {
    local config response text first_reachable=""

    if [[ -n "$url_override" ]]; then
        url="$url_override"
        [[ "$url" == */ ]] || url="$url/"
        [[ -n "$token_override" ]] || die "--url requires --token or XDBG_MCP_TOKEN"
        token=$token_override
        if ! response=$(rpc GetDebugState '{}'); then
            die "Cannot connect to x64dbg MCP at $url"
        fi
        selected_state=$(response_text <<<"$response")
        return
    fi

    for config in "${configs[@]}"; do
        [[ "$arch" == auto || "$config" == */"$arch"/mcp_config.json ]] || continue
        load_config "$config" || continue
        if ! response=$(rpc GetDebugState '{}'); then
            continue
        fi
        text=$(response_text <<<"$response")
        [[ -n "$first_reachable" ]] || first_reachable=$config
        if state_is_active "$text"; then
            selected_config=$config
            selected_state=$text
            return
        fi
    done

    if [[ -n "$first_reachable" ]]; then
        selected_config=$first_reachable
        load_config "$selected_config" || die "Invalid MCP config: $selected_config"
        response=$(rpc GetDebugState) || die "Cannot query x64dbg MCP state"
        selected_state=$(response_text <<<"$response")
        return
    fi

    die "No reachable x64dbg MCP server found${arch:+ for $arch}. Start x64dbg with the MCP plugin."
}

select_server

printf 'MCP: %s\n' "${selected_config:-$url}"
printf '%s\n' "$selected_state" | sed -n '1,8p'

if ! state_is_active "$selected_state"; then
    die "x64dbg has no active debug session."
fi

if [[ "$selected_state" == *"isRunning: true"* ]]; then
    printf '%s\n' 'The target is already running; no threads need resuming.'
    exit 0
fi

if ! threads_response=$(rpc GetThreads '{}'); then
    die "Could not read threads from x64dbg."
fi
threads_text=$(response_text <<<"$threads_response")
mapfile -t thread_ids < <(sed -nE 's/.*TID=([0-9]+).*/\1/p' <<<"$threads_text" | sort -nu)
((${#thread_ids[@]} > 0)) || die "x64dbg returned no thread IDs."

printf 'Threads found: %s\n' "${#thread_ids[@]}"
if ((dry_run)); then
    printf '%s\n' "$threads_text"
    exit 0
fi

# Resume x64dbg's process-wide thread set first. The individual calls below
# also clear any nested suspend counts exposed by the thread list.
resumeall_arguments='{"command":"resumeallthreads"}'
if response=$(rpc ExecuteDebuggerCommand "$resumeall_arguments"); then
    printf '%s\n' "$(response_text <<<"$response")" | sed -n '1,4p'
else
    warn 'The global resumeallthreads command failed; continuing with per-thread recovery.'
fi

resumed=0
failed=0
for ((pass = 1; pass <= passes; pass++)); do
    ((passes > 1)) && printf 'Resume pass %s/%s\n' "$pass" "$passes"
    for thread_id in "${thread_ids[@]}"; do
        arguments=$(jq -cn --argjson threadId "$thread_id" '{threadId:$threadId}')
        if response=$(rpc ResumeThread "$arguments"); then
            text=$(response_text <<<"$response")
            if [[ "$text" == *"Thread resumed."* ]]; then
                resumed=$((resumed + 1))
                printf '  TID %s: resumed\n' "$thread_id"
            else
                failed=$((failed + 1))
                printf '  TID %s: %s\n' "$thread_id" "${text//$'\n'/ }" >&2
            fi
        else
            failed=$((failed + 1))
            printf '  TID %s: MCP request failed\n' "$thread_id" >&2
        fi
    done
done

printf 'Resume requests: %s succeeded, %s failed.\n' "$resumed" "$failed"

if final_response=$(rpc GetDebugState '{}'); then
    final_state=$(response_text <<<"$final_response")
    printf '%s\n' "$final_state" | sed -n '1,8p'
fi

if ((continue_after)); then
    printf '%s\n' 'Calling x64dbg Run (F9)...'
    run_arguments='{"timeoutMs":1000}'
    if run_response=$(rpc run "$run_arguments"); then
        run_text=$(response_text <<<"$run_response")
        printf '%s\n' "$run_text" | sed -n '1,8p'
        if [[ "$run_text" == *"Breakpoint hit"* || "$run_text" == *"PAUSED"* ]]; then
            warn 'x64dbg paused again at a breakpoint or exception; disable/adjust that breakpoint if you want the target to keep running.'
        fi
    else
        warn 'The threads were resumed, but x64dbg Run did not return successfully.'
    fi
fi

((failed == 0))
