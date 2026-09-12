# xdbg launcher for SteamOS

`launch-xdbg.sh` runs a sibling `x32dbg.exe` or `x64dbg.exe` through Proton.
It has two modes:

- **Attach:** attach xdbg to a Steam game that is already running (or start it
  through Steam with `--start-game`).
- **Launch:** open a Windows `.exe` in xdbg paused before its entry point. You
  can inspect it without running it; this mode is for standalone executables,
  not for starting Steam games.

For a Steam game, xdbg can load the EXE without running it, but it cannot start
the game itself. Steam must create the game process; start it through Steam and
use **Attach** while it is running.

## Requirements

- SteamOS Desktop Mode and a complete x64dbg release (keep its DLLs/plugins).
- Use `x32dbg.exe` for 32-bit targets and `x64dbg.exe` for 64-bit targets.
- Steam games must be started through native Steam so the game and debugger
  share `wineserver`; Steam Flatpak is rejected for Attach mode.
- `curl` and `jq` are required by the optional MCP recovery helper.
- Launch mode creates and reuses a private Proton prefix for standalone
  executables, so no AppID or compatdata path is required. Use
  `--compatdata`/`--prefix` only for a custom prefix. The private prefix is
  per-user and is created automatically; no pre-existing folder is required.

The launcher does not change game files or bypass anti-cheat. Debugging can
make a game or the desktop unstable; use an offline/test setup.

## Install

Put one copy of the script beside the debugger:

```text
x32/
  launch-xdbg.sh
  x32dbg.exe
  ...the rest of the x64dbg release...
```

```bash
chmod +x launch-xdbg.sh
```

If both debugger executables are beside the script, select one with
`--debugger FILE`.

## Use

### Interactive mode

Run the script with no arguments (or use a Desktop shortcut):

```text
1) Attach to a running Steam game
2) Open a Windows executable before it runs
```

Attach detects running Steam games first. If one game is running it is selected
automatically; if several are running, the menu shows one entry per AppID and
the number of Wine processes instead of listing every helper process. The
launcher then queries Wine's process list and automatically passes the matching
Windows PID to xdbg when there is one clear game process. If several game
processes exist, it shows their paths/PIDs so you can choose before xdbg opens.
Launch opens a file picker in Downloads (KDE's `kdialog`, or `zenity` when
available), so a downloaded `.exe` can be selected without knowing its Linux
path. Cancel the picker to type or drag a path. It uses the private Proton
prefix, opens xdbg paused, and does not start Steam games. Any CLI flag skips
this menu. You can also run `./launch-xdbg.sh --launch` without a path to open
the picker directly.

### Attach to a running Steam game

Start the game normally from Steam first, then run the script. Omit `--appid` to
detect a running game automatically. If several games are running, choose one
from the grouped list. Pass `--appid` directly when the process does not expose
Steam's compatdata environment or when using `--start-game`. The ID is in the
Steam Store URL (`/app/<id>/`) or in `steamapps/appmanifest_<id>.acf`.

```bash
./launch-xdbg.sh
./launch-xdbg.sh --appid 123456 --debugger x64dbg.exe
./launch-xdbg.sh --appid 123456 --start-game --wait 120
```

`--start-game` starts the game normally with Steam, then waits for it. The
launcher attempts the same Windows-PID selection after the game starts; if it
cannot identify one process, open **Attach** (`Alt+A`) and select the actual
game executable rather than a launcher/helper.

### Launch before the target runs (non-game executables)

Use this mode for Windows tools that are not Steam games. xdbg opens the target
paused before its entry point, so you can inspect it without executing it; press
Run/F9 only when you want to start that standalone program.

For example, launch Windows Notepad without supplying an AppID or a
`--compatdata` path. The prefix is created under
`$XDG_DATA_HOME/xdbg/proton-prefix` (or `~/.local/share/xdbg/proton-prefix`):
this is the current user's private directory, not a repository or machine-wide
path.

```bash
./launch-xdbg.sh --launch 'C:\Windows\System32\notepad.exe'
# Or omit the path and choose a downloaded .exe in the file picker:
./launch-xdbg.sh --launch
```

For CLI paths containing spaces, quoting is recommended; the launcher also
joins unquoted path words until the next option. Bash removes unquoted Windows
backslashes, so use quotes or forward slashes (`C:/Windows/System32/notepad.exe`)
for Windows-style paths. You can still pass `--compatdata`/`--prefix` explicitly
for a custom prefix.

Optional target arguments and working directory:

```bash
./launch-xdbg.sh --launch "/path/to/tool.exe" \
  --proton "/path/to/Proton" \
  --target-cmdline 'one two' --target-cwd "/path/to/tool-dir"
```

The launcher converts Linux paths to the prefix's Windows drive mapping, then
passes the working directory with xdbg's `-workingDir` option. Target
arguments go after xdbg's `--` separator, so they are not mistaken for extra
xdbg positional arguments.

Paths already inside a Steam prefix are handled specially. For example,
`.../steamapps/compatdata/239140/pfx/drive_c/windows/system32/notepad.exe`
automatically selects AppID `239140` and is passed to xdbg as
`C:\windows\system32\notepad.exe`; Proton's symlink to its builtin EXE is
not followed to the wrong Proton AppID. Use the debugger that matches the
target's PE type (the Proton Notepad example is normally 64-bit, so use the
x64 script).

ScyllaHide stays installed but is skipped by default because its hooks can
terminate debugged processes under Proton. Use `--scyllahide` (or
`XDBG_DISABLE_SCYLLAHIDE=0`) when a target needs it. The Desktop shortcuts
explicitly keep it disabled for a stable default.

The target path can be a Linux path or a Wine-style Windows path. Steam games
must be created by Steam, so launching their EXE directly from xdbg can stop
with a Steam application-load error. To debug a Steam game, start it through
Steam and use Attach (or `--start-game`); do not press Run/F9 in Launch mode.
Native Linux programs are not supported by xdbg.

Host-path targets use their containing directory as the default working
directory. Override it with `--target-cwd` when a program needs another one.

`--check` prints the detected prefix without launching. In attach mode,
arguments after `--` are passed unchanged to xdbg. Use `--log FILE` for output.

### Recover suspended threads through MCP

If x64dbg becomes `LOCKED` after a breakpoint and its **Run** command cannot
resume the target, use `resume-xdbg-threads.sh` from a separate terminal. We
created it because a Proton breakpoint can leave the debugger, game, and other
debugging tools suspended together; a separate MCP client can still reach
x64dbg and repair that state. It reads the bearer token from the MCP plugin's
local `mcp_config.json`, detects the active x64/x32 server, sends x64dbg's
global `resumeallthreads` command, clears per-thread suspend counts, and sends
**Run/F9** by default. It does not delete breakpoints or terminate the game.

```bash
./resume-xdbg-threads.sh                 # recover and continue (F9)
./resume-xdbg-threads.sh --dry-run       # inspect only
./resume-xdbg-threads.sh --passes 2      # clear nested suspend counts
./resume-xdbg-threads.sh --threads-only  # resume threads, stay paused
```

If it immediately pauses again, an active breakpoint was hit; disable or
adjust that breakpoint before running again.

The MCP plugin must be running inside x64dbg. When the helper is kept beside an
x64dbg release, it finds `mcp_config.json` automatically; otherwise it checks
`~/.local/share/xdbg/release/x64/` and `x32/`. Use `--config FILE` or
`XDBG_MCP_TOKEN`/`XDBG_MCP_URL` for a custom installation. Keep the MCP server
bound to localhost because its token grants full debugger control.

### WinSock test binaries

`examples/winsock-test/` contains a small localhost server and client for
repeatable xdbg tests. We created them so breakpoints can be tested without a
game: both programs call `Ws2_32.dll` directly, making `socket`, `bind`,
`listen`, `accept`, `connect`, `send`, and `recv` easy to find in x32dbg or
x64dbg. Build both architectures with:

```bash
cd examples/winsock-test
./build.sh
```

The output contains `winsock32-*` (PE32 for x32dbg) and `winsock64-*` (PE32+
for x64dbg). Open the server and client with `--launch`, press F9 in the
server first, then press F9 in the client. Use the same private Proton prefix
for both processes; the sample only listens on `127.0.0.1:27015`. See
[`examples/winsock-test/README.md`](examples/winsock-test/README.md) for the
complete commands and breakpoint suggestions.

## How it works

The script recovers Proton, prefix, display and session details, then invokes:

```text
/path/to/Proton/proton runinprefix /path/to/x32dbg.exe
```

Attach mode reuses the game's `wineserver`, so xdbg can see the process. Launch
mode uses the private prefix described above and never asks Steam to create a
game process. In attach mode the script also asks Proton's `winedbg` for the
Windows process list and uses `xdbg -p PID` when one matching game process is
unambiguous. Closing xdbg ends the launcher. The Desktop shortcuts use a
dedicated Konsole without `--hold`; they pause on validation errors so the
message remains visible, while normal successful exits still close the
terminal. Ctrl+C or closing that terminal sends a cleanup signal to Proton.

## Troubleshooting

- **Text looks wrong or dump columns overlap:** `MS Shell Dlg 2` is a Windows
  font alias, and debugger panes may fall back from `Lucida Console` to the
  proportional `Noto Sans` under Proton. In x64dbg, open
  `Options -> Appearance -> Font` and set the **Application** font to
  `DejaVu Sans` (Regular, 9–10 pt). Set
  **Disassembly**, **HexDump**, **Registers**, **Stack**, **AbstractTableView**,
  and **HexEdit** to `DejaVu Sans Mono` (or `Noto Sans Mono`), then restart
  x64dbg. Do not change fonts inside the game's Proton prefix unless needed.
- **No game:** start it in Steam, wait for its main process, or use
  `--start-game`.
- **No automatic Attach detection:** use native Steam and pass `--appid APPID`
  if the running process does not expose `STEAM_COMPAT_DATA_PATH`.
- **Several Attach entries:** the launcher groups Wine processes by AppID, but
  it may find several matching Windows processes. Choose the process whose
  path is the real game executable; `wineserver` and launchers are not targets.
- **Wrong debugger architecture:** use `x32dbg.exe` for PE32 targets and
  `x64dbg.exe` for PE32+ targets. Launch mode rejects a mismatch before Proton
  starts, including when the target is a symlink inside `compatdata/pfx`.
- **"Debugging stopped" or a Steam application-load error:** Steam must create
  the game process. Start it in Steam and use Attach (or `--start-game`); do not
  launch that game's EXE directly from xdbg.
- **Proton not found for a standalone launch:** install a Proton tool, pass
  `--proton "/path/to/Proton"`, or use `--compatdata`/`--prefix` explicitly.
- **GUI errors:** run in Desktop Mode and inspect `--log` output.
