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
   if pane and reply.error then
      expected = {}
      local block = blocks[pane]
      if block then
         block.cx:toast("error", "TIDAL", reply.error)
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

local function cycle_sleep(block: Block)
   local s = snap
   local now: string = "off"
   if s and s.sleep then
      now = if s.sleep.end_of_track then "track" else "on"
   end
   -- From off: 15 min. From a timer: the next step. From end of track: off.
   local step = "15"
   if now == "track" then
      step = "off"
   elseif now == "on" and s and s.sleep and s.sleep.at_s then
      local left = (s.sleep.at_s - os.time()) / 60
      step = if left > 45 then "track" elseif left > 22 then "60" else "30"
   end
   send(block, "sleep", step)
   say(if step == "off" then "Sleep timer off"
      elseif step == "track" then "Pausing at the end of this track"
      else "Pausing in " .. step .. " minutes")
end

local function act(block: Block, name: string)
   if name == "playpause" then
      toggle(block)
   elseif name == "next" or name == "prev" or name == "radio" then
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
      link.set_setting("lyrics", not link.setting("lyrics"))
   elseif name == "sleep" then
      cycle_sleep(block)
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
-- the bar is a row of thin cells, each seeking to its own point. About one cell per column.
local function seek_bar(block: Block, s: Snapshot, fraction: number): Node
   local count = math.clamp(block.cx.cols - 24, 16, 160)
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
   return with(ui.row(cells), { key = "bar", role = "tidal-seek" })
end

-- What TIDAL streams, as "24-bit 48 kHz FLAC" (TIDAL's quality name when the format isn't known
-- yet); hi-res in the accent colour.
local function format_badge(s: Snapshot, role: string): Node?
   local text = s.format or (if s.quality then string.gsub(s.quality :: string, "_", " ") else nil)
   if text == nil or text == "" then
      return nil
   end
   local hires = s.quality == "HI_RES_LOSSLESS" or s.quality == "HI_RES"
   return with(ui.badge(text, if hires then "accent" else "muted"), { key = "format", role = role })
end

-- Title, then artist and album you can click for their track lists, the stream format (unless it
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
   local badge = if big then nil else format_badge(s, "tidal-quality")
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

-- Two lines beside the cover: title and controls, then the timeline. With `big`, the cover shows
-- above instead (see `big_cover`): the heading stacks, the controls get their own row.
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
   -- Starts the current track's radio, replacing the queue.
   table.insert(controls, button("radio", "broadcast", "radio", true))
   table.insert(controls, button("lyrics", "text-quote", "lyrics", true, link.setting("lyrics")))
   table.insert(controls, button("sleep", "moon", "sleep", true, s.sleep ~= nil))
   local sleeping = sleep_label(s)
   if sleeping then
      table.insert(controls, with(ui.text({ ui.span(sleeping, "muted") }), { key = "sleepleft", role = "tidal-level" }))
   end
   local level = shown("volume", s.volume)
   if s.can.volume and level then
      local muted = shown("muted", s.muted) == true
      table.insert(controls, button("mute", if muted then "slash-circle" else "wave", "mute", true, muted))
      table.insert(controls, with(ui.text({ ui.span(if muted then "mute" else tostring(level), "muted") }), {
         key = "level",
         role = "tidal-level",
      }))
   end
   if block.search == nil then
      -- Says that search exists and which key opens it; clicking opens it too.
      table.insert(controls, with(ui.row({
         ui.node("icon", { name = "search" }),
         ui.text({ ui.span("f", "key") }),
      }), { key = "search", role = "tidal-search-hint", actions = { click = "search" } }))
   end

   local pos = position()
   local length = track.length_ms
   local timeline = with(ui.row({
      with(ui.text({ ui.span(link.clock(pos), "muted") }), { key = "at", role = "tidal-time" }),
      seek_bar(block, s, if length and length > 0 then pos / length else 0),
      with(ui.text({ ui.span(link.clock(length), "muted") }), { key = "length", role = "tidal-time" }),
   }), { key = "timeline", role = "tidal-timeline" })

   if big then
      return with(ui.col({
         stacked_heading(block, s),
         with(ui.row(controls), { key = "controls", role = "tidal-controls tidal-stack-controls" }),
         timeline,
      }), { key = "player", role = "tidal-body tidal-stacked" })
   end
   local body = with(ui.col({
      with(ui.row({
         heading(block, s, big),
         with(ui.row(controls), { key = "controls", role = "tidal-controls" }),
      }), { key = "top", role = "tidal-top" }),
      timeline,
   }), { key = "body", role = "tidal-body" })
   return with(ui.row({ cover_node(block, s), body }), { key = "player", role = "tidal-player" })
end

-- A floating player without focus. Tern keeps the card a few lines tall, so it fills them: cover
-- beside title, artist · album, the timeline with times, then the stream format and what plays
-- next. Nothing to click (Tern gives presses on an unfocused floating block to its card, which
-- focuses it).
local function glance_view(block: Block, s: Snapshot): Node
   local track = s.track :: link.Track
   local function line(key: string, spans: { Span }): Node
      return with(ui.text(spans), { key = key, role = "tidal-line" })
   end

   local lines: { Node } = {
      with(ui.row({
         with(ui.text({ ui.span(track.title, "strong") }), { key = "title", role = "tidal-line" }),
         -- Tern can show a floating card enlarged without focusing it; playback stays one click away.
         with(ui.row({
            button("prev", "frame-prev", "prev", s.can.prev),
            button("playpause", if playing() then "pause" else "play", "playpause", s.can.toggle),
            button("next", "frame-next", "next", s.can.next),
         }), { key = "controls", role = "tidal-controls" }),
      }), { key = "top", role = "tidal-top" }),
   }
   local byline: { Span } = {}
   if track.artist ~= "" then
      table.insert(byline, ui.span(track.artist))
   end
   if track.album ~= "" then
      table.insert(byline, ui.span((if #byline > 0 then " · " else "") .. track.album, "muted"))
   end
   if #byline > 0 then
      table.insert(lines, line("byline", byline))
   end

   local pos = position()
   local length = track.length_ms
   table.insert(lines, with(ui.row({
      with(ui.text({ ui.span(link.clock(pos), "muted") }), { key = "at", role = "tidal-time" }),
      with(ui.progress(if length and length > 0 then pos / length else 0, ""), { key = "bar", role = "tidal-bar" }),
      with(ui.text({ ui.span(link.clock(length), "muted") }), { key = "length", role = "tidal-time" }),
   }), { key = "timeline", role = "tidal-timeline" }))

   local facts: { Span } = {}
   local function fact(text: string?)
      if text and text ~= "" then
         table.insert(facts, ui.span((if #facts > 0 then " · " else "") .. text, "dim"))
      end
   end
   fact(s.format)
   if s.shuffle then
      fact("shuffle")
   end
   if s["repeat"] and s["repeat"] ~= "off" then
      fact("repeat " .. s["repeat"])
   end
   if s.volume then
      fact(if s.muted then "muted" else "vol " .. tostring(s.volume))
   end
   if #facts > 0 then
      table.insert(lines, line("facts", facts))
   end

   local next_track = s.next
   if next_track then
      table.insert(lines, line("next", {
         ui.span("> ", "dim"),
         ui.span(next_track.title),
         ui.span(if next_track.artist ~= "" then " · " .. next_track.artist else "", "muted"),
      }))
   elseif s.source then
      table.insert(lines, line("source", { ui.span("from ", "dim"), ui.span(s.source :: string, "muted") }))
   else
      table.insert(lines, line("next", { ui.span("last in the queue", "dim") }))
   end

   -- A taller card (Tern's floating size varies) fills its extra rows with what plays after that.
   local queue = s.queue
   local spare = block.cx.rows - #lines - 1
   if queue and next_track and spare > 0 then
      local from = queue.current + 3 -- 1-based: current is current + 1, next is current + 2
      for i = from, math.min(#queue.items, from + spare - 1) do
         local item = queue.items[i]
         table.insert(lines, line("then" .. i, {
            ui.span("> ", "dim"),
            ui.span(item.title or "…", "muted"),
            ui.span(if item.artist ~= "" then " · " .. item.artist else "", "dim"),
         }))
      end
   end

   return with(ui.row({
      cover_node(block, s),
      with(ui.col(lines), { key = "body", role = "tidal-body" }),
   }), { key = "glance", role = "tidal-player tidal-glance" })
end

-- Rows the block spends on things other than the list below the player: the two-line player, the
-- list heading and some air.
local PANEL_CHROME_ROWS = 5
-- The big cover is as wide as the block up to 640 px (TIDAL sends it at that size), shrunk further
-- so the player and some of the list still fit under it, in 40 px steps (`tidal-art-w<px>` in
-- styles/player.css), plus an 8 px gap. Tern doesn't say how big a cell is; at its default font one
-- is about 8 × 16 px.
local ART_PX = 640
local ART_MIN_PX = 120
local ART_STEP_PX = 40
-- Under the big cover the heading stacks: artist and album take a line each, the controls one more.
local STACK_EXTRA_ROWS = 3
local ART_GAP_PX = 8
local CELL_W_PX = 8
local CELL_H_PX = 16
-- Rows under the cover: the stacked player (title, artist, album, controls, timeline), then list
-- rows: room for some of the queue when docked; a floating card, sized by you, needs just one.
local STACKED_PLAYER_ROWS = 5
local LIST_ROWS_DOCKED = 9
local LIST_ROWS_FLOATING = 1

-- The big cover's width in px, or nil when no useful size fits (then it stays a thumbnail).
local function art_px(block: Block): number?
   local list = if block.floating then LIST_ROWS_FLOATING else LIST_ROWS_DOCKED
   local rows_left = block.cx.rows - STACKED_PLAYER_ROWS - list - (if block.search then 1 else 0)
   local fit = math.min(ART_PX, block.cx.cols * CELL_W_PX, rows_left * CELL_H_PX - ART_GAP_PX)
   local px = fit - fit % ART_STEP_PX
   return if px >= ART_MIN_PX then px else nil
end

local function art_rows(block: Block): number
   return math.ceil(((art_px(block) or 0) + ART_GAP_PX) / CELL_H_PX)
end

-- The cover shows above the player at the largest size that keeps the player (and, docked, some of
-- the list) in view: docked, or floating with or without focus. Otherwise a docked or focused
-- player has the cover as a thumbnail, and an unfocused floating one shows the glance.
local function big_cover(block: Block, s: Snapshot): boolean
   return s.cover ~= nil and block.blob ~= nil and art_px(block) ~= nil
end

-- Rows left for the list under the player: whatever height Tern gives the block (docked, or a
-- focused floating card of any size), so the list fills it.
local function panel_rows(block: Block): number
   local rows = block.cx.rows - PANEL_CHROME_ROWS
   if block.search then
      rows -= 1 -- the search line
   end
   local s = snap
   if s and big_cover(block, s) then
      rows -= art_rows(block) + STACK_EXTRA_ROWS
   end
   return math.max(0, rows)
end

local function row_button(key: string, label: string, action: string): Node
   return with(ui.text({ ui.span(label) }), { key = key, role = "tidal-row-button", actions = { click = action } })
end

-- The queue around the current track, one line each, the current one highlighted; it scrolls to
-- keep the current track near the top. Clicking a line plays it; ↑ ↓ ✕ move or drop it.
local function queue_view(block: Block, s: Snapshot): Node?
   local queue = s.queue
   if queue == nil or #queue.items == 0 then
      return nil
   end
   local current = queue.current + 1
   local room = panel_rows(block)
   local last = math.min(#queue.items, room)
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
      -- A column for the marker: Tern's play / pause icon on the current entry (crisper than a text
      -- glyph), empty on the others so the titles line up.
      local marker = if is_current
         then with(ui.row({ ui.node("icon", { name = if playing() then "play" else "pause" }) }), {
            key = "marker",
            role = "tidal-marker",
            tone = "accent",
         })
         else with(ui.text(""), { key = "marker", role = "tidal-marker" })
      local row: { Node } = {
         marker,
         with(ui.text(spans), {
            key = "label",
            role = if is_current then "tidal-line tidal-row-label tidal-now" else "tidal-line tidal-row-label",
            actions = if is_current then nil else { click = "jump=" .. tostring(index_of(i)) },
         }),
      }
      -- Every entry, played or not, can give its share link.
      table.insert(row, row_button("link", "link", "qshare=" .. tostring(i)))
      if i > current then
         -- Upcoming entries can be reordered among themselves or dropped.
         if i > current + 1 then
            table.insert(row, row_button("up", "↑", "qmove=" .. tostring(index_of(i)) .. ":" .. tostring(index_of(i) - 1)))
         end
         if index_of(i) + 1 < queue.total then
            table.insert(row, row_button("down", "↓", "qmove=" .. tostring(index_of(i)) .. ":" .. tostring(index_of(i) + 1)))
         end
         table.insert(row, row_button("remove", "✕", "qremove=" .. tostring(i)))
      end
      table.insert(lines, with(ui.row(row), {
         key = item.uid or ("q" .. i),
         role = if is_current then "tidal-row tidal-selected" else "tidal-row tidal-result",
         tone = if is_current then "accent" else nil,
      }))
   end
   local hidden = queue.total - (queue.position - queue.current) - last
   if hidden > 0 then
      table.insert(lines, with(ui.text({ ui.span(string.format("  +%d more", hidden), "dim") }), {
         key = "more",
         role = "tidal-line",
      }))
   end
   return with(ui.col(lines), { key = "queue", role = "tidal-search tidal-queue" })
end

-- The current track's lyrics. Synced lyrics follow the song: the current line highlighted, the
-- block's rows centred on it; plain lyrics show from the top.
local function lyrics_view(block: Block, s: Snapshot): Node
   local room = panel_rows(block)
   local track = s.track :: link.Track
   local l = lyrics
   local lines: { Node } = {
      with(ui.text({ ui.span("Lyrics", "strong"), ui.span("  " .. track.title, "dim") }), {
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
   elseif l.lines then
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
      local first = math.clamp(now - math.floor(room / 3), 1, math.max(1, #synced - room + 1))
      for i = first, math.min(#synced, first + room - 1) do
         local line = synced[i]
         local text = if line.text == "" then "♪" else line.text
         table.insert(lines, with(ui.text({ ui.span(text, if i == now then "strong" elseif i < now then "dim" else nil) }), {
            key = "l" .. i,
            role = if i == now then "tidal-line tidal-lyric tidal-selected" else "tidal-line tidal-lyric",
            tone = if i == now then "accent" else nil,
            -- Clicking a line goes to it.
            actions = { click = "lyricseek=" .. tostring(line.ms) },
         }))
      end
   elseif l.text then
      local count = 0
      for line in string.gmatch((l.text :: string) .. "\n", "([^\n]*)\n") do
         count += 1
         if count > room then
            note("…")
            break
         end
         table.insert(lines, with(ui.text({ ui.span(if line == "" then " " else line) }), { key = "l" .. count, role = "tidal-line tidal-lyric" }))
      end
   else
      note("TIDAL has no lyrics for this track")
   end
   return with(ui.col(lines), { key = "lyrics", role = "tidal-search tidal-queue" })
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
      main = message(block, "Nothing playing", "", { link_button("launch", "Open", "launch") })
   elseif block.glance and not big_cover(block, s) then
      return { main = ui.col({ glance_view(block, s) }) }
   else
      main = now_playing(block, s, big_cover(block, s))
   end
   local st = block.search
   local parts: { Node } = { main }
   if st then
      table.insert(parts, search.view(st, panel_rows(block), s and s.track and s.track.id))
   end
   -- Results or a list take the space while there are any; otherwise the player shows the lyrics or
   -- the queue in whatever rows are left, docked or floating.
   if not (st and search.busy(st)) and s and s.track and panel_rows(block) >= 2 then
      if link.setting("lyrics") then
         table.insert(parts, lyrics_view(block, s))
      else
         local queue = queue_view(block, s)
         if queue then
            table.insert(parts, queue)
         end
      end
   end
   -- Docked with a big cover, it goes on top, as wide as the block (up to its own size).
   local big = s ~= nil and big_cover(block, s)
   if s and big then
      -- The stream format sits on the cover's corner.
      local art: { Node } = {
         with(ui.node("image", { blob = block.blob, alt = (s.track :: link.Track).album }), { key = "image", role = "tidal-art-image" }),
      }
      local badge = format_badge(s, "tidal-art-badge")
      if badge then
         table.insert(art, badge)
      end
      table.insert(parts, 1, with(ui.col(art), { key = "art", role = "tidal-art tidal-art-w" .. tostring(art_px(block)) }))
   end
   -- A docked block wider than the cover centres everything in a column as wide as the cover; a
   -- narrower one, and a floating player, keep it left-aligned at the block's width.
   local px = if big then art_px(block) else nil
   local wide = px ~= nil and not block.floating and block.cx.cols * CELL_W_PX > px + 2 * CELL_W_PX
   local result: BlockView = {
      main = ui.col({
         with(ui.col(parts), {
            key = "stage",
            role = if wide then "tidal-stage tidal-centered tidal-art-w" .. tostring(px) else "tidal-stage",
         }),
      }),
   }
   if notice then
      result.dock = ui.col({ with(ui.text({ ui.span(notice.text, "muted") }), { key = "notice" }) })
   end
   return result
end

-- Fetches the current track's lyrics while lyrics are shown, and picks up the answer.
local function update_lyrics()
   local s = snap
   if not link.setting("lyrics") or s == nil or s.track == nil or s.track.id == nil then
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

-- What the view depends on; panes re-render only when it changes.
local function signature(): string
   local s = snap
   local parts = { if notice then notice.text else "", bridge_problem or "", tostring(playing()) }
   table.insert(parts, tostring(link.setting("lyrics")))
   local l = lyrics
   if l then
      table.insert(parts, l.track .. tostring(l.waiting) .. tostring(l.error) .. tostring(l.lines ~= nil))
   end
   if s and s.sleep and s.sleep.at_s then
      table.insert(parts, tostring((s.sleep.at_s - os.time()) // 60))
   end
   if s then
      local beat = s.beat
      s.beat = 0
      table.insert(parts, tern.json.encode(s))
      s.beat = beat
      if playing() then
         table.insert(parts, tostring(position() // 1000))
      end
   end
   for field, want in expected do
      table.insert(parts, field .. "=" .. tostring(want.value))
   end
   return table.concat(parts, "\u{1f}")
end

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
      local block_sig = if block.search then sig .. "\u{1f}" .. search.signature(block.search) else sig
      if glance then
         block_sig ..= "\u{1f}glance"
      end
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
      elseif ev.act == "seekto" and index then
         local length = snap and snap.track and snap.track.length_ms
         if length then
            -- The cell's middle, so the first and last cells aren't 0 % and 100 % exactly.
            local count = math.clamp(block.cx.cols - 24, 16, 160)
            seek(block, (index - 0.5) / count * length)
         end
      else
         act(block, ev.act)
      end
      block.signature = ""
   end,
})
