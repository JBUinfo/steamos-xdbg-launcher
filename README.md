# xdbg launcher for SteamOS

`launch-xdbg.sh` starts a sibling `x32dbg.exe`/`x64dbg.exe` through the same
native Steam Proton prefix as a running game. xdbg can then see the game in
`Attach` (`Alt+A`). It uses Proton's `runinprefix`; Protontricks is not needed.

The AppID selects the correct `compatdata/<id>` prefix and `wineserver`; the
executable name alone is not enough when several games are installed or
running. If you omit it, the script lists installed apps and asks you to
choose one (use `--appid` for automation).

## Requirements

- SteamOS native Steam (the usual `/home/deck/.local/share/Steam` install).
  Steam Flatpak is rejected because its `wineserver` socket is isolated.
- The game installed with Proton, and the complete x64dbg release (not just
  the `.exe`; keep its DLLs/plugins/data in the original layout).
- A debugger with the game's bitness: `x32dbg.exe` for 32-bit, `x64dbg.exe`
  for 64-bit.

The script does not alter game files or bypass anti-cheat. Debugging can make a
game or the desktop unstable; use an offline/test setup when appropriate.

## Install

Put the script next to the debugger you want to run:

```text
x32/
  launch-xdbg.sh
  x32dbg.exe
  ...other x64dbg files...
```

```bash
chmod +x launch-xdbg.sh
```

Keep x64dbg's original release layout intact; copy only this script beside the
selected executable.

With exactly one sibling (`x32dbg.exe` or `x64dbg.exe`) it is auto-selected.
If both exist, pass `--debugger`.

## Use

Find the AppID in the game's Steam Store URL (`/app/<id>/`) or in
`steamapps/appmanifest_<id>.acf`. Launch the game first,
then either select it interactively:

```bash
./launch-xdbg.sh
```

or pass its AppID directly:

```bash
./launch-xdbg.sh --appid 123456
```

Other common forms:

```bash
./launch-xdbg.sh 123456 --debugger x32dbg.exe
./launch-xdbg.sh --appid 123456 --debugger x64dbg.exe --start-game --wait 120
./launch-xdbg.sh --appid 123456 --log ./logs/game.log
./launch-xdbg.sh --check --appid 123456
```

Everything after `--` is passed unchanged to xdbg:

```bash
./launch-xdbg.sh --appid 123456 -- <xdbg-arguments>
```

`--appid` may be supplied as `XDBG_APPID`; Proton and Steam roots can be
overridden with `--proton PATH`, `--steam-root PATH`, `XDBG_PROTON_PATH`, and
`XDBG_STEAM_ROOT`.

## What it does

1. Finds the AppID's live Proton process and reads its compatdata, prefix and
   Proton path from `/proc` (falling back to `config_info`).
2. Recovers the current user's X11/Wayland environment so the GUI can open.
3. Runs:

   ```text
   /path/to/Proton/proton runinprefix /path/to/x32dbg.exe
   ```

4. Reports the `wineserver` count before/after launch. A new server usually
   means the debugger is isolated and will not list the game.

In xdbg, choose `Attach`/`Alt+A` and select the Windows process. Its Windows
PID is not the same as the Linux PID printed by the script.

## Troubleshooting

- **Game not found:** start it in Steam, wait for its main process, then retry;
  or use `--start-game`.
- **Empty Attach list:** use native Steam, do not run xdbg with `flatpak run`,
  and match x32/x64 to the game. Run `--check` and inspect the prefix/server
  diagnostics.
- **Proton not found:** pass a Proton directory, e.g.
  `--proton "/home/deck/.local/share/Steam/steamapps/common/Proton 11.0"`.
- **GUI errors:** run from SteamOS Desktop Mode and use `--log` for Wine/Qt
  output.
