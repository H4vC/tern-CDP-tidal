# TIDAL for Tern

Now playing and playback controls for the TIDAL desktop app inside [Tern](https://stencil.so/tern):
a compact player block with cover art, the queue or synced lyrics, search, artist and album lists,
palette commands, and the current track in the status line. No login and nothing to install; it
drives the TIDAL app already on your machine.

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

Only Windows has been run so far; macOS and Linux follow the same path but are untested.

## The player

- **Title line:** title, then the artist and album (click either for the artist's top 20 tracks or
  the album's tracks), the stream quality (LOSSLESS / HI-RES) and a heart to like the track.
- **Controls:** previous, play/pause, next, shuffle, repeat, track radio, lyrics, sleep timer
  (click to cycle 15 / 30 / 60 minutes / end of track / off), mute and volume.
- **Progress bar:** click anywhere on it to seek.
- **Under the player**, in whatever height the block has (docked or floating and focused): the
  queue, or the lyrics. The queue shows a couple of played tracks, the current one highlighted and
  what comes next; click a line to play it, hover for ↑ ↓ ✕ to move or drop it. Synced lyrics follow
  the song; click a line to jump there.
- **Floating and not focused:** a preview with play controls, artist · album, the timeline, the
  stream format and what plays next, then as many upcoming tracks as the card has room for.
- Docked, the album cover sits faintly behind the player; colours follow your Tern theme.

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
| `l` | Like / unlike |
| `y` | Lyrics / queue |
| `a` `b` | The artist's top tracks / the album's tracks |
| `t` | Sleep timer |
| `o` | Open TIDAL |
| `/`, `f` | Search |

Focusing the player opens search, so letters type into it; `Esc` closes it and the letter keys above
work again. Space, the arrows and the number keys work either way.

**Search** opens under the player: type, and results (tracks, albums, artists, playlists) list one
per line from the third letter. `↑` `↓` pick; `Enter` or a click plays (replacing the queue, as
playing from TIDAL's own search does), `Shift+Enter` or **next** plays it after the current track,
`Ctrl+Enter` or **+queue** adds it to the end. Artist and album lists work the same way, with
**play all** and, for an artist, **radio**. `Esc` closes. Lookups run inside TIDAL with its own
sign-in.

**Palette:** Open player, Play/Pause, Next / Previous track, Like, Track radio, Artist radio,
Toggle shuffle, Cycle repeat, Mute, Sleep in 15 / 30 / 60 minutes, Sleep at the end of this track,
Cancel the sleep timer, Show lyrics / queue, and Toggle track-change notifications (a toast when the
track changes while the player isn't focused; off by default). Clicking the status line segment
opens the player.

## Internals

Tern plugins can only run processes to completion, so the bridge is a long-running process the
plugin starts and that exits 30 s after the plugin stops checking in; only one runs per machine,
however many Tern windows start one. They talk through files in the plugin's data directory: the
bridge writes `now.json` on every change, the plugin drops commands into `inbox/`, and lookups answer
in `search.json` and `lyrics.json`. The protocol is documented at the top of `src/link.luau`.
Problems land in `bridge.log` there; `tern plugin list` shows whether the plugin loaded.
