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
- Launch mode needs a Proton compatdata directory and Proton path when no
  Steam AppID is supplied.

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

### Attach to a running Steam game

Omit `--appid` for a live list of installed Steam apps, or pass it directly.
The ID is in the Steam Store URL (`/app/<id>/`) or in
`steamapps/appmanifest_<id>.acf`.

```bash
./launch-xdbg.sh
./launch-xdbg.sh --appid 123456 --debugger x64dbg.exe
./launch-xdbg.sh --appid 123456 --start-game --wait 120
```

`--start-game` starts the game normally with Steam, then waits for it. In xdbg,
open **Attach** (`Alt+A`) and select the Windows process.

### Launch before the target runs

Use an existing Proton prefix. `--compatdata` must contain `pfx/`; alternatively
pass that exact `pfx` directory with `--prefix`.

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

The target path can be a Linux path or a Wine-style Windows path. A Steam
game may still need its Steam bootstrap; use attach mode plus `--start-game`
for that case. Native Linux programs are not supported by xdbg.

`--check` prints the detected prefix without launching. In attach mode,
arguments after `--` are passed unchanged to xdbg. Use `--log FILE` for output.

## How it works

The script recovers Proton, prefix, display and session details, then invokes:

```text
/path/to/Proton/proton runinprefix /path/to/x32dbg.exe
```

This reuses the game's `wineserver`, so Attach can see the process. Closing xdbg
ends the launcher. The Desktop shortcuts use a dedicated Konsole without
`--hold`; Ctrl+C or closing that terminal sends a cleanup signal to Proton.

## Troubleshooting

- **No game:** start it in Steam, wait for its main process, or use
  `--start-game`.
- **Empty Attach list:** use native Steam, the matching x32/x64 debugger, and
  run `--check` to inspect the prefix/server diagnostics.
- **Proton not found:** pass `--proton "/path/to/Proton"` explicitly.
- **GUI errors:** run in Desktop Mode and inspect `--log` output.
