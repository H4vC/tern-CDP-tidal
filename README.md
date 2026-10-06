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

The TIDAL desktop app is Electron running TIDAL's web player. The plugin drives that player over the
Chrome DevTools protocol: it reads the player's own state (exact position, quality, shuffle, repeat,
app volume) and sends TIDAL's own playback actions. Changes reach the plugin within milliseconds.

- **No restart needed.** If TIDAL was started with `--remote-debugging-port`, the plugin uses that.
  Otherwise it turns on the Node inspector in TIDAL's running main process (port 9229, local only)
  and drives the page through Electron's `webContents.debugger` from there, so your music keeps
  playing. When the plugin stops, it detaches and closes the inspector again. Port 9229 is also the
  default for debugging Node programs; if another program holds it, the plugin can't use it.
- **Fallback: restart.** If neither works (for instance a TIDAL build that disables the inspector),
  the plugin restarts TIDAL with the port, and if TIDAL was playing it picks up the same track at the
  same spot (read from the OS media session first; on macOS this needs `media-control`, on Linux
  `playerctl`). A restart that doesn't bring remote control up is retried, waiting longer each time
  (up to 5 minutes); **Restart now** in the player skips the wait.
- **Security:** while the plugin controls TIDAL, any program on this machine can too, through the
  DevTools port or the inspector port (both bound to 127.0.0.1 only).
- The bridge (`bridge/bridge.js`) runs on TIDAL's own Electron binary in Node mode
  (`ELECTRON_RUN_AS_NODE=1`); `bridge/tidal-main.js` runs inside TIDAL's main process and
  `bridge/tidal-page.js` inside its page.

| OS | App | Looked up at |
| --- | --- | --- |
| Windows | TIDAL desktop | `%LOCALAPPDATA%\TIDAL\app-<version>\TIDAL.exe` (newest) |
| macOS | TIDAL desktop | `/Applications/TIDAL.app`, `~/Applications/TIDAL.app` |
| Linux | [tidal-hifi](https://github.com/Mastermindzh/tidal-hifi) (TIDAL has no Linux app) | `/opt/tidal-hifi`, `/usr/lib/tidal-hifi`, `/usr/share/tidal-hifi` |

Only Windows has been run so far; macOS and Linux follow the same path but are untested.

## The player

- **Title line:** title, then the artist and album (click either for the artist's top 20 tracks or
  the album's tracks), the stream format (e.g. `24-bit 48 kHz FLAC`, orange when hi-res) and a heart
  to like the track. When the big cover shows, the format sits on its corner instead.
- **Controls:** previous, play/pause, next, shuffle, repeat, track radio, lyrics, sleep timer
  (click to cycle 15 / 30 / 60 minutes / end of track / off), mute and volume.
- **Progress bar:** click anywhere on it to seek.
- **Under the player**, in whatever height the block has (docked or floating and focused): the
  queue, or the lyrics. The queue shows a couple of played tracks, the current one highlighted and
  what comes next; click a line to play it, hover for ↑ ↓ ✕ to move or drop it, or **link** to copy
  the track's share address (tidal.com/track/…). Synced lyrics follow the song; click a line to
  jump there.
- **Floating and not focused:** just the cover with the title, artist and stream format on it,
  filling the card. A card too small for that shows a compact preview (title, artist · album, the
  timeline and what plays next).
- **Big cover:** the album cover shows at the largest size that fits (up to 640 px), scaling smoothly
  as you resize the block, with the title and heart, artist, album, controls and progress bar over
  its lower part on a dark fade. The cover shrinks to keep at least 3 queue entries in view below
  it; a block too small for a 160 px cover that way keeps the compact layout. A docked block wider
  than the cover centres it all in a column as wide as the cover. Colours follow your Tern theme.
- **Stream format badge** on the cover's top corner: on the panel colour, or on the accent when the
  cover's corner is as light (or as dark) as the panel, so it always stands out.

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
`Ctrl+Enter` or **+queue** adds it to the end, and **link** copies the item's share address. Artist
and album lists work the same way, with **play all** and, for an artist, **radio**. `Esc` closes.
Lookups run inside TIDAL with its own sign-in. (Tern gives plugin blocks no right-click menu, so
the actions are hover buttons.)

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
