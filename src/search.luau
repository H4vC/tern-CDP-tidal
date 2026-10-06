--!strict
-- The panel under the player: a search (results follow the typing from the third character on) or
-- an artist's top tracks / an album's tracks. One line per item; ↑↓ pick, Enter plays,
-- Shift+Enter plays next, Ctrl+Enter adds to the end of the queue, Esc closes. The bridge looks
-- things up inside TIDAL and writes the answers to search.json.

local link = require("./link")
local ui = tern.ui

local search = {}

-- Searches start at this many characters (Enter searches shorter queries too)...
local MIN_CHARS = 3
-- ...once typing has paused this long, so a burst of keys sends one search.
local TYPE_PAUSE_MS = 150
local RESULTS = tern.plugin.data .. (if tern.runtime.os == "windows" then "\\" else "/") .. "search.json"

export type Item = { kind: string, id: string, title: string, detail: string, length_s: number? }

-- What a key or click asks the player to do with an item.
export type Pick = { op: string, item: Item }

-- An artist's top tracks or an album's tracks; title and subtitle arrive with the items.
export type List = { kind: string, id: string, title: string?, subtitle: string? }

export type State = {
   -- The key that opened search, and when (see `search.open`).
   trigger: string?,
   opened_at: number,
   query: string,
   -- Typing goes to the query; otherwise keys move through the results.
   editing: boolean,
   typed_at: number,
   -- Search even below MIN_CHARS (Enter on a short query).
   force: boolean,
   -- The query last sent, and the command id its results come back under.
   sent: string,
   waiting: string?,
   -- Order of every lookup sent, so a late answer to an older one never replaces a newer one.
   order: { [string]: number },
   shown: number,
   items: { Item },
   selected: number,
   error: string?,
   -- Showing a list instead of search results; typing goes back to searching.
   list: List?,
}

-- `trigger` is the character of the key that opened search: Tern can deliver that key's text right
-- after the key itself, and it must not land in the query.
function search.open(trigger: string?): State
   return {
      trigger = trigger,
      opened_at = tern.now(),
      query = "",
      editing = true,
      typed_at = 0,
      force = false,
      sent = "",
      waiting = nil,
      order = {},
      shown = 0,
      items = {},
      selected = 1,
      error = nil,
      list = nil,
   }
end

local sent_count = 0

local function track(st: State, id: string)
   sent_count += 1
   st.order[id] = sent_count
   st.waiting = id
end

-- Opens (or switches the panel to) an artist's top tracks or an album's tracks.
function search.open_list(st: State?, kind: string, id: string, send: (op: string, arg: string) -> string): State
   local state = st or search.open()
   state.list = { kind = kind, id = id }
   state.query, state.sent, state.editing = "", "", false
   state.items, state.selected, state.error = {}, 1, nil
   track(state, send("list", kind .. " " .. id))
   return state
end

-- Sends the query once typing pauses, and picks up answers that arrived. Returns true when the
-- view changed.
function search.poll(st: State, send: (op: string, arg: string) -> string): boolean
   local query = string.match(st.query, "^%s*(.-)%s*$") :: string
   local long_enough = st.force or (utf8.len(query) or #query) >= MIN_CHARS
   if query ~= st.sent and long_enough and tern.now() - st.typed_at >= TYPE_PAUSE_MS then
      st.sent = query
      st.force = false
      st.list = nil
      track(st, send("search", query))
      return true
   end
   if query == "" and st.list == nil and #st.items > 0 then
      st.sent, st.items, st.waiting, st.error = "", {}, nil, nil
      return true
   end
   if st.waiting == nil then
      return false
   end
   local ok, text = pcall(tern.fs.read, RESULTS, 1024 * 1024)
   if not ok then
      return false
   end
   local decoded, result = pcall(tern.json.decode, text)
   if not decoded or type(result) ~= "table" then
      return false
   end
   -- Results for an earlier query still show while the latest one is on its way.
   local rank = st.order[result.id]
   if rank == nil or rank <= st.shown then
      return false
   end
   st.shown = rank
   if result.id == st.waiting then
      st.waiting = nil
   end
   st.error = result.error
   st.items = result.items or {}
   st.selected = math.clamp(st.selected, 1, math.max(1, #st.items))
   local list = st.list
   if list and result.list then
      list.title, list.subtitle = result.title, result.subtitle
   end
   return true
end

local function drop_last_char(text: string): string
   local last = utf8.offset(text, -1)
   return if last then string.sub(text, 1, last - 1) else ""
end

-- Tracks and albums can go into the queue; artists and playlists only play.
function search.queueable(item: Item): boolean
   return item.kind == "track" or item.kind == "album"
end

-- Handles a key; returns "close", a pick, true when handled, or false.
function search.key(st: State, key: Key): (string | Pick | boolean)
   local name = key.name
   -- Without results, ↑↓ have nothing to move through: they stay the player's volume keys.
   if (name == "up" or name == "down") and #st.items == 0 then
      return false
   end
   if name == "escape" or name == "esc" then
      return "close"
   elseif name == "enter" then
      local item = st.items[st.selected]
      local query = string.match(st.query, "^%s*(.-)%s*$") :: string
      if item and (query == st.sent or st.list) then
         if key.shift and search.queueable(item) then
            return { op = "queue-next", item = item }
         elseif key.ctrl and search.queueable(item) then
            return { op = "queue-last", item = item }
         end
         return { op = "play", item = item }
      end
      -- Results are for another query, or none were asked for yet: search now.
      st.force = query ~= ""
      st.typed_at = 0
      return true
   elseif key.ctrl or key.alt or key.meta then
      return false
   elseif name == "down" or (not st.editing and key.text == "j") then
      st.editing = false
      st.selected = math.min(st.selected + 1, math.max(1, #st.items))
      return true
   elseif name == "up" or (not st.editing and key.text == "k") then
      st.selected = math.max(1, st.selected - 1)
      return true
   elseif name == "backspace" then
      st.editing = true
      st.query = drop_last_char(st.query)
      st.typed_at = tern.now()
      return true
   end
   local text = key.text or (if name == "space" then " " else nil)
   -- An empty query has nothing to separate: space stays play/pause, and ? opens the player's help.
   if (text == " " or text == "?") and st.query == "" then
      return false
   end
   if text and text ~= "" then
      if text == st.trigger and st.query == "" and tern.now() - st.opened_at < 200 then
         st.trigger = nil
         return true
      end
      st.editing = true
      st.query ..= text
      st.selected = 1
      st.typed_at = tern.now()
      return true
   end
   return false
end

local function with(node: Node, props: { [string]: any }): Node
   local p: { [string]: any } = node.p or {}
   for k, v in props do
      p[k] = v
   end
   node.p = p
   return node
end

local function small_button(key: string, label: string, action: string, lit: boolean?): Node
   return with(ui.text({ ui.span(label) }), {
      key = key,
      role = "tidal-row-button",
      tone = if lit then "accent" else nil,
      actions = { click = action },
   })
end

local KIND = { track = "♪", album = "◎", artist = "☺", playlist = "≡" }

-- What's playing, so the panel can mark it: the track id, and the queue's source (its type and id,
-- a mix's kind and the source's name).
export type Playing = { track: string?, type: string?, id: string?, mix: string?, name: string? }

-- Whether the queue plays from this item (an album, playlist or artist you can see in the list).
local function is_source(now: Playing, kind: string, id: string): boolean
   return kind ~= "track" and now.type == kind and now.id == id
end

local function heading(st: State, now: Playing): Node
   local list = st.list
   if list and st.query == "" then
      local spans: { Span } = {
         ui.span((KIND[list.kind] or "·") .. " ", "dim"),
         ui.span(list.title or "…", "strong"),
      }
      if list.subtitle and list.subtitle ~= "" then
         table.insert(spans, ui.span(" · " .. list.subtitle, "muted"))
      end
      if st.waiting then
         table.insert(spans, ui.span("   loading…", "dim"))
      elseif st.error then
         table.insert(spans, ui.span("   " .. st.error, "dim"))
      end
      local row: { Node } = { with(ui.text(spans), { key = "title", role = "tidal-line" }) }
      -- Lit while the queue plays this list, or (radio) this artist's mix, which TIDAL names after them.
      table.insert(row, small_button("playall", "play all", "playall", is_source(now, list.kind, list.id)))
      if list.kind == "artist" then
         local radio = now.mix == "ARTIST_MIX" and list.title ~= nil and now.name == list.title
         table.insert(row, small_button("artistradio", "radio", "artistradio", radio))
      end
      table.insert(row, small_button("back", "esc", "closesearch"))
      return with(ui.row(row), { key = "query", role = "tidal-list-heading" })
   end
   local short = (utf8.len(st.query) or #st.query) < MIN_CHARS
   local status = if st.waiting then "searching…"
      elseif st.error then st.error
      elseif st.sent ~= "" and #st.items == 0 then "no results"
      elseif st.query == "" and #st.items == 0 then "type to search · esc for the letter shortcuts · ? help"
      elseif short and #st.items == 0 then "results from 3 letters · enter searches now"
      else "enter plays · shift+enter next · ctrl+enter queue · esc closes"
   return with(ui.text({
      ui.span("/ ", "dim"),
      ui.span(st.query .. (if st.editing then "▏" else ""), "strong"),
      ui.span("   " .. status, "dim"),
   }), { key = "query", role = "tidal-line tidal-query" })
end

-- `rows` caps how many items show; the rest are summarised in one line. What's playing (`now`)
-- shows in the accent colour: the track, and the album, playlist or artist the queue plays from.
function search.view(st: State, rows: number, now: Playing): Node
   local lines: { Node } = { heading(st, now) }
   local shown = math.min(#st.items, math.max(1, rows))
   for i = 1, shown do
      local item = st.items[i]
      local selected = i == st.selected
      local spans: { Span } = {
         ui.span((KIND[item.kind] or "·") .. " ", "dim"),
         ui.span(item.title, if selected then "strong" else nil),
      }
      if item.detail ~= "" then
         table.insert(spans, ui.span(" · " .. item.detail, "muted"))
      end
      if item.length_s then
         table.insert(spans, ui.span("  " .. link.clock(item.length_s * 1000), "dim"))
      end
      local current = (item.kind == "track" and now.track ~= nil and item.id == now.track) or is_source(now, item.kind, item.id)
      local row: { Node } = {
         with(ui.text(spans), {
            key = "label",
            role = if current then "tidal-line tidal-row-label tidal-now" else "tidal-line tidal-row-label",
            actions = { click = "pick=" .. i },
         }),
      }
      if search.queueable(item) then
         table.insert(row, small_button("next", "next", "qnext=" .. i))
         table.insert(row, small_button("last", "+queue", "qlast=" .. i))
      end
      table.insert(row, small_button("link", "link", "qlink=" .. i))
      table.insert(lines, with(ui.row(row), {
         key = "r" .. i,
         role = if selected then "tidal-row tidal-result tidal-selected" else "tidal-row tidal-result",
      }))
   end
   if #st.items > shown then
      table.insert(lines, with(ui.text({ ui.span(string.format("  +%d more", #st.items - shown), "dim") }), {
         key = "more",
         role = "tidal-line",
      }))
   end
   return with(ui.col(lines), { key = "search", role = "tidal-search" })
end

-- Whether the panel has items (results or a list) to take the space under the player.
function search.busy(st: State): boolean
   return #st.items > 0 or st.waiting ~= nil or st.list ~= nil
end

function search.signature(st: State): string
   local list = st.list
   local parts = {
      st.query,
      tostring(st.editing),
      tostring(st.selected),
      st.waiting or "",
      st.error or "",
      st.sent,
      tostring(st.shown),
      if list then list.kind .. list.id .. (list.title or "") else "",
   }
   return table.concat(parts, "\u{1f}")
end

return search
