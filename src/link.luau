--!strict
-- The link between the plugin and its bridge (bridge/bridge.js): a long-running process that
-- drives the TIDAL desktop app over the Chrome DevTools protocol. It runs on TIDAL's own Electron
-- binary in Node mode, so nothing else is needed. Tern can only run processes to completion, so
-- the plugin and the bridge talk through files in the plugin's data directory:
--
--   now.json        bridge → plugin  Snapshot below, replaced atomically; `beat` is unix seconds.
--   inbox/<id>.cmd  plugin → bridge  One command: `<op> <arg>`. The id starts with unix seconds;
--                                     the bridge drops commands older than 10 s and answers the
--                                     latest in the snapshot's `reply`.
--   alive           plugin → bridge  Unix seconds of the plugin's last check-in. The bridge exits
--                                     once it is 30 s old.
--
-- Ops: toggle, pause, next, prev, seek <ms>, shuffle on|off, repeat off|all|one, volume <0-100>,
-- mute on|off, like (current track), radio (current track's), artist-radio <artist id>,
-- play <track|album|artist|playlist> <id>, queue-next|queue-last <track|album> <id>,
-- jump <queue index>, move <from> <to>, remove <queue uid>, sleep <minutes|track|off>,
-- search <query> and list <artist|album> <id> (answers go to search.json as {id, query, list?,
-- title?, subtitle?, items|error}), lyrics <track id> (to lyrics.json as {id, track, lines|text}),
-- launch (start TIDAL with remote control), relaunch (restart it with remote control, resuming
-- playback). When TIDAL runs without remote control, the bridge reaches it through its main
-- process instead; it restarts TIDAL by itself only if that fails too.

local link = {}

export type Track = {
   id: string?,
   title: string,
   artist: string,
   album: string,
   length_ms: number?,
   -- For the artist and album lists.
   artist_id: string?,
   album_id: string?,
   -- In your collection.
   liked: boolean,
}

-- User settings shared by the window half (palette commands) and the host half (the block), in the
-- plugin's kv store: `lyrics` (show lyrics instead of the queue), `notify` (toast on track change).
function link.setting(name: string): boolean
   local ok, value = pcall(tern.kv.get, "setting:" .. name)
   return ok and value == true
end

function link.set_setting(name: string, value: boolean)
   pcall(tern.kv.set, "setting:" .. name, value)
end

export type Snapshot = {
   v: number,
   os: string,
   beat: number,
   -- Whether the TIDAL app is running.
   app: boolean,
   -- Why the bridge can't drive TIDAL.
   problem: string?,
   -- TIDAL runs without remote control; `relaunch` fixes it.
   relaunch: boolean?,
   -- TIDAL is being (re)started with remote control.
   starting: boolean?,
   track: Track?,
   playing: boolean,
   position_ms: number?,
   -- Changes whenever the position jumps rather than advancing with time.
   timeline: number,
   shuffle: boolean?,
   ["repeat"]: string?,
   volume: number?,
   muted: boolean?,
   can: {
      toggle: boolean,
      next: boolean,
      prev: boolean,
      seek: boolean,
      shuffle: boolean,
      ["repeat"]: boolean,
      volume: boolean,
   },
   -- `tone`: whether the cover's top-right corner (under the format badge) is light or dark.
   cover: { key: string, file: string?, url: string?, tone: string? }?,
   -- TIDAL's stream quality (LOSSLESS, HI_RES_LOSSLESS, …).
   quality: string?,
   -- What the player streams: "24-bit 48 kHz FLAC".
   format: string?,
   -- Where the queue came from (a playlist, album or mix name).
   source: string?,
   -- The next track in the queue, when TIDAL has its details.
   next: { title: string, artist: string }?,
   -- The queue around the current track: `items[current]` (1-based in Luau: current + 1) is playing;
   -- `position` is its index in the whole queue of `total`. Titles are nil until TIDAL loads them.
   queue: {
      current: number,
      position: number,
      total: number,
      -- `uid` names the entry for remove; titles are nil until TIDAL loads them.
      items: { { uid: string, id: string, title: string?, artist: string, length_s: number? } },
   }?,
   reply: { id: string, error: string? }?,
   -- The sleep timer: pauses at `at_s` (unix seconds), or when the current track ends.
   sleep: { at_s: number?, end_of_track: boolean? }?,
}

local DATA = tern.plugin.data
local SEP = if tern.runtime.os == "windows" then "\\" else "/"
local NOW = DATA .. SEP .. "now.json"
local INBOX = DATA .. SEP .. "inbox"
local ALIVE = DATA .. SEP .. "alive"

local STALE_S = 5
local CHECK_IN_EVERY_S = 10
local START_GRACE_S = 15

local function path(...: string): string
   return table.concat({ ... }, SEP)
end

function link.read(): Snapshot?
   local ok, text = pcall(tern.fs.read, NOW, 1024 * 1024)
   if not ok then
      return nil
   end
   local decoded, snap = pcall(tern.json.decode, text)
   if not decoded or type(snap) ~= "table" or snap.v ~= 1 then
      return nil
   end
   return snap :: Snapshot
end

function link.fresh(snap: Snapshot?): boolean
   return snap ~= nil and os.time() - snap.beat <= STALE_S
end

-- Starting --------------------------------------------------------------------------------------

local checked_in_at = -math.huge
local started_at = -math.huge
local start_problem: string? = nil

local function tail(file: string): string?
   local ok, text = pcall(tern.fs.read, file, 64 * 1024)
   if not ok then
      return nil
   end
   local lines = {}
   for line in string.gmatch(text, "[^\r\n]+") do
      table.insert(lines, line)
   end
   if #lines == 0 then
      return nil
   end
   return table.concat(lines, "\n", math.max(1, #lines - 3))
end

-- The TIDAL desktop app's Electron binary; the bridge runs on it and launches it.
local function find_app(): (string?, string?)
   local os_name = tern.runtime.os
   local candidates: { string } = {}
   if os_name == "windows" then
      -- Squirrel installs each version in its own app-<version> directory.
      local root = path(tern.getenv("LOCALAPPDATA") or "", "TIDAL")
      local ok, names = pcall(tern.fs.list, root)
      local best: { number }? = nil
      local best_name: string? = nil
      for _, name in if ok then names else {} do
         local version = string.match(name, "^app%-([%d%.]+)$")
         if version then
            local parts = {}
            for n in string.gmatch(version, "%d+") do
               table.insert(parts, tonumber(n) :: number)
            end
            local newer = best == nil
            if best then
               for i = 1, math.max(#parts, #best) do
                  local a, b = parts[i] or 0, best[i] or 0
                  if a ~= b then
                     newer = a > b
                     break
                  end
               end
            end
            if newer then
               best, best_name = parts, name
            end
         end
      end
      if best_name then
         table.insert(candidates, path(root, best_name, "TIDAL.exe"))
      end
   elseif os_name == "macos" then
      table.insert(candidates, "/Applications/TIDAL.app/Contents/MacOS/TIDAL")
      table.insert(candidates, path(tern.getenv("HOME") or "", "Applications", "TIDAL.app", "Contents", "MacOS", "TIDAL"))
   elseif os_name == "linux" then
      -- TIDAL has no Linux app; tidal-hifi wraps the same web player in Electron.
      table.insert(candidates, "/opt/tidal-hifi/tidal-hifi")
      table.insert(candidates, "/usr/lib/tidal-hifi/tidal-hifi")
      table.insert(candidates, "/usr/share/tidal-hifi/tidal-hifi")
   else
      return nil, "TIDAL control isn't available on " .. os_name .. "."
   end
   for _, candidate in candidates do
      if tern.fs.exists(candidate) then
         return candidate, nil
      end
   end
   return nil, if os_name == "linux"
      then "tidal-hifi wasn't found in /opt, /usr/lib or /usr/share."
      else "The TIDAL desktop app wasn't found."
end

local function start()
   local app, why = find_app()
   if app == nil then
      start_problem = why
      return
   end
   local at = os.time()
   local argv = { app, path(tern.plugin.dir, "bridge", "bridge.js"), DATA, app }
   -- cwd outside the plugin directory: on Windows a process's cwd can't be replaced, which would
   -- block `tern plugin install --force` while the bridge runs.
   local options = { cwd = DATA, env = { ELECTRON_RUN_AS_NODE = "1" } }
   local ok, err = pcall(tern.process.run, argv, options, function(result: ProcessResult)
      -- A second bridge exits 0 at once; only an early failure means the bridge can't run.
      if result.status ~= 0 and os.time() - at < START_GRACE_S then
         local detail = tail(path(DATA, "bridge.log")) or (if result.stderr ~= "" then result.stderr else nil)
         start_problem = "The TIDAL bridge stopped (exit " .. tostring(result.status) .. ")."
            .. (if detail then "\n" .. detail else "")
      end
   end)
   if not ok then
      start_problem = "Couldn't start the TIDAL bridge: " .. tostring(err)
   end
end

-- Checks in with the bridge and starts one when none is answering. Returns why the bridge can't
-- run, when that's known.
function link.ensure(snap: Snapshot?): string?
   local now = os.time()
   if now - checked_in_at >= CHECK_IN_EVERY_S and pcall(tern.fs.write, ALIVE, tostring(now)) then
      checked_in_at = now
   end
   if link.fresh(snap) then
      start_problem = nil
      return nil
   end
   if now - started_at >= START_GRACE_S then
      started_at = now
      start_problem = nil
      start()
   end
   return start_problem
end

-- Forgets a failed start so the next `ensure` tries again.
function link.retry()
   started_at = -math.huge
   start_problem = nil
end

local counter = 0

-- Queues a command for the bridge; returns its id, which comes back in the snapshot's `reply`.
function link.send(op: string, arg: (string | number)?): string
   counter += 1
   -- Fixed-width parts, so the bridge's name sort is send order.
   local id = string.format("%d-%08d%04d", os.time(), counter, math.random(0, 9999))
   pcall(tern.fs.mkdir, INBOX)
   tern.fs.write(path(INBOX, id .. ".cmd"), op .. (if arg ~= nil then " " .. tostring(arg) else "") .. "\n")
   link.ensure(link.read())
   return id
end

-- The kv key under which the window half reports a player pane's { floating, focused }: the host
-- half only learns those from it.
function link.view_key(pane: number): string
   return "view:" .. tostring(pane)
end

export type PaneView = { floating: boolean, focused: boolean }

function link.pane_view(pane: number): PaneView
   local ok, value = pcall(tern.kv.get, link.view_key(pane))
   if ok and type(value) == "table" then
      return { floating = value.floating == true, focused = value.focused == true }
   end
   return { floating = false, focused = false }
end

-- Formatting -------------------------------------------------------------------------------------

function link.clock(ms: number?): string
   if ms == nil then
      return "–:––"
   end
   local s = math.max(0, ms // 1000)
   if s >= 3600 then
      return string.format("%d:%02d:%02d", s // 3600, s // 60 % 60, s % 60)
   end
   return string.format("%d:%02d", s // 60, s % 60)
end

function link.shorten(text: string, chars: number): string
   local length = utf8.len(text)
   if length == nil or length <= chars then
      return text
   end
   return string.sub(text, 1, (utf8.offset(text, chars) :: number) - 1) .. "…"
end

-- The address TIDAL's own Share button gives for an item (kind: track, album, artist or playlist).
function link.share_url(kind: string, id: string): string
   return "https://tidal.com/" .. kind .. "/" .. id
end

return link
