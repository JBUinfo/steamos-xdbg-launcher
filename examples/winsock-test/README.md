# WinSock xdbg fixture

This is a tiny localhost TCP pair for testing x32dbg/x64dbg under Proton. The
programs call `Ws2_32.dll` directly instead of using Go's high-level `net`
package, so breakpoints on `socket`, `bind`, `listen`, `accept`, `connect`,
`send`, and `recv` are easy to reproduce.

## Build

From this directory:

```bash
./build.sh
```

It creates four small Windows binaries in `bin/`:

- `winsock32-server.exe` and `winsock32-client.exe` for **x32dbg** (PE32).
- `winsock64-server.exe` and `winsock64-client.exe` for **x64dbg** (PE32+).

The binaries are generated with `GOOS=windows`, `GOARCH=386/amd64`, and
`CGO_ENABLED=0`; no MinGW installation is needed.

## Run under xdbg

Set the launcher path to the script beside the matching xdbg release:

```bash
XDBG_LAUNCHER=/path/to/xdbg/x32/launch-xdbg.sh

# Terminal 1: open the server paused, set breakpoints, then press F9.
"$XDBG_LAUNCHER" --launch "$PWD/bin/winsock32-server.exe"

# Terminal 2: open the client paused, then press F9 to connect.
"$XDBG_LAUNCHER" --launch "$PWD/bin/winsock32-client.exe"
```

Use `/path/to/xdbg/x64/launch-xdbg.sh` and the `64` binaries with the x64
debugger. The standalone launch
mode uses the private Proton prefix described in the root README, so both
processes must use the same prefix. The server listens only on
`127.0.0.1:27015`; add `-port 27016` to both programs if that port is busy.

The server prints the received message and replies with
`pong from winsock server`. Pass arguments through the launcher's
`--target-cmdline` option; for example, to serve one client:

```bash
"$XDBG_LAUNCHER" --launch "$PWD/bin/winsock32-server.exe" \
  --target-cmdline "-once"
"$XDBG_LAUNCHER" --launch "$PWD/bin/winsock32-client.exe" \
  --target-cmdline '-message "hello from xdbg"'
```

Useful breakpoints include `Ws2_32!accept`, `Ws2_32!recv`, `Ws2_32!send`, and
the `main`/`serve` code in the sample. This fixture is local-only and is not a
game or a network scanner.
