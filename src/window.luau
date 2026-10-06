--!strict
-- Window side: palette commands and the now-playing status segment.

local link = require("./link")

local KIND = "tidal.player"
local TICK_MS = 1000

local function is_player(pane: PaneInfo): boolean
   return pane.block == KIND or pane.block == "plugin." .. KIND
end

local function open_player(cx: WindowCx)
   for _, pane in cx.session:panes() do
      if is_player(pane) then
         cx.layout:focus(pane.pane)
         return
      end
   end
   local pane = cx:new_block(KIND, nil, "beside")
   if pane == nil then
      cx:toast("error", "TIDAL isn't loaded on this host", "Install the plugin where your panes run.")
      return
   end
   -- A small picture in picture in the corner, out of the way of the work.
   cx.layout:float(pane, nil, "br")
end

tern.command({ id = "open", title = "TIDAL: Open player", icon = "wave", run = open_player })

if tern.runtime.os == "ios" then
   return
end

-- Command id → whether this window sent it, to toast the bridge's answer here.
local mine: { [string]: boolean } = {}
local answered: string? = nil

local function send(op: string, arg: (string | number)?)
   mine[link.send(op, arg)] = true
end

-- A palette command; `run` gets the latest snapshot, for commands that toggle from the current state.
local function command(id: string, title: string, icon: string, run: (snap: link.Snapshot?, cx: WindowCx) -> ())
   tern.command({
      id = id,
      title = "TIDAL: " .. title,
      icon = icon,
      run = function(cx: WindowCx)
         run(link.read(), cx)
      end,
   })
end

local function simple(id: string, title: string, icon: string, op: string, arg: string?)
   command(id, title, icon, function()
      send(op, arg)
   end)
end

simple("toggle", "Play/Pause", "play", "toggle")
simple("next", "Next track", "frame-next", "next")
simple("previous", "Previous track", "frame-prev", "prev")
simple("like", "Like / unlike this track", "heart", "like")
simple("radio", "Track radio", "broadcast", "radio")
simple("discovery", "Play My Daily Discovery", "sparkle", "discovery")
command("shuffle", "Toggle shuffle", "swap", function(snap)
   send("shuffle", if snap and snap.shuffle then "off" else "on")
end)
local NEXT_REPEAT = { off = "all", all = "one", one = "off" }
command("repeat", "Cycle repeat", "repeat", function(snap)
   send("repeat", NEXT_REPEAT[(snap and snap["repeat"]) or "off"] or "off")
end)
command("mute", "Mute / unmute", "slash-circle", function(snap)
   send("mute", if snap and snap.muted then "off" else "on")
end)
command("artist-radio", "Artist radio", "broadcast", function(snap, cx)
   local id = snap and snap.track and snap.track.artist_id
   if id then
      send("artist-radio", id)
   else
      cx:toast("info", "TIDAL", "Nothing is playing")
   end
end)
simple("sleep-15", "Sleep in 15 minutes", "moon", "sleep", "15")
simple("sleep-30", "Sleep in 30 minutes", "moon", "sleep", "30")
simple("sleep-60", "Sleep in 60 minutes", "moon", "sleep", "60")
simple("sleep-track", "Sleep at the end of this track", "moon", "sleep", "track")
simple("sleep-off", "Cancel the sleep timer", "moon", "sleep", "off")
command("lyrics", "Show lyrics / queue", "text-quote", function(_snap, cx)
   local on = not link.setting("lyrics")
   link.set_setting("lyrics", on)
   cx:toast("info", "TIDAL", if on then "The player shows lyrics" else "The player shows the queue")
end)
command("notify", "Toggle track-change notifications", "bell", function(_snap, cx)
   local on = not link.setting("notify")
   link.set_setting("notify", on)
   cx:toast("info", "TIDAL", if on then "Notifying on track changes" else "Track-change notifications off")
end)

local segment: StatusSegment? = nil

local function segment_of(snap: link.Snapshot?): StatusSegment?
   if not (snap and link.fresh(snap) and snap.app and snap.track) then
      return nil
   end
   local track = snap.track :: link.Track
   local text = link.shorten(track.title, 32)
   if track.artist ~= "" then
      text ..= " · " .. link.shorten(track.artist, 24)
   end
   return {
      text = text,
      icon = if snap.playing then "play" else "pause",
      tone = if snap.playing then nil else "muted",
      command = "plugin.tidal.open",
   }
end

tern.chrome.status(function(_pane: StatusPaneInfo): { StatusSegment }?
   return if segment then { segment :: StatusSegment } else nil
end)

local function player_focused(cx: WindowCx): boolean
   for _, pane in cx.session:panes() do
      if is_player(pane) and pane.focused then
         return true
      end
   end
   return false
end

local announced: string? = nil

local function tick(cx: WindowCx?)
   local snap = link.read()
   link.ensure(snap)
   local reply = snap and snap.reply
   if cx and reply and reply.id ~= answered then
      answered = reply.id
      if mine[reply.id] then
         mine[reply.id] = nil
         if reply.error then
            cx:toast("error", "TIDAL", reply.error)
         end
      end
   end
   local track: link.Track? = if snap and link.fresh(snap) then snap.track else nil
   local key = if track then (track.id or track.title) else nil
   if key ~= announced then
      -- The first track seen is the one already playing, not a change.
      if cx and key and announced and link.setting("notify") and not player_focused(cx) then
         local t = track :: link.Track
         cx:toast("info", t.title, if t.artist ~= "" then t.artist else nil)
      end
      announced = key
   end
   local next_segment = segment_of(snap)
   local a, b = next_segment, segment
   if (a == nil) ~= (b == nil) or (a and b and (a.text ~= b.text or a.icon ~= b.icon)) then
      segment = next_segment
      tern.chrome.refresh()
   end
   tern.timer(TICK_MS, tick)
end

tern.timer(TICK_MS, tick)

-- Only the window knows whether a player floats and whether it has focus; it tells the host half
-- through the shared kv store, per pane. The host shows a glance (preview) while floating without
-- focus, and opens search when the player gains focus.
local VIEW_CHECK_MS = 250
local published: { [number]: string } = {}

local function publish_views(cx: WindowCx)
   local seen: { [number]: boolean } = {}
   for _, pane in cx.session:panes() do
      if is_player(pane) then
         local floating, focused = pane.floating == true, pane.focused == true
         local key = tostring(floating) .. tostring(focused)
         seen[pane.pane] = true
         if published[pane.pane] ~= key then
            published[pane.pane] = key
            pcall(tern.kv.set, link.view_key(pane.pane), { floating = floating, focused = focused })
         end
      end
   end
   for pane in published do
      if not seen[pane] then
         published[pane] = nil
         pcall(tern.kv.set, link.view_key(pane), nil)
      end
   end
end

tern.on("focus", function(_event: FocusEvent, cx: WindowCx)
   publish_views(cx)
end)

local function view_tick(cx: WindowCx?)
   if cx then
      publish_views(cx)
   end
   tern.timer(VIEW_CHECK_MS, view_tick)
end

tern.timer(VIEW_CHECK_MS, view_tick)
