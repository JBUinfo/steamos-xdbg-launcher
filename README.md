# xdbg launcher for SteamOS

`launch-xdbg.sh` runs a sibling `x32dbg.exe` or `x64dbg.exe` through Proton.
It has two modes:

- **Attach:** find a running Steam game's Proton prefix and attach xdbg to it.
- **Launch:** start any Windows `.exe` through xdbg before its entry point;
  no game needs to be running.

## Requirements

- SteamOS Desktop Mode and a complete x64dbg release (keep its DLLs/plugins).
- Use `x32dbg.exe` for 32-bit targets and `x64dbg.exe` for 64-bit targets.
- Attach mode requires native Steam so the game and debugger share `wineserver`.
  Steam Flatpak is rejected.
- Launching an executable inside a Steam library automatically detects its
  AppID, compatdata prefix and Proton version. Non-Steam targets can use an
  existing prefix selected interactively or supplied with `--compatdata`.

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
2) Launch a Windows executable through xdbg
```

Attach detects running Steam games first. If one game is running it is selected
automatically; if several are running, the menu shows one entry per AppID and
the number of Wine processes instead of listing every helper process. The
launcher then queries Wine's process list and automatically passes the matching
Windows PID to xdbg when there is one clear game process. If several game
processes exist, it shows their paths/PIDs so you can choose before xdbg opens.
Launch asks only for the `.exe` path when it is inside a Steam library. For a
non-Steam `.exe`, it shows a prefix chooser. Any CLI flag skips this menu.

### Attach to a running Steam game

Omit `--appid` to detect a running game automatically. If several games are
running, choose one from the grouped list. Pass `--appid` directly when the
process does not expose Steam's compatdata environment or when using
`--start-game`. The ID is in the Steam Store URL (`/app/<id>/`) or in
`steamapps/appmanifest_<id>.acf`.

```bash
./launch-xdbg.sh
./launch-xdbg.sh --appid 123456 --debugger x64dbg.exe
./launch-xdbg.sh --appid 123456 --start-game --wait 120
```

`--start-game` starts the game normally with Steam, then waits for it. The
launcher attempts the same Windows-PID selection after the game starts; if it
cannot identify one process, open **Attach** (`Alt+A`) and select the actual
game executable rather than a launcher/helper.

### Launch before the target runs

For a Steam game, pass only its executable: the launcher matches the path under
`steamapps/common/<installdir>` to `appmanifest_<id>.acf`, then selects
`steamapps/compatdata/<id>` and the Proton version recorded there.

```bash
./launch-xdbg.sh --launch \
  "$HOME/.local/share/Steam/steamapps/common/Game/game.exe"
```

For a non-Steam executable, use an existing Proton prefix. `--compatdata` must
contain `pfx/`; alternatively pass that exact `pfx` directory with `--prefix`.

```bash
./launch-xdbg.sh --launch "/path/to/tool.exe" \
  --compatdata "$HOME/.local/share/Steam/steamapps/compatdata/123456" \
  --proton "$HOME/.local/share/Steam/steamapps/common/Proton 11.0"
```

Optional target arguments and working directory:

```bash
./launch-xdbg.sh --launch "/path/to/tool.exe" \
  --compatdata "/path/to/compatdata/custom" --proton "/path/to/Proton" \
  --target-cmdline 'one two' --target-cwd "/path/to/tool-dir"
```

The launcher passes the working directory with xdbg's `-workingDir` option
and places target arguments after xdbg's `--` separator, so they are not
mistaken for extra xdbg positional arguments.

The target path can be a Linux path or a Wine-style Windows path. A Steam
game may still need its Steam bootstrap; use attach mode plus `--start-game`
for that case. Native Linux programs are not supported by xdbg.

Host-path targets use their containing directory as the default working
directory. Override it with `--target-cwd` when a program needs another one.

`--check` prints the detected prefix without launching. In attach mode,
arguments after `--` are passed unchanged to xdbg. Use `--log FILE` for output.

## How it works

The script recovers Proton, prefix, display and session details, then invokes:

```text
/path/to/Proton/proton runinprefix /path/to/x32dbg.exe
```

This reuses the game's `wineserver`, so Attach can see the process. In attach
mode it also asks Proton's `winedbg` for the Windows process list and uses
`xdbg -p PID` when one matching game process is unambiguous. Closing xdbg ends
the launcher. The Desktop shortcuts use a dedicated Konsole without `--hold`;
they pause on validation errors so the message remains visible, while normal
successful exits still close the terminal. Ctrl+C or closing that terminal
sends a cleanup signal to Proton.

## Troubleshooting

- **No game:** start it in Steam, wait for its main process, or use
  `--start-game`.
- **No automatic Attach detection:** use native Steam and pass `--appid APPID`
  if the running process does not expose `STEAM_COMPAT_DATA_PATH`.
- **Several Attach entries:** the launcher groups Wine processes by AppID, but
  it may find several matching Windows processes. Choose the process whose
  path is the real game executable; `wineserver` and launchers are not targets.
- **Wrong debugger architecture:** use `x32dbg.exe` for PE32 targets and
  `x64dbg.exe` for PE32+ targets. Launch mode rejects a mismatch before Proton
  starts.
- **Steam path not detected:** verify that the executable is below
  `steamapps/common/<installdir>` and that its `appmanifest_<id>.acf` exists;
  otherwise pass `--appid` or `--compatdata` explicitly.
- **Proton not found:** pass `--proton "/path/to/Proton"` explicitly.
- **GUI errors:** run in Desktop Mode and inspect `--log` output.
