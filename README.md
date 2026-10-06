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
  the album's tracks), the stream quality as an icon (— low, ∿ high, shield lossless, bolt hi-res in
  the accent; the help panel names them and shows the exact format) and a heart to like the track.
  When the big cover shows, the quality icon sits on its corner instead.
- **Controls:** previous, play/pause, next, shuffle, repeat, track radio, Daily Discovery, lyrics,
  sleep timer (opens a row of choices: 15 / 30 / 60 min, end of track, off), mute and volume (click
  the number to step through 10 / 25 / 50), search, and **?** help.
- **Help** (`?` or the help button): what every button does, the keys, and the quality icons.
- **Progress bar:** click anywhere on it to seek (also the line along the top of a focused floating
  card's cover).
- **Daily Discovery:** the ✦ button (or **Daily Discovery** when nothing is playing) plays your "My
  Daily Discovery" mix after the song that's playing. By default, when nothing is queued after the
  current song (one you picked on its own, or the end of a list) and repeat is off, Daily Discovery
  is queued after it so playback carries on, and the player says so; the palette turns that off.
- **What's playing now** is always the accent colour: its line in the queue (with a level meter),
  the synced lyric being sung, the radio button while a track radio plays, ✦ while Daily Discovery
  does, **play all** / **radio** in an album or artist list while the queue plays it, and the album,
  playlist or artist in search results. The search selection is a neutral band.
- **Under the player**, in whatever height the block has: the queue, or the lyrics (per player, so a
  docked and a floating player can differ). The queue shows a couple of played tracks, then what
  comes next; click a line to play it, hover for **next** (play right after this song), ↑ ↓ ✕ to
  move or drop it, or **link** to copy its share address (tidal.com/track/…). Long lines end in "…".
  Synced lyrics follow the song and a click jumps there; plain lyrics say "not synced" and can't
  be clicked. On a floating card with the big cover, lyrics play over the cover instead.
- **Floating and not focused:** the cover (at the card's left, up to 320 px) with the title, artist
  and quality on it, a thin progress line along its top, and the queue in any rows left below; the
  palette switches to cover only (the cover fills the card). A card too small for that shows a
  compact preview: a small cover, title, artist and a thin progress line.
- **Big cover:** the album cover shows at the largest size that fits (up to 640 px docked and 320 px
  on a floating card, and never wider than a quarter of the Tern window), scaling smoothly as you
  resize the block, with the title and heart, artist, album, controls and progress bar over its
  lower part on a dark fade (darker on light covers). Stacked, the cover shrinks to keep at least 3
  queue entries below it. A docked block wide enough puts the cover on the left at full height and
  the queue or lyrics beside it. The list clips whatever doesn't fit. Colours follow your Tern theme.
- **Quality icon** on the cover's top corner sits on a solid square, switched to the accent when the
  cover's corner is as light (or as dark) as the panel, so it always stands out.
- **Errors** from TIDAL stay under the player until you dismiss them (✕) or the next command works.

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
| `t` | Sleep timer choices |
| `o` | Open TIDAL |
| `/`, `f` | Search |
| `?` | Help |
| `Esc` | Close search, help or the sleep choices |

Focusing the player opens search, so letters type into it (the search line says so); `Esc` closes
it and the letter keys above work again. Space, `?`, the arrows and the number keys work either way.

**Search** opens under the player: type, and results (tracks, albums, artists, playlists) list one
per line from the third letter. `↑` `↓` pick; `Enter` or a click plays (replacing the queue, as
playing from TIDAL's own search does), `Shift+Enter` or **next** plays it after the current track,
`Ctrl+Enter` or **+queue** adds it to the end, and **link** copies the item's share address. Artist
and album lists work the same way, with **play all** and, for an artist, **radio**. `Esc` closes.
Lookups run inside TIDAL with its own sign-in. (Tern gives plugin blocks no right-click menu, so
the actions are hover buttons.)

**Palette:** Open player, Play/Pause, Next / Previous track, Like, Track radio, Play My Daily
Discovery, Artist radio, Toggle shuffle, Cycle repeat, Mute, Sleep in 15 / 30 / 60 minutes, Sleep at
the end of this track, Cancel the sleep timer, Show lyrics / queue (the focused player, else all),
Toggle track-change notifications (a toast when the track changes while the player isn't focused;
off by default), Floating card when not focused: cover only / cover + queue, and Toggle queuing
Daily Discovery when nothing follows. Clicking the status line segment opens the player.

## Internals

Tern plugins can only run processes to completion, so the bridge is a long-running process the
plugin starts and that exits 30 s after the plugin stops checking in; only one runs per machine,
however many Tern windows start one. They talk through files in the plugin's data directory: the
bridge writes `now.json` on every change, the plugin drops commands into `inbox/`, and lookups answer
in `search.json` and `lyrics.json`. The protocol is documented at the top of `src/link.luau`.
Problems land in `bridge.log` there; `tern plugin list` shows whether the plugin loaded.
