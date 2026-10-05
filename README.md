# TIDAL for Tern

Now playing and playback controls for the TIDAL desktop app inside [Tern](https://stencil.so/tern):
a two-line player block with cover art, palette commands, and the current track in the status line.
No login and nothing to install; it drives the TIDAL app already on your machine.

## Install

```sh
tern plugin install https://github.com/H4vC/tern-CDP-tidal
```

Run **TIDAL: Open player** from the command palette. It opens as a picture in picture; dock it like
any block. For development, `tern plugin link /path/to/tern-CDP-tidal`.

## How it talks to TIDAL

The TIDAL desktop app is Electron running TIDAL's web player. The plugin starts TIDAL with
`--remote-debugging-port` and drives that player over the Chrome DevTools protocol: it reads the
player's own state (exact position, quality, shuffle, repeat, app volume) and sends TIDAL's own
playback actions. Changes reach the plugin within milliseconds.

- **TIDAL must run with remote control.** When the plugin finds TIDAL running without it, it
  restarts TIDAL that way by itself, and if TIDAL was playing it picks up the same track at the same
  spot (read from the OS media session first; on macOS this needs `media-control`, on Linux
  `playerctl`). If the restart doesn't bring remote control up, the player offers
  **Restart TIDAL**. Adding `--remote-debugging-port=0` to your TIDAL shortcut avoids the restart.
- **Security:** while TIDAL runs with remote control, any program on this machine can control TIDAL
  and read its session through the DevTools port (bound to 127.0.0.1 only).
- The bridge (`bridge/bridge.js`) runs on TIDAL's own Electron binary in Node mode
  (`ELECTRON_RUN_AS_NODE=1`); `bridge/tidal-page.js` runs inside TIDAL's page.

| OS | App | Looked up at |
| --- | --- | --- |
| Windows | TIDAL desktop | `%LOCALAPPDATA%\TIDAL\app-<version>\TIDAL.exe` (newest) |
| macOS | TIDAL desktop | `/Applications/TIDAL.app`, `~/Applications/TIDAL.app` |
| Linux | [tidal-hifi](https://github.com/Mastermindzh/tidal-hifi) (TIDAL has no Linux app) | `/opt/tidal-hifi`, `/usr/lib/tidal-hifi`, `/usr/share/tidal-hifi` |

## Controls

| Key | Action |
| --- | --- |
| `space`, `k` | Play / pause |
| `←` `→` | Back / forward 10 s |
| `0`–`9` | Jump to 0–90 % |
| `n` `p` | Next / previous track |
| `s` `r` | Shuffle / cycle repeat (off → all → one) |
| `+` `-`, `↑` `↓` | TIDAL's volume ±5 % (±1 % below 10 %) |
| `m` | Mute |
| `o` | Open TIDAL |
| `/`, `f` | Search |

**Search** opens under the player: type, and results (tracks, albums, artists, playlists) list one
per line as you pause. `↑` `↓` pick, `Enter` or a click plays it (replacing the queue, as playing from
TIDAL's own search does), `Esc` closes. The search runs inside TIDAL with its own sign-in.

Palette: **TIDAL: Open player**, **Play/Pause**, **Next track**, **Previous track**. Clicking the
status line segment opens the player.

## Internals

Tern plugins can only run processes to completion, so the bridge is a long-running process the
plugin starts and that exits 30 s after the plugin stops checking in. They talk through files in the
plugin's data directory: the bridge writes `now.json` on every change, the plugin drops commands into
`inbox/`. The protocol is documented at the top of `src/link.luau`. Problems land in `bridge.log`
there; `tern plugin list` shows whether the plugin loaded.
