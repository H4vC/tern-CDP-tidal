--!strict
-- The player block: renders the bridge's snapshot and turns clicks and keys into commands.

local link = require("./link")
local search = require("./search")
local ui = tern.ui

type Snapshot = link.Snapshot

-- The bridge publishes within milliseconds of a change; the tick is what bounds the view's lag.
local TICK_MS = 100
local SEEK_STEP_MS = 10000
local VOLUME_STEP = 5
-- Below this level a 5 % step is a large jump in loudness, so steps shrink to 1 %.
local FINE_VOLUME_BELOW = 10
-- How long a control shows the state it asked for before the snapshot must agree.
local EXPECT_MS = 2500
local NOTICE_MS = 4000

type Block = {
   cx: BlockCx,
   -- The cover sent to this pane, as the blob Tern gave back.
   cover_key: string?,
   blob: string?,
   signature: string,
   -- Open while searching.
   search: search.State?,
   -- The TIDAL mark (icons/tidal.svg) as this pane's blob: Tern's own chrome only takes built-in icon names.
   mark: string?,
   -- Floating while another block has focus: shows the preview (see `glance_view`).
   glance: boolean,
   -- Whether the pane had focus at the last tick, to open search when it gains it.
   focused: boolean,
   -- Floating (picture in picture); a docked player also lists the queue.
   floating: boolean,
   -- Showing the help panel (`?`) instead of the queue or lyrics.
   help: boolean,
   -- The sleep timer's choices are open under the controls.
   sleep_menu: boolean,
   -- The last error TIDAL gave this pane's commands, shown until dismissed or the next success.
   problem: string?,
}

-- Blocks have no close hook; the tick drops panes that are gone.
local blocks: { [number]: Block } = {}
local snap: Snapshot? = nil
local bridge_problem: string? = nil
local ticking = false

-- The position the view extrapolates from, re-anchored whenever the bridge reports a jump.
local anchor = { timeline = -1, pos = 0, at = 0 }

local cover: { key: string?, bytes: string?, mime: string?, loading: string? } = {}
local expected: { [string]: { value: any, expires: number } } = {}
local notice: { text: string, expires: number }? = nil
-- Command id → the pane that sent it, to show the bridge's answer there.
local senders: { [string]: number } = {}
local answered: string? = nil

-- The current track's lyrics, fetched once per track while lyrics are shown. `lines` are synced
-- (`ms` from the start), `text` is plain.
type Lyrics = { track: string, waiting: string?, lines: { { ms: number, text: string } }?, text: string?, error: string? }
local lyrics: Lyrics? = nil
local LYRICS_FILE = tern.plugin.data .. (if tern.runtime.os == "windows" then "\\" else "/") .. "lyrics.json"

-- State ---------------------------------------------------------------------------------------

-- A field as the view should show it: what a control just asked for until the bridge agrees.
local function shown(field: string, actual: any): any
   local want = expected[field]
   if want == nil then
      return actual
   end
   if want.value == actual or tern.now() > want.expires then
      expected[field] = nil
      return actual
   end
   return want.value
end

local function expect(field: string, value: any)
   expected[field] = { value = value, expires = tern.now() + EXPECT_MS }
end

local function playing(): boolean
   return shown("playing", snap ~= nil and snap.playing) == true
end

local function position(): number
   local s = snap
   if s == nil or s.track == nil then
      return 0
   end
   local pos = anchor.pos
   if playing() then
      pos += tern.now() - anchor.at
   end
   local length = s.track.length_ms
   if length then
      pos = math.min(pos, length)
   end
   return math.max(0, pos)
end

local function reanchor(pos: number)
   anchor = { timeline = anchor.timeline, pos = pos, at = tern.now() }
end

local function say(text: string)
   notice = { text = text, expires = tern.now() + NOTICE_MS }
end

local function sniff(bytes: string, header: string?): string
   if header and string.match(header, "^image/") then
      return (string.match(header, "^[^;%s]+") :: string)
   end
   if string.sub(bytes, 1, 2) == "\xFF\xD8" then
      return "image/jpeg"
   end
   return "image/png"
end

local function load_cover(s: Snapshot)
   local c = s.cover
   if c == nil then
      cover = {}
      return
   end
   if c.key == cover.key or c.key == cover.loading then
      return
   end
   if c.file then
      local ok, bytes = pcall(tern.fs.read, c.file, 8 * 1024 * 1024)
      if ok then
         cover = { key = c.key, bytes = bytes, mime = sniff(bytes, nil) }
      end
   elseif c.url then
      local key = c.key
      cover.loading = key
      tern.fetch(c.url, { timeout_ms = 15000 }, function(result: FetchResult)
         if cover.loading ~= key then
            return
         end
         cover.loading = nil
         if result.error == nil and result.status == 200 then
            cover = { key = key, bytes = result.body, mime = sniff(result.body, result.headers["content-type"]) }
            for _, block in blocks do
               block.signature = ""
            end
         end
      end)
   end
end

local function take_reply(s: Snapshot)
   local reply = s.reply
   if reply == nil or reply.id == answered then
      return
   end
   answered = reply.id
   local pane = senders[reply.id]
   senders[reply.id] = nil
   if pane then
      expected = if reply.error then {} else expected
      local block = blocks[pane]
      if block then
         -- Errors stay in the player until dismissed (or the next command works).
         block.problem = reply.error
         block.signature = ""
      end
   end
end

-- Commands --------------------------------------------------------------------------------------

local function send(block: Block, op: string, arg: (string | number)?): string
   local id = link.send(op, arg)
   senders[id] = block.cx.pane
   return id
end

local function toggle(block: Block)
   local s = snap
   if s == nil or not s.app then
      send(block, "launch")
      return
   end
   if not s.can.toggle then
      return
   end
   reanchor(position())
   expect("playing", not playing())
   send(block, "toggle")
end

local function seek(block: Block, ms: number)
   local s = snap
   if s == nil or s.track == nil or not s.can.seek then
      return
   end
   local length = s.track.length_ms
   ms = math.max(0, if length then math.min(ms, length) else ms)
   reanchor(ms)
   send(block, "seek", math.floor(ms))
end

local function shuffle(block: Block)
   local s = snap
   if s == nil or not s.can.shuffle then
      say("TIDAL doesn't offer shuffle here")
      return
   end
   local on = not shown("shuffle", s.shuffle)
   expect("shuffle", on)
   send(block, "shuffle", if on then "on" else "off")
end

local NEXT_REPEAT = { off = "all", all = "one", one = "off" }

local function cycle_repeat(block: Block)
   local s = snap
   if s == nil or not s.can["repeat"] then
      say("TIDAL doesn't offer repeat here")
      return
   end
   local mode = NEXT_REPEAT[shown("repeat", s["repeat"]) or "off"] or "off"
   expect("repeat", mode)
   send(block, "repeat", mode)
end

local function no_volume(): string
   return "Nothing is playing in TIDAL"
end

local function set_volume(block: Block, level: number)
   local s = snap
   if s == nil or not s.can.volume then
      say(no_volume())
      return
   end
   level = math.clamp(math.floor(level + 0.5), 0, 100)
   if shown("muted", s.muted) then
      expect("muted", false)
      send(block, "mute", "off")
   end
   expect("volume", level)
   send(block, "volume", level)
end

local function toggle_mute(block: Block)
   local s = snap
   if s == nil or not s.can.volume then
      say(no_volume())
      return
   end
   local on = not shown("muted", s.muted)
   expect("muted", on)
   send(block, "mute", if on then "on" else "off")
end

local function like(block: Block)
   local s = snap
   if s == nil or s.track == nil then
      return
   end
   local liked = not shown("liked", s.track.liked)
   expect("liked", liked)
   send(block, "like")
   say(if liked then "Added to your collection" else "Removed from your collection")
end

local function open_list(block: Block, kind: string, id: string?)
   if id == nil then
      say("TIDAL didn't say which " .. kind .. " this is")
      return
   end
   block.search = search.open_list(block.search, kind, id, function(op, arg)
      return send(block, op, arg)
   end)
end

-- The sleep timer's choices (minutes, or the end of this track), as the menu under the controls
-- offers them.
local SLEEP_CHOICES = { "15", "30", "60", "track", "off" }

local function set_sleep(block: Block, choice: string)
   block.sleep_menu = false
   send(block, "sleep", choice)
   say(if choice == "off" then "Sleep timer off"
      elseif choice == "track" then "Pausing at the end of this track"
      else "Pausing in " .. choice .. " minutes")
end

-- Clicking the volume number steps through these levels (the next one above the current, then
-- back to the first).
local VOLUME_PRESETS = { 10, 25, 50 }

local function volume_preset(block: Block)
   local level = shown("volume", snap and snap.volume) or 0
   local target = VOLUME_PRESETS[1]
   for _, preset in VOLUME_PRESETS do
      if preset > level then
         target = preset
         break
      end
   end
   set_volume(block, target)
end

local function lyrics_on(block: Block): boolean
   return link.setting(link.lyrics_key(block.cx.pane))
end

local function act(block: Block, name: string)
   if name == "playpause" then
      toggle(block)
   elseif name == "next" or name == "prev" or name == "radio" or name == "discovery" then
      send(block, name)
   elseif name == "back" then
      seek(block, position() - SEEK_STEP_MS)
   elseif name == "forward" then
      seek(block, position() + SEEK_STEP_MS)
   elseif name == "shuffle" then
      shuffle(block)
   elseif name == "repeat" then
      cycle_repeat(block)
   elseif name == "mute" then
      toggle_mute(block)
   elseif name == "louder" or name == "quieter" then
      local level = shown("volume", snap and snap.volume) or 0
      local louder = name == "louder"
      local step = if (if louder then level < FINE_VOLUME_BELOW else level <= FINE_VOLUME_BELOW) then 1 else VOLUME_STEP
      set_volume(block, level + (if louder then step else -step))
   elseif name == "like" then
      like(block)
   elseif name == "lyrics" then
      link.set_setting(link.lyrics_key(block.cx.pane), not lyrics_on(block))
      block.help = false
   elseif name == "sleep" then
      block.sleep_menu = not block.sleep_menu
   elseif name == "help" then
      block.help = not block.help
   elseif name == "volpreset" then
      volume_preset(block)
   elseif name == "dismiss" then
      block.problem = nil
   elseif name == "artist" then
      open_list(block, "artist", snap and snap.track and snap.track.artist_id)
   elseif name == "album" then
      open_list(block, "album", snap and snap.track and snap.track.album_id)
   elseif name == "playall" or name == "artistradio" then
      local list = block.search and block.search.list
      if list then
         if name == "playall" then
            send(block, "play", list.kind .. " " .. list.id)
         else
            send(block, "artist-radio", list.id)
         end
         block.search = nil
      end
   elseif name == "closesearch" then
      block.search = nil
   elseif name == "launch" or name == "relaunch" then
      send(block, name)
   elseif name == "search" then
      block.search = block.search or search.open()
   elseif name == "retry" then
      link.retry()
      bridge_problem = link.ensure(link.read())
   end
end

-- Plays a search or list item, or puts it in the queue.
local function pick(block: Block, choice: search.Pick)
   local item = choice.item
   send(block, choice.op, item.kind .. " " .. item.id)
   if choice.op == "play" then
      block.search = nil
   else
      say((if choice.op == "queue-next" then "Plays next: " else "Added to the queue: ") .. item.title)
   end
end

-- View ------------------------------------------------------------------------------------------

local function with(node: Node, props: { [string]: any }): Node
   local p: { [string]: any } = node.p or {}
   for k, v in props do
      p[k] = v
   end
   node.p = p
   return node
end

local function button(key: string, icon: string, action: string, enabled: boolean, lit: boolean?): Node
   local props: { [string]: any } = {
      key = key,
      role = if key == "playpause" then "tidal-button tidal-button-main" else "tidal-button",
      tone = if not enabled then "muted" elseif lit then "accent" else nil,
   }
   if enabled then
      props.actions = { click = action }
   end
   return with(ui.row({ ui.node("icon", { name = icon }) }), props)
end

local function link_button(key: string, label: string, action: string): Node
   return with(ui.badge(label, "accent"), { key = key, role = "tidal-link", actions = { click = action } })
end

local MARK_SVG: string? = (function()
   local ok, svg = pcall(tern.fs.read, "icons/tidal.svg", 16 * 1024)
   return if ok then svg else nil
end)()

local function mark_node(block: Block, key: string): Node?
   if block.mark == nil and MARK_SVG then
      block.mark = block.cx:blob(MARK_SVG :: string, "image/svg+xml")
   end
   if block.mark == nil then
      return nil
   end
   return with(ui.node("image", { blob = block.mark, alt = "TIDAL" }), { key = key, role = "tidal-mark" })
end

local function message(block: Block, title: string, body: string, buttons: { Node }, tone: string?): Node
   local children: { Node } = {}
   local mark = mark_node(block, "mark")
   if mark then
      table.insert(children, mark)
   end
   table.insert(children, with(ui.text({ ui.span(title, "strong"), ui.span("  " .. body, "muted") }), { key = "text", role = "tidal-line" }))
   for _, b in buttons do
      table.insert(children, b)
   end
   return with(ui.row(children), { key = "message", role = "tidal-message", tone = tone })
end

local function cover_node(block: Block, s: Snapshot): Node
   -- The previous track's cover stays until the new one arrives (the tick swaps `blob` then), so
   -- the layout doesn't jump on every track change.
   if block.blob and s.cover then
      return with(ui.node("image", { blob = block.blob, alt = (s.track :: link.Track).album }), {
         key = "cover",
         role = "tidal-cover",
      })
   end
   local mark = mark_node(block, "cover")
   if mark then
      return with(ui.row({ mark }), { key = "cover", role = "tidal-cover tidal-cover-empty" })
   end
   return with(ui.row({ ui.node("icon", { name = "wave" }) }), { key = "cover", role = "tidal-cover tidal-cover-empty" })
end

-- A progress bar you can click to seek: Tern's progress node doesn't say where it was clicked, so
-- the bar is a row of thin cells, each seeking to its own point. One cell per two columns keeps the
-- re-render each second cheap and is still finer than a click.
local SEEK_CELLS_MAX = 80

local function seek_cells(block: Block): number
   return math.clamp((block.cx.cols - 24) // 2, 16, SEEK_CELLS_MAX)
end

-- `role` places it: the timeline, or along the top of a floating card's cover.
local function seek_bar(block: Block, s: Snapshot, fraction: number, role: string?): Node
   local count = seek_cells(block)
   local lit = math.floor(fraction * count + 0.5)
   local cells: { Node } = table.create(count)
   for i = 1, count do
      local props: { [string]: any } = { key = i, role = "tidal-seek-cell" }
      if s.can.seek then
         props.actions = { click = "seekto=" .. tostring(i) }
      end
      cells[i] = with(ui.row({
         with(ui.text(""), { role = "tidal-seek-line", tone = if i <= lit then "accent" else nil }),
      }), props)
   end
   return with(ui.row(cells), { key = "bar", role = "tidal-seek" .. (if role then " " .. role else "") })
end

-- The stream quality as an icon, one per level (the help panel says which is which); hi-res in the
-- accent colour.
local QUALITY_ICON = {
   LOW = "minus",
   HIGH = "wave",
   LOSSLESS = "shield",
   HI_RES = "bolt",
   HI_RES_LOSSLESS = "bolt",
}
local QUALITY_NAME = {
   LOW = "Low (lossy)",
   HIGH = "High (lossy)",
   LOSSLESS = "Lossless (CD quality)",
   HI_RES = "Hi-res (MQA)",
   HI_RES_LOSSLESS = "Hi-res lossless",
}

local function quality_icon(s: Snapshot, role: string): Node?
   local icon = s.quality and QUALITY_ICON[s.quality]
   if icon == nil then
      return nil
   end
   local hires = s.quality == "HI_RES_LOSSLESS" or s.quality == "HI_RES"
   return with(ui.row({ ui.node("icon", { name = icon }) }), {
      key = "quality",
      role = role,
      tone = if hires then "accent" else nil,
   })
end

-- Title, then artist and album you can click for their track lists, the stream quality (unless it
-- sits on the big cover) and the heart.
local function heading(block: Block, s: Snapshot, big: boolean): Node
   local track = s.track :: link.Track
   local parts: { Node } = {
      mark_node(block, "mark") or ui.text(""),
      with(ui.text({ ui.span(track.title, "strong") }), { key = "title", role = "tidal-line tidal-title" }),
   }
   if track.artist ~= "" then
      table.insert(parts, with(ui.text({ ui.span("· " .. track.artist, "muted") }), {
         key = "artist",
         role = "tidal-name",
         actions = if track.artist_id then { click = "artist" } else nil,
      }))
   end
   if track.album ~= "" then
      table.insert(parts, with(ui.text({ ui.span("· " .. track.album, "dim") }), {
         key = "album",
         role = "tidal-name tidal-album",
         actions = if track.album_id then { click = "album" } else nil,
      }))
   end
   local badge = if big then nil else quality_icon(s, "tidal-quality")
   if badge then
      table.insert(parts, badge)
   end
   local liked = shown("liked", track.liked) == true
   table.insert(parts, with(ui.text({ ui.span(if liked then "♥" else "♡") }), {
      key = "like",
      role = "tidal-heart",
      tone = if liked then "accent" else nil,
      actions = { click = "like" },
   }))
   return with(ui.row(parts), { key = "heading", role = "tidal-heading" })
end

-- Under the big cover: the title with the heart, then the artist and the album on their own lines
-- (each clickable for its track list). The stream format sits on the cover.
local function stacked_heading(block: Block, s: Snapshot): Node
   local track = s.track :: link.Track
   local liked = shown("liked", track.liked) == true
   local lines: { Node } = {
      with(ui.row({
         mark_node(block, "mark") or ui.text(""),
         with(ui.text({ ui.span(track.title, "strong") }), { key = "title", role = "tidal-line tidal-title" }),
         with(ui.text({ ui.span(if liked then "♥" else "♡") }), {
            key = "like",
            role = "tidal-heart",
            tone = if liked then "accent" else nil,
            actions = { click = "like" },
         }),
      }), { key = "titleline", role = "tidal-stack-line" }),
   }
   if track.artist ~= "" then
      table.insert(lines, with(ui.text({ ui.span("· " .. track.artist, "muted") }), {
         key = "artist",
         role = "tidal-name tidal-stack-name",
         actions = if track.artist_id then { click = "artist" } else nil,
      }))
   end
   if track.album ~= "" then
      table.insert(lines, with(ui.text({ ui.span("· " .. track.album, "dim") }), {
         key = "album",
         role = "tidal-name tidal-stack-name",
         actions = if track.album_id then { click = "album" } else nil,
      }))
   end
   return with(ui.col(lines), { key = "heading", role = "tidal-stack" })
end

-- Minutes left on the sleep timer, or "end" when it waits for the track to end.
local function sleep_label(s: Snapshot): string?
   local sleep = s.sleep
   if sleep == nil then
      return nil
   end
   if sleep.end_of_track then
      return "end"
   end
   return tostring(math.max(1, math.ceil(((sleep.at_s or os.time()) - os.time()) / 60))) .. "m"
end

-- The sleep timer's choices, under the controls while its button is open: the current one lit.
local function sleep_menu(s: Snapshot): Node
   local current = if s.sleep == nil then "off" elseif s.sleep.end_of_track then "track" else nil
   local items: { Node } = {
      with(ui.text({ ui.span("sleep", "dim") }), { key = "label", role = "tidal-menu-label" }),
   }
   for _, choice in SLEEP_CHOICES do
      local label = if choice == "track" then "end of track" elseif choice == "off" then "off" else choice .. " min"
      table.insert(items, with(ui.text({ ui.span(label) }), {
         key = choice,
         role = "tidal-menu-item",
         tone = if choice == current then "accent" else nil,
         actions = { click = "sleepset=" .. choice },
      }))
   end
   return with(ui.row(items), { key = "sleepmenu", role = "tidal-menu" })
end

-- Two lines beside the cover: title and controls, then the timeline. With `big`, the cover shows
-- above (or beside) instead (see `big_cover`): the heading stacks, the controls get their own row.
local function now_playing(block: Block, s: Snapshot, big: boolean): Node
   local track = s.track :: link.Track

   -- Controls TIDAL doesn't offer here are left out rather than greyed.
   local controls: { Node } = {
      button("prev", "frame-prev", "prev", s.can.prev),
      -- Not keyed or named "toggle": that is a Tern UI event name, and clicks on such a node never
      -- reached the block.
      button("playpause", if playing() then "pause" else "play", "playpause", s.can.toggle),
      button("next", "frame-next", "next", s.can.next),
   }
   if s.can.shuffle then
      table.insert(controls, button("shuffle", "swap", "shuffle", true, shown("shuffle", s.shuffle) == true))
   end
   if s.can["repeat"] then
      table.insert(controls, button("repeat", "repeat", "repeat", true, (shown("repeat", s["repeat"]) or "off") ~= "off"))
   end
   -- Starts the current track's radio, after the song that's playing; lit while a track radio plays.
   table.insert(controls, button("radio", "broadcast", "radio", true, s.source_mix == "TRACK_MIX"))
   -- Your Daily Discovery, after the song that's playing; lit while it plays.
   table.insert(controls, button("discovery", "sparkle", "discovery", true, s.source_mix == "DISCOVERY_MIX"))
   table.insert(controls, button("lyrics", "text-quote", "lyrics", true, lyrics_on(block)))
   table.insert(controls, button("sleep", "moon", "sleep", true, s.sleep ~= nil or block.sleep_menu))
   local sleeping = sleep_label(s)
   if sleeping then
      table.insert(controls, with(ui.text({ ui.span(sleeping, "muted") }), { key = "sleepleft", role = "tidal-level" }))
   end
   local level = shown("volume", s.volume)
   if s.can.volume and level then
      local muted = shown("muted", s.muted) == true
      table.insert(controls, button("mute", if muted then "slash-circle" else "wave", "mute", true, muted))
      -- Clicking the number steps through a few volume levels.
      table.insert(controls, with(ui.text({ ui.span(if muted then "mute" else tostring(level), "muted") }), {
         key = "level",
         role = "tidal-level tidal-level-click",
         actions = { click = "volpreset" },
      }))
   end
   if block.search == nil then
      -- Says that search exists and which key opens it; clicking opens it too.
      table.insert(controls, with(ui.row({
         ui.node("icon", { name = "search" }),
         ui.text({ ui.span("f", "key") }),
      }), { key = "search", role = "tidal-search-hint", actions = { click = "search" } }))
   end
   -- What every button does, and the keys.
   table.insert(controls, button("help", "help", "help", true, block.help))

   local pos = position()
   local length = track.length_ms
   local timeline = with(ui.row({
      with(ui.text({ ui.span(link.clock(pos), "muted") }), { key = "at", role = "tidal-time" }),
      seek_bar(block, s, if length and length > 0 then pos / length else 0),
      with(ui.text({ ui.span(link.clock(length), "muted") }), { key = "length", role = "tidal-time" }),
   }), { key = "timeline", role = "tidal-timeline" })

   local controls_row = with(ui.row(controls), {
      key = "controls",
      role = if big then "tidal-controls tidal-stack-controls" else "tidal-controls",
   })
   if big then
      local stack: { Node } = { stacked_heading(block, s), controls_row }
      if block.sleep_menu then
         table.insert(stack, sleep_menu(s))
      end
      table.insert(stack, timeline)
      return with(ui.col(stack), { key = "player", role = "tidal-body tidal-stacked" })
   end
   local body: { Node } = {
      with(ui.row({ heading(block, s, big), controls_row }), { key = "top", role = "tidal-top" }),
   }
   if block.sleep_menu then
      table.insert(body, sleep_menu(s))
   end
   table.insert(body, timeline)
   return with(ui.row({ cover_node(block, s), with(ui.col(body), { key = "body", role = "tidal-body" }) }), {
      key = "player",
      role = "tidal-player",
   })
end

-- A floating card too small for the big cover, without focus: the cover small beside the title
-- (with play controls: Tern can show a floating card enlarged without focusing it), the artist, and
-- a thin line for how far the song is.
local function glance_view(block: Block, s: Snapshot): Node
   local track = s.track :: link.Track
   local length = track.length_ms
   local lines: { Node } = {
      with(ui.row({
         with(ui.text({ ui.span(track.title, "strong") }), { key = "title", role = "tidal-line" }),
         with(ui.row({
            button("prev", "frame-prev", "prev", s.can.prev),
            button("playpause", if playing() then "pause" else "play", "playpause", s.can.toggle),
            button("next", "frame-next", "next", s.can.next),
         }), { key = "controls", role = "tidal-controls" }),
      }), { key = "top", role = "tidal-top" }),
   }
   if track.artist ~= "" then
      table.insert(lines, with(ui.text({ ui.span(track.artist, "muted") }), { key = "artist", role = "tidal-line" }))
   end
   table.insert(lines, with(ui.progress(if length and length > 0 then position() / length else 0, ""), {
      key = "bar",
      role = "tidal-thin",
   }))
   return with(ui.row({
      cover_node(block, s),
      with(ui.col(lines), { key = "body", role = "tidal-body" }),
   }), { key = "glance", role = "tidal-player tidal-glance" })
end

-- Rows the block spends on things other than the list below the player: the two-line player, the
-- list heading and some air.
local PANEL_CHROME_ROWS = 5
-- The big cover is as wide as the block up to 640 px (TIDAL sends it at that size), shrunk further
-- so some of the list still fits beside or under it. Sizes go in 8 px steps, about one column each
-- (`tidal-art-w<px>` in styles/player.css), so it scales smoothly as the block resizes; there's an
-- 8 px gap. styles/player.css also keeps it within a quarter of the window's width. Tern doesn't say
-- how big a cell is; at its default font one is about 8 × 16 px. The list takes whatever room is
-- left and clips what doesn't fit, so a different cell size only shows fewer or more entries.
local ART_PX = 640
-- A floating card is a corner companion: its cover stops at 320 × 320, and a taller card gives the
-- extra rows to the list (unless you chose cover only for an unfocused card).
local FLOATING_ART_PX = 320
-- Small enough for short cards, big enough that the player over it doesn't hide the whole cover.
local ART_MIN_PX = 160
local ART_STEP_PX = 8
local ART_GAP_PX = 8
local CELL_W_PX = 8
local CELL_H_PX = 16
-- Under the big cover (the player sits over it): the list's heading and some air, then at least
-- this many list entries; the cover shrinks to leave them. A taller block gives the cover its room
-- first, then the list any rows left.
local LIST_CHROME_ROWS = 2
local LIST_ENTRIES_MIN = 3
-- A docked block wide enough for the cover and this much list beside it puts them side by side:
-- the cover on the left at the block's full height, the queue or lyrics on the right.
local SIDE_LIST_PX = 320

local function search_rows(block: Block): number
   return if block.search then 1 else 0
end

-- An unfocused floating card shows just the cover with the title, artist and quality on it, so the
-- cover takes the whole card and can be smaller (two lines over it, not the player).
local GLANCE_ART_MIN_PX = 104

local function stepped(px: number, min: number): number?
   local step = px - px % ART_STEP_PX
   return if step >= min then step else nil
end

-- Side by side: the cover's width, or nil when the block is floating or not that wide.
local function side_px(block: Block): number?
   if block.floating then
      return nil
   end
   local fit = math.min(ART_PX, block.cx.cols * CELL_W_PX - SIDE_LIST_PX - ART_GAP_PX, block.cx.rows * CELL_H_PX - ART_GAP_PX)
   return stepped(fit, ART_MIN_PX)
end

-- The big cover's width in px, or nil when no useful size fits (then it stays a thumbnail).
local function art_px(block: Block): number?
   local side = side_px(block)
   if side then
      return side
   end
   local cover_only = block.glance and link.setting("glance_cover_only")
   local keep = if block.glance then 0 else LIST_CHROME_ROWS + LIST_ENTRIES_MIN
   local rows_left = block.cx.rows - search_rows(block) - keep
   local cap = if block.floating and not cover_only then FLOATING_ART_PX else ART_PX
   local fit = math.min(cap, block.cx.cols * CELL_W_PX, rows_left * CELL_H_PX - ART_GAP_PX)
   return stepped(fit, if block.glance then GLANCE_ART_MIN_PX else ART_MIN_PX)
end

local function art_rows(block: Block): number
   return math.ceil(((art_px(block) or 0) + ART_GAP_PX) / CELL_H_PX)
end

-- The cover shows with the player over it at the largest size that fits (docked, leaving those list
-- entries), floating or docked. Otherwise a docked or focused player has the cover as a thumbnail,
-- and an unfocused floating one shows the glance.
local function big_cover(block: Block, s: Snapshot): boolean
   return s.cover ~= nil and block.blob ~= nil and art_px(block) ~= nil
end

-- Entries the list has room for: the block's height less the player (and the big cover, unless the
-- list sits beside it). The list clips anything past this, so it's the most worth building.
local function panel_rows(block: Block): number
   local s = snap
   if s and big_cover(block, s) then
      local above = if side_px(block) then 0 else art_rows(block)
      return math.max(0, block.cx.rows - above - LIST_CHROME_ROWS - search_rows(block))
   end
   return math.max(0, block.cx.rows - PANEL_CHROME_ROWS - search_rows(block))
end

local function row_button(key: string, label: string, action: string): Node
   return with(ui.text({ ui.span(label) }), { key = key, role = "tidal-row-button", actions = { click = action } })
end

-- Three accent bars that bounce like a level meter while the song plays and hold still while it's
-- paused (styles/player.css animates them). `role` adds where they sit.
local function level_meter(key: string, role: string): Node
   return with(ui.row({
      with(ui.text(""), { key = "b1", role = "tidal-eq-bar tidal-eq-1" }),
      with(ui.text(""), { key = "b2", role = "tidal-eq-bar tidal-eq-2" }),
      with(ui.text(""), { key = "b3", role = "tidal-eq-bar tidal-eq-3" }),
   }), {
      key = key,
      role = role .. " tidal-eq" .. (if playing() then "" else " tidal-eq-paused"),
      tone = "accent",
   })
end

-- The queue around the current track, one line each; it scrolls to keep the current track near the
-- top. Clicking a line plays it; hover buttons play it next, move it, drop it or copy its link. The
-- list fills the block's rows and the stylesheet clips what doesn't fit.
local function queue_view(block: Block, s: Snapshot): Node?
   local queue = s.queue
   if queue == nil or #queue.items == 0 then
      return nil
   end
   local current = queue.current + 1
   -- A couple more than the estimate, so a smaller font fills the gap instead of leaving one.
   local last = math.min(#queue.items, panel_rows(block) + 2)
   local lines: { Node } = {
      with(ui.text({
         ui.span("Queue", "strong"),
         ui.span(string.format("  %d of %d", queue.position + 1, queue.total), "dim"),
         ui.span(if s.source then "  · " .. (s.source :: string) else "", "dim"),
      }), { key = "heading", role = "tidal-line tidal-queue-heading" }),
   }
   -- The entry's index in the whole queue.
   local function index_of(i: number): number
      return queue.position - queue.current + i - 1
   end
   for i = 1, last do
      local item = queue.items[i]
      local is_current = i == current
      local spans: { Span } = {
         ui.span(item.title or "…", if is_current then "strong" elseif i < current then "dim" else nil),
      }
      if item.artist ~= "" then
         table.insert(spans, ui.span(" · " .. item.artist, if i < current then "dim" else "muted"))
      end
      if item.length_s then
         table.insert(spans, ui.span("  " .. link.clock(item.length_s * 1000), "dim"))
      end
      -- A column for the marker: the level meter on the current entry, empty on the others so the
      -- titles line up. The current entry is marked like "now" everywhere: accent text and the meter.
      local marker = if is_current then level_meter("marker", "tidal-marker") else with(ui.text(""), { key = "marker", role = "tidal-marker" })
      local row: { Node } = {
         marker,
         with(ui.text(spans), {
            key = "label",
            role = if is_current then "tidal-line tidal-row-label tidal-now" else "tidal-line tidal-row-label",
            actions = if is_current then nil else { click = "jump=" .. tostring(index_of(i)) },
         }),
      }
      if i > current + 1 then
         -- Straight to the front: plays after the current song.
         table.insert(row, row_button("tonext", "next", "qmove=" .. tostring(index_of(i)) .. ":" .. tostring(queue.position + 1)))
         table.insert(row, row_button("up", "↑", "qmove=" .. tostring(index_of(i)) .. ":" .. tostring(index_of(i) - 1)))
      end
      if i > current then
         if index_of(i) + 1 < queue.total then
            table.insert(row, row_button("down", "↓", "qmove=" .. tostring(index_of(i)) .. ":" .. tostring(index_of(i) + 1)))
         end
         table.insert(row, row_button("remove", "✕", "qremove=" .. tostring(i)))
      end
      -- Every entry, played or not, can give its share link.
      table.insert(row, row_button("link", "link", "qshare=" .. tostring(i)))
      table.insert(lines, with(ui.row(row), { key = item.uid or ("q" .. i), role = "tidal-row tidal-result" }))
   end
   return with(ui.col(lines), { key = "queue", role = "tidal-search tidal-queue tidal-list" })
end

-- The current track's synced lyrics and the index of the line being sung (0 before the first),
-- or nil when there are none (not loaded yet, plain text only, or none at all).
local function synced_lyrics(s: Snapshot): ({ { ms: number, text: string } }?, number)
   local l = lyrics
   local track = s.track
   if l == nil or track == nil or l.track ~= track.id or l.waiting or l.lines == nil then
      return nil, 0
   end
   local synced = l.lines :: { { ms: number, text: string } }
   local pos = position()
   local now = 0
   for i, line in synced do
      if line.ms <= pos then
         now = i
      else
         break
      end
   end
   return synced, now
end

-- On a floating card with lyrics on: the line being sung over the cover, between the one before and
-- the one after (dimmed). Nil without synced lyrics.
local function lyric_strip(s: Snapshot): Node?
   local synced, now = synced_lyrics(s)
   if synced == nil then
      return nil
   end
   local rows: { Node } = {}
   for i = math.max(1, now - 1), math.min(#synced, math.max(now, 1) + 1) do
      local text = if synced[i].text == "" then "♪" else synced[i].text
      table.insert(rows, with(ui.text({ ui.span(text, if i == now then "strong" else nil) }), {
         key = "l" .. i,
         role = if i == now then "tidal-line tidal-overlay-lyric tidal-now" else "tidal-line tidal-overlay-lyric tidal-lyric-dim",
      }))
   end
   return with(ui.col(rows), { key = "lyrics", role = "tidal-overlay-lyrics" })
end

-- The current track's lyrics. Synced lyrics follow the song: the line being sung in the accent
-- colour, near the top third of the list; clicking a line goes there. Plain lyrics (no timing) show
-- from the top and can't be clicked; the heading says which kind these are.
local function lyrics_view(block: Block, s: Snapshot): Node
   local room = panel_rows(block)
   local track = s.track :: link.Track
   local l = lyrics
   local synced, now = synced_lyrics(s)
   local kind = if synced then "synced · click a line to go there" elseif l and l.text then "not synced" else ""
   local lines: { Node } = {
      with(ui.text({ ui.span("Lyrics", "strong"), ui.span("  " .. track.title, "dim"), ui.span(if kind ~= "" then "  · " .. kind else "", "dim") }), {
         key = "heading",
         role = "tidal-line tidal-queue-heading",
      }),
   }
   local function note(text: string)
      table.insert(lines, with(ui.text({ ui.span("  " .. text, "dim") }), { key = "note", role = "tidal-line" }))
   end
   if l == nil or l.track ~= track.id or l.waiting then
      note("loading…")
   elseif l.error then
      note(l.error)
   elseif synced then
      local first = math.clamp(now - math.floor(room / 3), 1, math.max(1, #synced - room + 1))
      for i = first, math.min(#synced, first + room + 1) do
         local line = synced[i]
         local text = if line.text == "" then "♪" else line.text
         table.insert(lines, with(ui.text({ ui.span(text, if i == now then "strong" elseif i < now then "dim" else nil) }), {
            key = "l" .. i,
            role = if i == now then "tidal-line tidal-lyric tidal-now" else "tidal-line tidal-lyric",
            actions = { click = "lyricseek=" .. tostring(line.ms) },
         }))
      end
   elseif l.text then
      local count = 0
      for line in string.gmatch((l.text :: string) .. "\n", "([^\n]*)\n") do
         count += 1
         if count > room + 2 then
            break
         end
         table.insert(lines, with(ui.text({ ui.span(if line == "" then " " else line) }), { key = "l" .. count, role = "tidal-line tidal-lyric-plain" }))
      end
   else
      note("TIDAL has no lyrics for this track")
   end
   return with(ui.col(lines), { key = "lyrics", role = "tidal-search tidal-queue tidal-list" })
end

-- What every control does and the keys, in place of the queue (`?` or the help button).
local HELP_CONTROLS = {
   { "frame-prev", "previous · next · play / pause", "p n space" },
   { "swap", "shuffle", "s" },
   { "repeat", "repeat (off → all → one)", "r" },
   { "broadcast", "track radio after this song", "" },
   { "sparkle", "Daily Discovery after this song", "" },
   { "text-quote", "lyrics instead of the queue", "y" },
   { "moon", "sleep timer", "t" },
   { "wave", "mute; click the number for 10 / 25 / 50", "m  + -" },
   { "search", "search", "/ f" },
}
local HELP_KEYS = "←→ 10 s · 0–9 jump · l like · a artist · b album · o open TIDAL · ? help · esc closes"

local function help_view(s: Snapshot?): Node
   local lines: { Node } = {
      with(ui.text({ ui.span("Controls", "strong"), ui.span("  ? closes", "dim") }), { key = "heading", role = "tidal-line tidal-queue-heading" }),
   }
   local function row(key: string, icon: string, text: string, keys: string, tone: string?)
      table.insert(lines, with(ui.row({
         with(ui.row({ ui.node("icon", { name = icon }) }), { key = "icon", role = "tidal-help-icon", tone = tone }),
         with(ui.text({ ui.span(text), ui.span(if keys ~= "" then "  " .. keys else "", "dim") }), { key = "text", role = "tidal-line" }),
      }), { key = key, role = "tidal-help-row" }))
   end
   for i, entry in HELP_CONTROLS do
      row("c" .. i, entry[1], entry[2], entry[3])
   end
   -- The quality icons, the current one named in full.
   for _, level in { "HI_RES_LOSSLESS", "LOSSLESS", "HIGH", "LOW" } do
      local current = s ~= nil and s.quality == level
      local text = QUALITY_NAME[level] .. (if current and s and s.format then " — now: " .. s.format elseif current then " — now" else "")
      row("q" .. level, QUALITY_ICON[level], text, "", if level == "HI_RES_LOSSLESS" then "accent" else nil)
   end
   table.insert(lines, with(ui.text({ ui.span(HELP_KEYS, "dim") }), { key = "keys", role = "tidal-line" }))
   return with(ui.col(lines), { key = "help", role = "tidal-search tidal-queue tidal-list" })
end

local function view(block: Block): BlockView
   local s = snap
   local main: Node
   if bridge_problem and not link.fresh(s) then
      main = message(block, "Bridge not running", bridge_problem, { link_button("retry", "Retry", "retry") }, "error")
   elseif s == nil then
      main = message(block, "TIDAL", "Connecting…", {})
   elseif s.starting then
      main = message(block, "Starting TIDAL", "with remote control…", {})
   elseif s.relaunch then
      -- The bridge keeps retrying by itself; the button restarts TIDAL right away.
      main = message(block, "No remote control", s.problem or "TIDAL was started without it.", { link_button("relaunch", "Restart now", "relaunch") }, "warning")
   elseif s.problem then
      main = message(block, "Can't reach TIDAL", s.problem, { link_button("retry", "Retry", "retry") }, "warning")
   elseif not s.app then
      main = message(block, "TIDAL isn't running", "", { link_button("launch", "Open", "launch") })
   elseif s.track == nil then
      main = message(block, "Nothing playing", "", {
         link_button("discovery", "Daily Discovery", "discovery"),
         link_button("launch", "Open", "launch"),
      })
   elseif block.glance and not big_cover(block, s) then
      return { main = ui.col({ glance_view(block, s) }) }
   elseif block.glance then
      -- Unfocused floating card: the title and artist over the cover (below), the quality on its corner.
      local track = s.track :: link.Track
      local lines: { Node } = {
         with(ui.text({ ui.span(track.title, "strong") }), { key = "title", role = "tidal-line tidal-glance-title" }),
      }
      if track.artist ~= "" then
         table.insert(lines, with(ui.text({ ui.span(track.artist) }), { key = "artist", role = "tidal-line tidal-glance-title tidal-stack-name" }))
      end
      main = ui.col(lines)
   else
      main = now_playing(block, s, big_cover(block, s))
   end
   local st = block.search
   -- With a big cover, the player sits over its lower part (see `big_cover`).
   local big = s ~= nil and big_cover(block, s)
   local side = big and side_px(block) ~= nil
   local top: Node = main
   if s and big then
      local art: { Node } = {
         with(ui.node("image", { blob = block.blob, alt = (s.track :: link.Track).album }), { key = "image", role = "tidal-art-image" }),
      }
      -- The quality icon sits on the cover's top corner, clear of the player. Its backing follows
      -- the corner's tone (styles/player.css picks the accent or the panel colour, whichever stands
      -- out more against it in the current theme).
      local tone = s.cover and s.cover.tone
      local badge = quality_icon(s, if tone then "tidal-art-badge tidal-on-" .. tone else "tidal-art-badge")
      if badge then
         table.insert(art, badge)
      end
      -- A floating card's cover shows how far the song is as a thin line along its top edge; with
      -- focus, clicking it seeks.
      if block.floating then
         local length = (s.track :: link.Track).length_ms
         local fraction = if length and length > 0 then position() / length else 0
         if block.glance then
            table.insert(art, with(ui.progress(fraction, ""), { key = "progress", role = "tidal-art-progress tidal-thin" }))
         else
            table.insert(art, seek_bar(block, s, fraction, "tidal-art-progress"))
         end
      end
      -- With lyrics on, a floating card sings them over its cover, above the title (or the player).
      local over: { Node } = {}
      local strip = if block.floating and lyrics_on(block) then lyric_strip(s) else nil
      if strip then
         table.insert(over, strip)
      end
      table.insert(over, main)
      -- A light cover gets a darker fade behind the text.
      local strong = s.cover and s.cover.tone_bottom == "light"
      table.insert(art, with(ui.col(over), {
         key = "overlay",
         role = (if block.glance then "tidal-overlay tidal-overlay-title" else "tidal-overlay") .. (if strong then " tidal-overlay-strong" else ""),
      }))
      -- Floating, the cover sits at the card's left edge like the rest of its content.
      local role = "tidal-art tidal-art-w" .. tostring(art_px(block)) .. (if block.floating then " tidal-art-left" else "")
      top = with(ui.col(art), { key = "art", role = role })
   end

   -- Under (or beside) the player: search results or a list while there are any; otherwise the
   -- help, the lyrics or the queue, in whatever room is left. An unfocused card shows the queue only
   -- under a big cover, and not when you chose cover only. A floating card with a big cover has its
   -- lyrics over the cover, so the queue stays below.
   local panel: { Node } = {}
   if st and not block.glance then
      local now: search.Playing = if s
         then { track = s.track and s.track.id, type = s.source_type, id = s.source_id, mix = s.source_mix, name = s.source }
         else {}
      table.insert(panel, search.view(st, panel_rows(block), now))
   end
   local cover_only = block.glance and link.setting("glance_cover_only")
   if (big or not block.glance) and not cover_only and not (st and search.busy(st)) and s and s.track and panel_rows(block) >= 2 then
      if block.help and not block.glance then
         table.insert(panel, help_view(s))
      elseif lyrics_on(block) and not (block.floating and big) then
         table.insert(panel, lyrics_view(block, s))
      else
         local queue = queue_view(block, s)
         if queue then
            table.insert(panel, queue)
         end
      end
   end

   local stage: Node
   if side then
      -- Wide docked block: the cover (with the player over it) on the left, the list on the right.
      stage = with(ui.row({
         top,
         with(ui.col(panel), { key = "panel", role = "tidal-side-panel" }),
      }), { key = "stage", role = "tidal-stage tidal-side" })
   else
      local parts: { Node } = { top }
      for _, part in panel do
         table.insert(parts, part)
      end
      stage = with(ui.col(parts), { key = "stage", role = "tidal-stage" })
   end
   local result: BlockView = { main = ui.col({ stage }) }

   -- Below everything: the last error (until dismissed) and passing notices.
   local dock: { Node } = {}
   if block.problem then
      table.insert(dock, with(ui.row({
         with(ui.text({ ui.span(block.problem :: string) }), { key = "text", role = "tidal-line" }),
         row_button("dismiss", "✕", "dismiss"),
      }), { key = "problem", role = "tidal-problem", tone = "error" }))
   end
   if notice then
      table.insert(dock, with(ui.text({ ui.span(notice.text, "muted") }), { key = "notice" }))
   end
   if #dock > 0 then
      result.dock = ui.col(dock)
   end
   return result
end

-- Fetches the current track's lyrics while any player shows them, and picks up the answer.
local function update_lyrics()
   local s = snap
   local wanted = false
   for _, block in blocks do
      wanted = wanted or lyrics_on(block)
   end
   if not wanted or s == nil or s.track == nil or s.track.id == nil then
      return
   end
   local id = s.track.id :: string
   local l = lyrics
   if l == nil or l.track ~= id then
      local _, block = next(blocks)
      if block == nil then
         return
      end
      lyrics = { track = id, waiting = send(block :: Block, "lyrics", id) }
      return
   end
   if l.waiting == nil then
      return
   end
   local ok, text = pcall(tern.fs.read, LYRICS_FILE, 1024 * 1024)
   if not ok then
      return
   end
   local decoded, answer = pcall(tern.json.decode, text)
   if not decoded or type(answer) ~= "table" or answer.id ~= l.waiting then
      return
   end
   l.waiting = nil
   l.error = answer.error
   l.lines = if answer.lines and #answer.lines > 0 then answer.lines else nil
   l.text = answer.text
end

-- What the views depend on (apart from each pane's own state); panes re-render only when it
-- changes. The snapshot's part is its text as read, so nothing is re-encoded each tick.
local function signature(): string
   local s = snap
   local parts = { if notice then notice.text else "", bridge_problem or "", tostring(playing()) }
   table.insert(parts, tostring(link.setting("glance_cover_only")))
   local l = lyrics
   if l then
      table.insert(parts, l.track .. tostring(l.waiting) .. tostring(l.error) .. tostring(l.lines ~= nil))
   end
   if s and s.sleep and s.sleep.at_s then
      table.insert(parts, tostring((s.sleep.at_s - os.time()) // 60))
   end
   if s then
      table.insert(parts, link.signature())
      if playing() then
         table.insert(parts, tostring(position() // 1000))
      end
   end
   for field, want in expected do
      table.insert(parts, field .. "=" .. tostring(want.value))
   end
   return table.concat(parts, "\u{1f}")
end

-- How many times the page had queued Daily Discovery by itself when last seen (nil before the first
-- snapshot, so a count from before the plugin loaded isn't announced).
local auto_seen: number? = nil

-- Loop ------------------------------------------------------------------------------------------

local function tick()
   local live: { [number]: boolean } = {}
   for _, pane in tern.pane.list() do
      live[pane.pane] = true
   end
   for pane in blocks do
      if not live[pane] then
         blocks[pane] = nil
      end
   end
   if next(blocks) == nil then
      ticking = false
      return
   end

   local latest = link.read()
   bridge_problem = link.ensure(latest)
   if latest and (link.fresh(latest) or snap == nil) then
      snap = latest
      if latest.timeline ~= anchor.timeline then
         anchor = { timeline = latest.timeline, pos = latest.position_ms or 0, at = tern.now() }
      end
      load_cover(latest)
      take_reply(latest)
      local auto = latest.auto_discovery or 0
      if auto_seen and auto > auto_seen then
         say("Nothing was queued after this song, so Daily Discovery follows it (off in the palette)")
      end
      auto_seen = auto
   end
   update_lyrics()
   if notice and tern.now() > notice.expires then
      notice = nil
   end

   local sig = signature()
   for _, block in blocks do
      if cover.key and cover.bytes and block.cover_key ~= cover.key then
         block.blob = block.cx:blob(cover.bytes :: string, cover.mime or "image/png")
         block.cover_key = cover.key
         block.signature = ""
      end
      if block.search and search.poll(block.search, function(op, arg)
         return send(block, op, arg)
      end) then
         block.signature = ""
      end
      local pane_view = link.pane_view(block.cx.pane)
      local glance = pane_view.floating and not pane_view.focused
      if pane_view.floating ~= block.floating then
         block.floating = pane_view.floating
         block.signature = ""
      end
      if pane_view.focused ~= block.focused then
         block.focused = pane_view.focused
         -- Focusing the player opens search; leaving it closes an untouched one.
         if pane_view.focused then
            block.search = block.search or search.open()
         elseif block.search and block.search.query == "" and block.search.list == nil then
            block.search = nil
         end
         block.signature = ""
      end
      if glance ~= block.glance then
         block.glance = glance
         -- A glance drops search; focusing the player again starts from the full view.
         if glance then
            block.search = nil
         end
         block.signature = ""
      end
      local own = table.concat({
         tostring(lyrics_on(block)),
         tostring(block.help),
         tostring(block.sleep_menu),
         block.problem or "",
         if glance then "glance" else "",
      }, "\u{1f}")
      local block_sig = sig .. "\u{1f}" .. own .. (if block.search then "\u{1f}" .. search.signature(block.search) else "")
      if block.signature ~= block_sig then
         block.signature = block_sig
         block.cx:render()
      end
   end
   tern.timer(TICK_MS, tick)
end

tern.block.define("player", {
   init = function(cx: BlockCx, _args: { string }, _saved: any): Block
      local pane_view = link.pane_view(cx.pane)
      local block: Block = {
         cx = cx,
         signature = "",
         glance = pane_view.floating and not pane_view.focused,
         focused = pane_view.focused,
         floating = pane_view.floating,
         help = false,
         sleep_menu = false,
      }
      blocks[cx.pane] = block
      snap = snap or link.read()
      if not ticking then
         ticking = true
         tern.timer(0, tick)
      end
      return block
   end,

   title = function(_block: Block): string?
      local s = snap
      if s and s.app and s.track then
         local track = s.track :: link.Track
         local text = link.shorten(track.title, 40)
         if track.artist ~= "" then
            text ..= " · " .. link.shorten(track.artist, 30)
         end
         return (if playing() then "▶ " else "⏸ ") .. text
      end
      return "TIDAL"
   end,

   view = function(block: Block, _cx: BlockCx): BlockView
      return view(block)
   end,

   key = function(block: Block, key: Key, _cx: BlockCx): boolean?
      local st = block.search
      if st then
         local result = search.key(st, key)
         if result == "close" then
            block.search = nil
         elseif type(result) == "table" then
            pick(block, result :: search.Pick)
         end
         -- Search opens with focus, so keys it leaves alone (space on an empty query, ←→) still
         -- drive the player.
         if result ~= false then
            block.signature = ""
            return true
         end
      end
      if key.ctrl or key.alt or key.meta then
         return false
      end
      local s = snap
      local typed = key.text or key.name
      if typed == "/" or typed == "f" then
         block.search = block.search or search.open(typed)
         block.signature = ""
         return true
      end
      if key.name == "space" or typed == "k" then
         act(block, "playpause")
      elseif key.name == "left" then
         act(block, "back")
      elseif key.name == "right" then
         act(block, "forward")
      elseif typed == "n" then
         act(block, "next")
      elseif typed == "p" then
         act(block, "prev")
      elseif typed == "s" then
         act(block, "shuffle")
      elseif typed == "r" then
         act(block, "repeat")
      elseif typed == "+" or typed == "=" or key.name == "up" then
         act(block, "louder")
      elseif typed == "-" or key.name == "down" then
         act(block, "quieter")
      elseif typed == "m" then
         act(block, "mute")
      elseif typed == "l" then
         act(block, "like")
      elseif typed == "y" then
         act(block, "lyrics")
      elseif typed == "a" then
         act(block, "artist")
      elseif typed == "b" then
         act(block, "album")
      elseif typed == "t" then
         act(block, "sleep")
      elseif typed == "o" then
         act(block, "launch")
      elseif typed == "?" then
         act(block, "help")
      elseif key.name == "escape" or key.name == "esc" then
         if not (block.help or block.sleep_menu) then
            return false
         end
         block.help, block.sleep_menu = false, false
      elseif string.match(typed, "^%d$") and s and s.track and s.track.length_ms then
         seek(block, (tonumber(typed) :: number) / 10 * s.track.length_ms)
      else
         return false
      end
      return true
   end,

   event = function(block: Block, ev: UiEvent, _cx: BlockCx)
      if ev.ev ~= "action" or type(ev.act) ~= "string" then
         return
      end
      local st = block.search
      local value = ev.value
      local index = tonumber(value)
      local item = st and index and st.items[index]
      if ev.act == "pick" and item then
         pick(block, { op = "play", item = item })
      elseif (ev.act == "qnext" or ev.act == "qlast") and item then
         pick(block, { op = if ev.act == "qnext" then "queue-next" else "queue-last", item = item })
      elseif ev.act == "jump" and index then
         send(block, "jump", index)
      elseif ev.act == "qmove" and type(value) == "string" then
         local from, to = string.match(value, "^(%d+):(%d+)$")
         if from and to then
            send(block, "move", from .. " " .. to)
         end
      elseif ev.act == "qlink" and item then
         block.cx:copy(link.share_url(item.kind, item.id))
         say("Copied the link to " .. item.title)
      elseif ev.act == "qshare" and index then
         local entry = snap and snap.queue and snap.queue.items[index]
         if entry then
            block.cx:copy(link.share_url("track", entry.id))
            say("Copied the link to " .. (entry.title or "the track"))
         end
      elseif ev.act == "qremove" and index then
         local entry = snap and snap.queue and snap.queue.items[index]
         if entry then
            send(block, "remove", entry.uid)
         end
      elseif ev.act == "lyricseek" and index then
         seek(block, index)
      elseif ev.act == "sleepset" and type(value) == "string" then
         set_sleep(block, value)
      elseif ev.act == "seekto" and index then
         local length = snap and snap.track and snap.track.length_ms
         if length then
            -- The cell's middle, so the first and last cells aren't 0 % and 100 % exactly.
            seek(block, (index - 0.5) / seek_cells(block) * length)
         end
      else
         act(block, ev.act)
      end
      block.signature = ""
   end,
})
