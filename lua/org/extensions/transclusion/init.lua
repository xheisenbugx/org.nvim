---@mod org.extensions.transclusion Live transclusion (org-transclusion)
---
--- Shows the text a `#+transclude: [[link]]` keyword points to, with
--- org-transclusion's keyword syntax. By default the text is drawn as
--- virtual lines under the keyword, so the file is never touched;
--- `transclusion_add` inserts it into the buffer instead, like Emacs, and
--- it is taken out again while the file is written. `transclusion_edit`
--- opens the source in a float whose `:write` updates the source and every
--- transclusion of it. See `:h org-extensions-transclusion`.
---
--- ```lua
--- require("org").setup({ extensions = { transclusion = {} } })
--- ```
---
--- Inserted text is tracked by an extmark on its keyword line and one on
--- each inserted line, all with `invalidate`: a line whose mark is valid
--- is transcluded text and never reaches the file, whatever edits, undo or
--- redo did to the buffer (undo brings the marks back with their text).

local edit = require("org.extensions.transclusion.edit")
local highlight = require("org.extensions.transclusion.highlight")
local keyword = require("org.extensions.transclusion.keyword")
local source = require("org.extensions.transclusion.source")
local utils = require("org.utils")

local M = {}

local MOD = "org.extensions.transclusion"

M.keyword = keyword
M.source = source

--- See :h org-extensions-stability (scripts/extension_report.lua measures it).
M.stability = "stable"

M.defaults = {
  --- How transclusions show when an org buffer is opened: "virtual"
  --- (virtual lines under the keyword; the buffer text is untouched),
  --- "materialized" (inserted into the buffer like Emacs
  --- org-transclusion-add-all, and removed while writing) or false
  --- (nothing until `transclusion_toggle` or `transclusion_add`).
  mode = "virtual",
  --- Element types always left out of org text
  --- (org-transclusion-exclude-elements); `:exclude-elements` adds more.
  exclude_elements = { "property-drawer" },
  --- Include the text before the first headline when a whole org file is
  --- transcluded (org-transclusion-include-first-section).
  include_first_section = true,
  --- Expand `#+transclude:` keywords inside transcluded text.
  nested = true,
  --- How deep nested transclusions go; deeper ones (and cycles) are left
  --- as keywords and reported.
  max_depth = 5,
  --- Longest transclusion drawn as virtual lines; the rest is summarized.
  max_virtual_lines = 400,
  --- Left border of virtual lines.
  border = "│ ",
  --- Sign on materialized lines (false for none), like org-transclusion's
  --- fringe indicator.
  sign = "▎",
  --- Show where the text comes from at the end of the keyword line.
  show_source = true,
  --- Redraw when a source buffer changes, not only when it is written.
  live = true,
  --- Watch source files that aren't loaded for changes made outside
  --- Neovim (only while a buffer showing them is loaded).
  watch = true,
  --- Milliseconds to wait before redrawing after a change.
  debounce = 150,
  --- Expand `#+transclude:` keywords when exporting.
  export = true,
  --- Key that edits the transclusion under the cursor (on its keyword or
  --- its materialized text); elsewhere the key keeps its meaning. false
  --- for none.
  edit_key = "<CR>",
  --- The window of `transclusion_edit`: `window` is "float" or an Ex
  --- command such as "split", "vsplit" or "tabnew"; `width` and `height`
  --- are columns/lines or fractions of the screen. With `live`, the source
  --- (and every transclusion of it) follows as you type, like
  --- org-transclusion-live-sync; `:w` still writes it.
  edit = { window = "float", width = 0.8, height = 0.7, border = "rounded", live = false },
  --- How `transclusion_open_source` shows the source: "edit", "split",
  --- "vsplit" or "tab".
  open_source = "split",
}

local function a(fn, desc)
  return { MOD, fn, desc = desc }
end

M.actions = {
  transclusion_add = a("add", "Transclusion: insert the text at point into the buffer (org-transclusion-add)"),
  transclusion_add_all = a("add_all", "Transclusion: insert every transclusion (org-transclusion-add-all)"),
  transclusion_remove = a("remove", "Transclusion: remove the transclusion at point (org-transclusion-remove)"),
  transclusion_remove_all = a(
    "remove_all",
    "Transclusion: remove inserted transclusions (org-transclusion-remove-all)"
  ),
  transclusion_refresh = a("refresh", "Transclusion: refresh from the sources (org-transclusion-refresh)"),
  transclusion_edit = a("edit", "Transclusion: edit the source in a float (org-transclusion-live-sync-start)"),
  transclusion_open_source = a("open_source", "Transclusion: open the source (org-transclusion-open-source)"),
  transclusion_toggle = a("toggle", "Transclusion: toggle virtual transclusions in the buffer"),
  transclusion_detach = a("detach", "Transclusion: turn the transclusion into a copy (org-transclusion-detach)"),
  transclusion_make_from_link = a(
    "make_from_link",
    "Transclusion: add a #+transclude: for the link at point (org-transclusion-make-from-link)"
  ),
  transclusion_promote = a("promote", "Transclusion: promote the transcluded subtree (:level - 1)"),
  transclusion_demote = a("demote", "Transclusion: demote the transcluded subtree (:level + 1)"),
}

local PROPS = {
  ":level",
  ":only-contents",
  ":no-first-heading",
  ":exclude-elements",
  ":expand-links",
  ":disable-auto",
  ":lines",
  ":src",
  ":rest",
  ":end",
  ":thing-at-point",
  ":noweb-chunk",
}

--- Completion of `:Org transclusion_insert`: a `file:` link first, then
--- keyword properties.
---@param arglead string
---@param cmdline string
---@return string[]
function M.complete_insert(arglead, cmdline)
  local args = cmdline:match("transclusion_insert%s+(.*)$") or ""
  local before = args:sub(1, #args - #arglead)
  if vim.trim(before) == "" then
    if arglead:match("^%[?%[?id:") then
      return {}
    end
    local prefix, path = arglead:match("^(%[?%[?file:)(.*)$")
    if not prefix then
      prefix, path = "file:", arglead
    end
    local base = require("org.links").base_dir(0)
    local absolute = path:match("^[/~]") ~= nil
    local full = absolute and utils.expand(path) or (base .. "/" .. path)
    if path:sub(-1) == "/" then
      full = full .. "/"
    end
    local out = {}
    for _, f in ipairs(vim.fn.glob(vim.fn.escape(full, "*?[]{}") .. "*", false, true)) do
      local shown = absolute and (path:match("^(.*/)") or "") .. vim.fn.fnamemodify(f, ":t") or f:sub(#base + 2)
      out[#out + 1] = prefix .. shown .. (vim.fn.isdirectory(f) == 1 and "/" or "")
    end
    return out
  end
  local out = {}
  for _, p in ipairs(PROPS) do
    if not before:find(vim.pesc(p) .. "%f[^%w%-]") then
      out[#out + 1] = p
    end
  end
  return out
end

M.commands = {
  transclusion_insert = {
    MOD,
    "insert_command",
    desc = "Insert a #+transclude: line: :Org transclusion_insert [[link]] [:level N ...]",
    complete = function(arglead, cmdline)
      return M.complete_insert(arglead, cmdline)
    end,
  },
}

M.mappings = {
  org = {
    transclusion_add = "<prefix>ua",
    transclusion_add_all = "<prefix>uA",
    transclusion_remove = "<prefix>ud",
    transclusion_remove_all = "<prefix>uD",
    transclusion_refresh = "<prefix>ug",
    transclusion_edit = "<prefix>ue",
    transclusion_open_source = "<prefix>uo",
    transclusion_toggle = "<prefix>ut",
    transclusion_detach = "<prefix>uc",
    transclusion_make_from_link = "<prefix>ul",
    transclusion_promote = "<prefix>u<",
    transclusion_demote = "<prefix>u>",
  },
}

M.groups = { { "u", "transclusion" } }

local api = vim.api
local ns = api.nvim_create_namespace("org_transclusion")
local ns_region = api.nvim_create_namespace("org_transclusion_region")
local ns_line = api.nvim_create_namespace("org_transclusion_line")
local ns_hide = api.nvim_create_namespace("org_transclusion_hidden")
local augroup = api.nvim_create_augroup("OrgTransclusion", { clear = true })

M.ns, M.ns_region, M.ns_line = ns, ns_region, ns_line

--- buf -> { virtual, regions = { [anchor mark] = data }, owner = { [line
--- mark] = anchor mark }, gen, sources, sig, tick, keys }. A region's
--- data is { lines, label, sources, kw (its keyword line), marks (its line
--- marks, old ones included: undo can bring them back), removed }.
---@type table<integer, table>
M.buffers = {}

local function opts()
  return require("org.extensions").opts("transclusion") or M.defaults
end

local function enabled()
  return require("org.extensions").enabled("transclusion")
end

local function valid(buf)
  return buf and api.nvim_buf_is_valid(buf) and api.nvim_buf_is_loaded(buf)
end

local function state(buf, create)
  local st = M.buffers[buf]
  if not st and create then
    st = { virtual = opts().mode == "virtual", regions = {}, owner = {}, gen = 0, sources = {}, sig = "", tick = -1 }
    M.buffers[buf] = st
  end
  return st
end

local function define_highlights()
  local function hl(name, val)
    val.default = true
    api.nvim_set_hl(0, name, val)
  end
  hl("OrgTransclusionBorder", { link = "FloatBorder" })
  hl("OrgTransclusionSource", { link = "Comment" })
  hl("OrgTransclusionSign", { link = "Special" })
  hl("OrgTransclusionError", { link = "DiagnosticError" })
end

-- Report a message once (errors in timers and watchers must not spam).
local reported = {}
local function report_once(msg)
  msg = tostring(msg)
  if not reported[msg] then
    reported[msg] = true
    utils.warn("transclusion: " .. msg)
  end
end

---------------------------------------------------------------------------
-- Materialized regions
---------------------------------------------------------------------------

local function touch(st)
  st.gen = st.gen + 1
  st.cache = nil
end

-- run `fn` with the buffer's modified flag kept as it was
local function keep_modified(buf, fn)
  local o = { buf = buf }
  local mod = api.nvim_get_option_value("modified", o)
  local ok, err = pcall(fn)
  if valid(buf) and api.nvim_get_option_value("modified", o) ~= mod then
    api.nvim_set_option_value("modified", mod, o)
  end
  if not ok then
    error(err, 0)
  end
end

local function undojoin(buf)
  api.nvim_buf_call(buf, function()
    pcall(vim.cmd, "undojoin")
  end)
end

-- Whether the buffer is at the tip of its undo tree: false while undo,
-- redo or :earlier walk its history, when the text is what that state
-- had and must be left alone.
local function at_tip(buf)
  local ok, t = pcall(api.nvim_buf_call, buf, vim.fn.undotree)
  return not ok or type(t) ~= "table" or t.seq_cur == t.seq_last
end

local function mark_lines(buf, aid, row0, n)
  local st = M.buffers[buf]
  local data = st.regions[aid]
  local o = opts()
  local sign = o.sign and o.sign ~= "" and o.sign or nil
  for i = 0, n - 1 do
    local id = api.nvim_buf_set_extmark(buf, ns_line, row0 + i, 0, {
      invalidate = true,
      sign_text = sign,
      sign_hl_group = sign and "OrgTransclusionSign" or nil,
    })
    data.marks[#data.marks + 1] = id
    st.owner[id] = aid
  end
  touch(st)
end

-- A new region for the text of the keyword on 1-based `row`, inserted on
-- the lines below it.
local function new_region(buf, row, data)
  local st = M.buffers[buf]
  -- an older region of this keyword (removed, or its text deleted) gives
  -- way: only undo can bring it back now
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ns_region, { row - 1, 0 }, { row - 1, -1 }, {})) do
    if st.regions[m[1]] then
      st.regions[m[1]].removed = true
    end
  end
  data.marks = {}
  data.kw = api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
  local aid = api.nvim_buf_set_extmark(buf, ns_region, row - 1, 0, { invalidate = true })
  st.regions[aid] = data
  mark_lines(buf, aid, row, #data.lines)
  return aid
end

-- Drop the marks of a region for good (its text becomes plain text).
local function forget(buf, aid)
  local st = M.buffers[buf]
  local data = st.regions[aid]
  if not data then
    return
  end
  for _, id in ipairs(data.marks) do
    pcall(api.nvim_buf_del_extmark, buf, ns_line, id)
    st.owner[id] = nil
  end
  pcall(api.nvim_buf_del_extmark, buf, ns_region, aid)
  st.regions[aid] = nil
  touch(st)
end

-- Delete invalid marks of a region that has piled up many (every write
-- and refresh marks the lines again).
local function gc_marks(buf, aid)
  local st = M.buffers[buf]
  local data = st.regions[aid]
  if not data or #data.marks <= 3 * #data.lines + 100 then
    return
  end
  local keep = {}
  for _, id in ipairs(data.marks) do
    local m = api.nvim_buf_get_extmark_by_id(buf, ns_line, id, { details = true })
    if m[1] and not (m[3] and m[3].invalid) then
      keep[#keep + 1] = id
    else
      pcall(api.nvim_buf_del_extmark, buf, ns_line, id)
      st.owner[id] = nil
    end
  end
  data.marks = keep
end

--- Every region of `buf` with text in the buffer, in buffer order:
--- { id, s, e, intact, data, gone, rows, own, stray }. `s` is the 0-based
--- row of the first line of text (the keyword's 1-based row), `e` the last
--- row of the text; `intact` when the lines s..e are exactly the inserted
--- text. Otherwise (after edits) `rows` are the rows still marked as
--- inserted, `own` those between s and e and `stray` the others; `gone`
--- when the keyword line was deleted. Also returns the dormant regions
--- (none of their text is left).
local function collect(buf)
  if buf == 0 then
    buf = api.nvim_get_current_buf()
  end
  local st = M.buffers[buf]
  if not st or not next(st.regions) or not valid(buf) then
    return {}, {}
  end
  local tick = api.nvim_buf_get_changedtick(buf)
  if st.cache and st.cache.tick == tick and st.cache.gen == st.gen then
    return st.cache.list, st.cache.dormant
  end
  local list, slow, dormant = {}, {}, {}
  local anchor_at = {}
  local count = api.nvim_buf_line_count(buf)
  for aid, data in pairs(st.regions) do
    local m = api.nvim_buf_get_extmark_by_id(buf, ns_region, aid, { details = true })
    if m[1] then
      local gone = m[3] and m[3].invalid or false
      local r = { id = aid, data = data, gone = gone, s = m[1] + 1 }
      if not gone then
        anchor_at[m[1]] = aid
      end
      local n = #data.lines
      local fast = false
      if not gone and n > 0 and r.s + n <= count then
        local marks = api.nvim_buf_get_extmarks(buf, ns_line, { r.s, 0 }, { r.s + n - 1, 0 }, {})
        if #marks == n then
          fast = true
          for i, mk in ipairs(marks) do
            if mk[2] ~= r.s + i - 1 or st.owner[mk[1]] ~= aid then
              fast = false
              break
            end
          end
          fast = fast and vim.deep_equal(api.nvim_buf_get_lines(buf, r.s, r.s + n, false), data.lines)
        end
      end
      if fast then
        r.e, r.intact = r.s + n - 1, true
        list[#list + 1] = r
      else
        slow[#slow + 1] = r
      end
    end
  end
  if #slow > 0 then
    local owner_at, rows = {}, {}
    for _, mk in ipairs(api.nvim_buf_get_extmarks(buf, ns_line, 0, -1, { details = true })) do
      local aid = st.owner[mk[1]]
      -- a keyword line is never inserted text, whatever mark a join left
      -- on it
      if aid and not (mk[4] and mk[4].invalid) and not anchor_at[mk[2]] then
        owner_at[mk[2]] = owner_at[mk[2]] or {}
        owner_at[mk[2]][aid] = true
        rows[aid] = rows[aid] or {}
        local rr = rows[aid]
        if rr[#rr] ~= mk[2] then
          rr[#rr + 1] = mk[2]
        end
      end
    end
    for _, r in ipairs(slow) do
      local vr = rows[r.id] or {}
      if #vr == 0 then
        dormant[#dormant + 1] = r
      else
        r.rows, r.own, r.stray = vr, {}, {}
        local e = r.s - 1
        if not r.gone then
          local row, last = r.s, vr[#vr]
          while row <= last do
            local o = owner_at[row]
            if o and o[r.id] then
              e = row
              r.own[row] = true
            elseif o or anchor_at[row] then
              break
            end
            row = row + 1
          end
        end
        r.e = e
        for _, row in ipairs(vr) do
          if not r.own[row] then
            r.stray[#r.stray + 1] = row
          end
        end
        list[#list + 1] = r
      end
    end
  end
  for _, r in ipairs(list) do
    r.data.removed = nil
  end
  table.sort(list, function(x, y)
    return x.s < y.s
  end)
  st.cache = { tick = tick, gen = st.gen, list = list, dormant = dormant, anchors = anchor_at }
  return list, dormant
end

--- Materialized regions of `buf` in buffer order: { id, s, e, intact,
--- data }, `s` the 0-based row of the first inserted line (the keyword's
--- 1-based row) and `e` the last (0-based, inclusive). A region is intact
--- when its lines are exactly the inserted text.
---@param buf integer
---@return table[]
function M.regions(buf)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  local out = {}
  for _, r in ipairs((collect(buf))) do
    if not r.gone and r.e >= r.s then
      out[#out + 1] = r
    end
  end
  return out
end

-- rows (0-based) of `r` that hold inserted text
local function owned_rows(r)
  if r.intact then
    local rows = {}
    for row = r.s, r.e do
      rows[#rows + 1] = row
    end
    return rows
  end
  return r.rows or {}
end

--- Line ranges of inserted (materialized) text in `bufnr`, for other
--- extensions and plugins that must skip it (indexers, linters, language
--- servers): a list of { first, last, keyword } 1-based line numbers,
--- `last` included, `keyword` the line of its `#+transclude:`. Empty when
--- nothing is inserted or the extension is off.
---@param bufnr? integer
---@return { first: integer, last: integer, keyword: integer }[]
function M.ranges(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and api.nvim_get_current_buf() or bufnr
  local out = {}
  if not M.buffers[bufnr] then
    return out
  end
  for _, r in ipairs((collect(bufnr))) do
    local rows = owned_rows(r)
    local first
    for i, row in ipairs(rows) do
      first = first or row
      if rows[i + 1] ~= row + 1 then
        out[#out + 1] = { first = first + 1, last = row + 1, keyword = r.s }
        first = nil
      end
    end
  end
  table.sort(out, function(x, y)
    return x.first < y.first
  end)
  return out
end

--- Lines of `buf` without its materialized text, and a map from those
--- lines to buffer lines (nil when there is nothing materialized).
---@param buf integer
---@return string[], integer[]|nil
function M.clean_lines(buf)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local list = collect(buf)
  if #list == 0 then
    return lines, nil
  end
  local anchors = M.buffers[buf].cache.anchors
  local inside = {}
  for _, r in ipairs(list) do
    for _, row in ipairs(owned_rows(r)) do
      if not anchors[row] then
        inside[row + 1] = true
      end
    end
  end
  local out, map = {}, {}
  for i, l in ipairs(lines) do
    if not inside[i] then
      out[#out + 1] = l
      map[#out] = i
    end
  end
  return out, map
end

-- Delete 0-based `rows` (any order), bottom-up in runs.
local function delete_rows(buf, rows)
  local sorted = vim.deepcopy(rows)
  table.sort(sorted)
  local i = #sorted
  while i >= 1 do
    local e = sorted[i]
    local s = e
    while i > 1 and sorted[i - 1] == s - 1 do
      i = i - 1
      s = sorted[i]
    end
    api.nvim_buf_set_lines(buf, s, e + 1, false, {})
    i = i - 1
  end
end

-- the region whose text starts right below keyword row `row` (1-based)
local function region_below(buf, row)
  for _, r in ipairs(M.regions(buf)) do
    if r.s == row then
      return r
    end
  end
end

-- Put a region's text back where it was edited in place: its marked lines
-- become the inserted text again, lines typed or pasted among them are
-- kept below it, and text joined to its last line (J) goes below too.
local function restore(buf, r)
  local data = r.data
  local n = #data.lines
  local cur = api.nvim_buf_get_lines(buf, r.s, r.e + 1, false)
  local keep = {}
  local last_own
  for i, l in ipairs(cur) do
    if r.own[r.s + i - 1] then
      last_own = i
    elseif data.lines[i] ~= l then
      keep[#keep + 1] = l
    end
  end
  local lo, expect = last_own and cur[last_own], data.lines[n]
  if lo and expect and #lo > #expect and lo:sub(1, #expect) == expect then
    local extra = lo:sub(#expect + 1):gsub("^%s+", "")
    if extra ~= "" then
      table.insert(keep, 1, extra)
    end
  end
  local new = vim.list_extend(vim.deepcopy(data.lines), keep)
  api.nvim_buf_set_lines(buf, r.s, r.e + 1, false, new)
  mark_lines(buf, r.id, r.s, n)
end

--- Check the materialized text. It is read-only, like in Emacs: text
--- edited in place is put back. Text whose keyword was deleted is
--- removed with it; text deleted as a whole leaves the keyword without
--- it. While undo or redo walk the history, the text they bring back is
--- kept as it is.
local function protect(buf)
  local st = M.buffers[buf]
  if not st or st.saving or not next(st.regions) or not valid(buf) then
    return
  end
  local list, dormant = collect(buf)
  local todo = {}
  for _, r in ipairs(list) do
    if not r.intact then
      todo[#todo + 1] = r
    end
  end
  -- text whose marks were lost (deleted and put back without undo) is
  -- taken back when it is exactly the text under its unchanged keyword
  local adopt = {}
  for _, r in ipairs(dormant) do
    if not r.gone and not r.data.removed and #r.data.lines > 0 then
      local n = #r.data.lines
      local got = api.nvim_buf_get_lines(buf, r.s - 1, r.s + n, false)
      if got[1] == r.data.kw and vim.deep_equal(vim.list_slice(got, 2), r.data.lines) then
        adopt[#adopt + 1] = r
      end
    end
  end
  if #todo == 0 and #adopt == 0 then
    return
  end
  for _, r in ipairs(adopt) do
    local marks = api.nvim_buf_get_extmarks(buf, ns_line, { r.s, 0 }, { r.s + #r.data.lines - 1, -1 }, {})
    local free = true
    for _, mk in ipairs(marks) do
      local o = st.owner[mk[1]]
      if o and o ~= r.id then
        local m = api.nvim_buf_get_extmark_by_id(buf, ns_line, mk[1], { details = true })
        free = free and (m[3] and m[3].invalid) or false
      end
    end
    if free then
      mark_lines(buf, r.id, r.s, #r.data.lines)
    end
  end
  if #todo == 0 then
    return
  end
  local tip = at_tip(buf)
  table.sort(todo, function(x, y)
    return x.s > y.s
  end)
  local restored = false
  keep_modified(buf, function()
    local joined = false
    local function join()
      if not joined and tip then
        undojoin(buf)
        joined = true
      end
    end
    for _, r in ipairs(todo) do
      local kw = not r.gone and api.nvim_buf_get_lines(buf, r.s - 1, r.s, false)[1]
      if not kw or not keyword.match(kw) then
        -- the keyword went: its text goes too
        local rows = {}
        for _, row in ipairs(r.rows) do
          if not st.cache or not st.cache.anchors[row] then
            rows[#rows + 1] = row
          end
        end
        if tip then
          join()
          delete_rows(buf, rows)
          r.data.removed = true
        end
      elseif not tip then
        -- undo brought this text back: it is the region's text now
        local lines = {}
        for _, row in ipairs(r.rows) do
          if r.own[row] then
            lines[#lines + 1] = api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
          end
        end
        if #lines > 0 then
          r.data.lines = lines
        end
        r.data.kw = kw
      else
        join()
        local below, above = {}, {}
        for _, row in ipairs(r.stray) do
          if row > r.e then
            below[#below + 1] = row
          elseif row ~= r.s - 1 then
            above[#above + 1] = row
          end
        end
        delete_rows(buf, below)
        if kw ~= r.data.kw and kw:sub(1, #r.data.kw) == r.data.kw then
          -- the first line was joined to the keyword (J)
          api.nvim_buf_set_text(buf, r.s - 1, #r.data.kw, r.s - 1, #kw, {})
        end
        if r.e >= r.s then
          restore(buf, r)
          restored = true
        end
        delete_rows(buf, above)
      end
    end
  end)
  touch(st)
  if restored then
    utils.warn(
      "Transcluded text is read-only: edit its source with transclusion_edit (" .. (opts().edit_key or "") .. ")"
    )
  end
end

-- Text whose keyword and lines were all replaced (a formatter rewrote the
-- whole buffer) lost its marks: find it again by its keyword line and
-- text, and mark it.
local function adopt_gone(buf)
  local st = M.buffers[buf]
  local _, dormant = collect(buf)
  local anchors = st.cache and st.cache.anchors or {}
  local lines
  for _, r in ipairs(dormant) do
    local d = r.data
    if r.gone and not d.removed and #d.lines > 0 then
      lines = lines or api.nvim_buf_get_lines(buf, 0, -1, false)
      for i, l in ipairs(lines) do
        if l == d.kw and not anchors[i - 1] and vim.deep_equal(vim.list_slice(lines, i + 1, i + #d.lines), d.lines) then
          pcall(api.nvim_buf_del_extmark, buf, ns_region, r.id)
          local aid = api.nvim_buf_set_extmark(buf, ns_region, i - 1, 0, { invalidate = true })
          st.regions[aid], st.regions[r.id] = d, nil
          for _, id in ipairs(d.marks) do
            st.owner[id] = aid
          end
          mark_lines(buf, aid, i, #d.lines)
          anchors[i - 1] = aid
          break
        end
      end
    end
  end
end

---------------------------------------------------------------------------
-- Resolving
---------------------------------------------------------------------------

-- 1-based lines of `buf` holding inserted text
local function inside_rows(buf)
  local inside = {}
  for _, r in ipairs(M.regions(buf)) do
    for _, row in ipairs(owned_rows(r)) do
      inside[row + 1] = true
    end
  end
  return inside
end

--- What the keywords of `buf` resolve against: its file and directory, and
--- the level of the headline above each line (inserted text left out).
local function environment(buf, lines, inside)
  lines = lines or api.nvim_buf_get_lines(buf, 0, -1, false)
  inside = inside or inside_rows(buf)
  local name = api.nvim_buf_get_name(buf)
  local env = {
    dir = require("org.links").base_dir(buf),
    filename = name ~= "" and not name:match("^%a[%w+%-]*://") and vim.fs.normalize(name) or nil,
    bufnr = buf,
    levels = {},
  }
  local outline = require("org.parser").outline_level
  local level = 0
  for i, l in ipairs(lines) do
    env.levels[i] = level
    if not inside[i] and l:byte(1) == 42 then
      local stars = l:match("^(%*+) ")
      if stars and outline(l) then
        level = #stars
      end
    end
  end
  return env
end

local function context(env, row, indent)
  return {
    dir = env.dir,
    filename = env.filename,
    bufnr = env.bufnr,
    level = env.levels[row] or 0,
    indent = indent,
    depth = 0,
  }
end

local function resolve_at(buf, row, env)
  local line = api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  local indent, value = keyword.match(line)
  if not indent then
    return nil, "not a #+transclude: line"
  end
  local spec, err = keyword.parse(value)
  if not spec then
    return nil, err
  end
  local ctx = context(env or environment(buf), row, indent)
  local res, rerr = source.frame(source.resolve_cached, spec, ctx)
  return res, rerr, spec, ctx
end

local function open_folds(buf, first, last)
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do
    api.nvim_win_call(w, function()
      pcall(vim.cmd, string.format("silent! %d,%dfoldopen!", first, last))
    end)
  end
end

--- Insert the text of the keyword on `row` (1-based) below it.
---@return boolean ok, string|nil err
local function materialize(buf, row, env)
  local res, err = resolve_at(buf, row, env)
  if not res then
    return false, err
  end
  if #res.lines == 0 then
    return false, "No content found with " .. res.label
  end
  keep_modified(buf, function()
    api.nvim_buf_set_lines(buf, row, row, false, res.lines)
    new_region(buf, row, { lines = res.lines, label = res.label, sources = res.sources })
  end)
  -- the new text shows open, whatever the folds around it
  open_folds(buf, row + 1, row + #res.lines)
  return true
end

-- Replace the text of region `r` by `lines`, changing only the lines that
-- differ (marks, folds and the cursor stay on the others).
local function replace_text(buf, r, lines)
  local old = r.data.lines
  local diff = (vim.text and vim.text.diff) or vim.diff
  local ok, hunks = pcall(diff, table.concat(old, "\n") .. "\n", table.concat(lines, "\n") .. "\n", {
    result_type = "indices",
  })
  if not ok or type(hunks) ~= "table" then
    hunks = { { 1, #old, 1, #lines } }
  end
  for i = #hunks, 1, -1 do
    local h = hunks[i]
    local start = h[2] == 0 and h[1] or h[1] - 1
    api.nvim_buf_set_lines(buf, r.s + start, r.s + start + h[2], false, vim.list_slice(lines, h[3], h[3] + h[4] - 1))
    if h[4] > 0 then
      mark_lines(buf, r.id, r.s + start, h[4])
    end
  end
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

local function source_label(text)
  return { { "  ⇣ " .. text, "OrgTransclusionSource" } }
end

local function virt_chunks(res, max)
  res.chunks = res.chunks or {}
  local c = res.chunks[max]
  if not c then
    local lines = #res.lines > max and vim.list_slice(res.lines, 1, max) or res.lines
    c = res.kind == "org" and highlight.org(lines, res.todo) or highlight.code(lines, res.lang)
    res.chunks[max] = c
  end
  return c
end

local function draw_virtual(buf, row, indent, res, err)
  local o = opts()
  local border = { o.border or "", "OrgTransclusionBorder" }
  local virt = {}
  local function add(chunks)
    local line = {}
    if indent ~= "" then
      line[1] = { indent }
    end
    line[#line + 1] = border
    vim.list_extend(line, chunks)
    virt[#virt + 1] = line
  end
  local label
  if res then
    local max = o.max_virtual_lines or 400
    for _, c in ipairs(virt_chunks(res, max)) do
      add(c)
    end
    if #res.lines > max then
      add({ { string.format("… %d more lines", #res.lines - max), "OrgTransclusionSource" } })
    end
    for _, e in ipairs(res.errors) do
      add({ { e, "OrgTransclusionError" } })
    end
    label = string.format("%s (%d line%s)", res.label, #res.lines, #res.lines == 1 and "" or "s")
  else
    add({ { "transclusion: " .. tostring(err), "OrgTransclusionError" } })
  end
  local mark = { virt_lines = virt, hl_mode = "combine" }
  if label and o.show_source then
    mark.virt_text = source_label(label)
    mark.virt_text_pos = "eol"
  end
  return api.nvim_buf_set_extmark(buf, ns, row - 1, 0, mark)
end

local function draw_region(buf, row, r)
  if opts().show_source then
    return api.nvim_buf_set_extmark(buf, ns, row - 1, 0, {
      virt_text = source_label(r.data.label .. " (inserted)"),
      virt_text_pos = "eol",
      hl_mode = "combine",
    })
  end
end

local function hidden(buf, row)
  return #api.nvim_buf_get_extmarks(buf, ns_hide, { row - 1, 0 }, { row - 1, -1 }, {}) > 0
end

local function signature(sources)
  local keys = vim.tbl_keys(sources)
  table.sort(keys)
  local parts = {}
  for _, p in ipairs(keys) do
    parts[#parts + 1] = source.signature(p)
  end
  return table.concat(parts, "|")
end

local update_watchers
local wrap_key

local function render(buf, st, refresh)
  protect(buf)
  local regs = M.regions(buf)
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local inside = inside_rows(buf)
  local env = environment(buf, lines, inside)
  -- inserted text follows its source (refresh) and its keyword
  local tip
  local changed = false
  for i = #regs, 1, -1 do
    local r = regs[i]
    local kw = lines[r.s]
    if refresh or kw ~= r.data.kw then
      if tip == nil then
        tip = at_tip(buf)
      end
      if kw ~= r.data.kw and not tip then
        r.data.kw = kw
      else
        local res = resolve_at(buf, r.s, env)
        if res and #res.lines > 0 and (kw ~= r.data.kw or not vim.deep_equal(res.lines, r.data.lines)) then
          keep_modified(buf, function()
            if kw ~= r.data.kw then
              undojoin(buf)
            end
            if r.intact then
              replace_text(buf, r, res.lines)
            else
              delete_rows(buf, owned_rows(r))
              api.nvim_buf_set_lines(buf, r.s, r.s, false, res.lines)
              mark_lines(buf, r.id, r.s, #res.lines)
            end
          end)
          r.data.lines, r.data.label, r.data.sources, r.data.kw = res.lines, res.label, res.sources, kw
          changed = true
        else
          r.data.kw = kw
        end
      end
    end
  end
  if changed then
    touch(st)
    regs = M.regions(buf)
    lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    inside = inside_rows(buf)
    env = environment(buf, lines, inside)
  end
  -- Only what changed is drawn again: each mark remembers what it shows
  -- (a result, shared while its sources don't change, or an error).
  local old, drawn, now = {}, st.drawn or {}, {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})) do
    local key = drawn[m[1]]
    if key ~= nil and not old[m[2] + 1] then
      old[m[2] + 1] = { id = m[1], key = key }
    else
      pcall(api.nvim_buf_del_extmark, buf, ns, m[1])
    end
  end
  local function place(row, key, draw)
    local o = old[row]
    old[row] = nil
    if o and o.key == key then
      now[o.id] = key
      return
    elseif o then
      pcall(api.nvim_buf_del_extmark, buf, ns, o.id)
    end
    local id = draw()
    if id then
      now[id] = key
    end
  end
  local below = {}
  for _, r in ipairs(regs) do
    below[r.s] = r
  end
  local ui
  local function text_pad(level)
    if ui == nil then
      local ok, decorations = pcall(require, "org.ui.decorations")
      local uok, u = false, nil
      if ok then
        uok, u = pcall(decorations.ui_options, buf)
      end
      ui = uok and u.indent_mode and { u = u, widths = decorations.indent_widths } or false
    end
    if not ui or not level or level <= 0 then
      return 0
    end
    local _, text = ui.widths(ui.u, level)
    return text
  end
  local sources = {}
  local kws = keyword.scan(lines, function(row)
    return inside[row]
  end)
  for _, kw in ipairs(kws) do
    local r = below[kw.row]
    if r then
      place(kw.row, "r\0" .. r.data.label, function()
        return draw_region(buf, kw.row, r)
      end)
      for p in pairs(r.data.sources or {}) do
        sources[p] = true
      end
    else
      local spec, err = keyword.parse(kw.value)
      local show = st.virtual and not hidden(buf, kw.row) and not (spec and spec.disable_auto)
      -- text under a keyword may be its own, brought back by undo: look
      -- when it is drawn anyway or the buffer had inserted text
      local check = show or next(st.regions) ~= nil or vim.bo[buf].undofile
      local res, adopted
      if spec and check then
        res, err = source.resolve_cached(spec, context(env, kw.row, kw.indent))
      end
      local n = res and #res.lines or 0
      if
        n > 0
        and lines[kw.row + n] ~= nil
        and vim.deep_equal(vim.list_slice(lines, kw.row + 1, kw.row + n), res.lines)
      then
        -- its text is right below it; when undo brought it back (from
        -- before a write, even of an earlier session with 'undofile'),
        -- it is taken back
        if tip == nil then
          tip = at_tip(buf)
        end
        if not tip then
          new_region(buf, kw.row, { lines = res.lines, label = res.label, sources = res.sources })
          place(kw.row, "r\0" .. res.label, function()
            return draw_region(buf, kw.row, { data = { label = res.label } })
          end)
          show, adopted = false, true
        end
      end
      if show then
        -- org-indent-mode: the keyword is drawn after its entry's virtual
        -- indentation, and so is the text under it
        local pad = text_pad(env.levels[kw.row])
        local indent = pad > 0 and string.rep(" ", pad) .. kw.indent or kw.indent
        local key = res or ("e\0" .. tostring(err))
        if pad > 0 or kw.indent ~= "" then
          key = tostring(key) .. "\0" .. indent
        end
        place(kw.row, key, function()
          return draw_virtual(buf, kw.row, indent, res, err)
        end)
      end
      if show or adopted then
        for p in pairs(res and res.sources or {}) do
          sources[p] = true
        end
      end
    end
  end
  for _, o in pairs(old) do
    pcall(api.nvim_buf_del_extmark, buf, ns, o.id)
  end
  st.drawn = now
  st.sources = sources
  st.count = #kws
  st.tick = api.nvim_buf_get_changedtick(buf)
  st.sig = signature(sources)
  local keys = vim.tbl_keys(sources)
  table.sort(keys)
  local key = table.concat(keys, "\n")
  if #kws > 0 then
    wrap_key(buf)
  end
  if key ~= st.srckey then
    st.srckey = key
    update_watchers()
  end
end

--- Draw the transclusions of `buf`. With `refresh`, materialized text is
--- replaced by the current text of its source.
---@param buf? integer
---@param refresh? boolean
function M.render(buf, refresh)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  if not valid(buf) or not enabled() then
    return
  end
  local st = state(buf, true)
  if st.saving then
    return
  end
  source.frame(render, buf, st, refresh)
end

--- Redraw every buffer showing `path` (after it changed).
---@param path string
---@param except? integer
function M.refresh_dependents(path, except)
  path = vim.fs.normalize(path)
  source.clear_cache(path)
  for buf, st in pairs(M.buffers) do
    if buf ~= except and source.source_key(st.sources, path) then
      M.render(buf, true)
    end
  end
end

---------------------------------------------------------------------------
-- Debouncing and watching
---------------------------------------------------------------------------

local timers = {}

local function close_handle(h)
  pcall(function()
    h:stop()
    if not h:is_closing() then
      h:close()
    end
  end)
end

-- Run `fn` once, `debounce` ms after the last call with the same key.
local function later(key, fn)
  local t = timers[key]
  if not t then
    t = vim.uv.new_timer()
    if not t then
      return
    end
    timers[key] = t
  end
  t:stop()
  t:start(
    opts().debounce or 150,
    0,
    vim.schedule_wrap(function()
      if timers[key] == t then
        timers[key] = nil
      end
      close_handle(t)
      if enabled() then
        local ok, err = pcall(fn)
        if not ok then
          report_once(err)
        end
      end
    end)
  )
end

M.later = later

-- directory -> { handle, files = { [basename] = path } }. Directories are
-- watched rather than files: that also sees files saved by renaming.
local watchers = {}
local MAX_WATCHED = 64

--- Number of directories being watched.
function M.watch_count()
  local n = 0
  for _ in pairs(watchers) do
    n = n + 1
  end
  return n
end

update_watchers = function()
  local want, n = {}, 0
  if opts().watch then
    for buf, st in pairs(M.buffers) do
      if valid(buf) then
        for p in pairs(st.sources) do
          local d, name = p:match("^(.*)/([^/]+)$")
          if d then
            d = d == "" and "/" or d
            if not want[d] then
              n = n + 1
              want[d] = {}
            end
            want[d][name] = p
          end
        end
      end
    end
  end
  for d, w in pairs(watchers) do
    if not want[d] then
      close_handle(w.handle)
      watchers[d] = nil
    end
  end
  local open = M.watch_count()
  for d, names in pairs(want) do
    if watchers[d] then
      watchers[d].files = names
    elseif open >= MAX_WATCHED then
      report_once("watching at most " .. MAX_WATCHED .. " directories; refresh the others by hand")
      break
    elseif utils.is_dir(d) then
      local h = vim.uv.new_fs_event()
      local entry = { handle = h, files = names }
      local ok = h
        and h:start(d, {}, function(err, fname)
          if err then
            return
          end
          -- a fast callback: no vim.fn or vim.api here
          local tail = fname and fname:match("[^/]+$")
          for name, p in pairs(entry.files) do
            if not tail or tail == name then
              later("watch:" .. p, function()
                require("org.files").invalidate(p)
                M.refresh_dependents(p)
              end)
            end
          end
        end)
      if ok == 0 then
        watchers[d] = entry
        open = open + 1
      elseif h then
        close_handle(h)
      end
    end
  end
end

local function stop_all()
  for _, t in pairs(timers) do
    close_handle(t)
  end
  timers = {}
  for _, w in pairs(watchers) do
    close_handle(w.handle)
  end
  watchers = {}
end

---------------------------------------------------------------------------
-- The edit key
---------------------------------------------------------------------------

-- whether 1-based `row` is a #+transclude: keyword (not in a block)
local function keyword_row(buf, row)
  local line = api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  if not keyword.match(line) then
    return false
  end
  local kws = keyword.scan(api.nvim_buf_get_lines(buf, 0, row, false))
  return kws[#kws] ~= nil and kws[#kws].row == row
end

--- The transclusion under the cursor: { row = keyword row (1-based),
--- region = materialized region or nil }.
---@param buf? integer
---@return table|nil
function M.at_cursor(buf)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  local row = api.nvim_win_get_cursor(0)[1]
  for _, r in ipairs(M.regions(buf)) do
    if row - 1 >= r.s and row - 1 <= r.e then
      return { row = r.s, region = r }
    end
  end
  if keyword_row(buf, row) then
    return { row = row, region = region_below(buf, row) }
  end
end

wrap_key = function(buf)
  local key = opts().edit_key
  local st = M.buffers[buf]
  if not key or key == "" or st.keys then
    return
  end
  local prev = api.nvim_buf_call(buf, function()
    return vim.fn.maparg(key, "n", false, true)
  end)
  st.keys = { key, prev }
  vim.keymap.set("n", key, function()
    if M.at_cursor(0) then
      return M.edit()
    end
    if type(prev) == "table" and prev.callback then
      return prev.callback()
    elseif type(prev) == "table" and prev.rhs and prev.rhs ~= "" then
      local keys = api.nvim_replace_termcodes(prev.rhs, true, true, true)
      api.nvim_feedkeys(keys, prev.noremap == 1 and "n" or "m", false)
    else
      api.nvim_feedkeys(api.nvim_replace_termcodes(key, true, true, true), "n", false)
    end
  end, { buffer = buf, desc = "org: edit the transclusion at point, else " .. ((prev or {}).desc or key) })
end

local function unwrap_key(buf)
  local st = M.buffers[buf]
  if not st or not st.keys or not valid(buf) then
    return
  end
  local key, prev = st.keys[1], st.keys[2]
  api.nvim_buf_call(buf, function()
    pcall(vim.keymap.del, "n", key, { buffer = buf })
    if type(prev) == "table" and prev.lhs and prev.buffer == 1 then
      pcall(vim.fn.mapset, "n", false, prev)
    end
  end)
  st.keys = nil
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

local function need()
  local t = M.at_cursor(0)
  if not t then
    utils.warn("Not on a #+transclude: keyword or transcluded text")
  end
  return t
end

--- Insert the text of the transclusion at point (org-transclusion-add).
function M.add()
  local t = need()
  if not t then
    return
  end
  local buf = api.nvim_get_current_buf()
  state(buf, true)
  if t.region then
    utils.notify("Already inserted")
    return
  end
  pcall(api.nvim_buf_clear_namespace, buf, ns_hide, t.row - 1, t.row)
  local ok, err = materialize(buf, t.row)
  if not ok then
    utils.warn(tostring(err))
  end
  M.render(buf)
end

--- Insert every transclusion of the buffer except `:disable-auto` ones
--- (org-transclusion-add-all).
---@param buf? integer
function M.add_all(buf)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  if not valid(buf) then
    return
  end
  state(buf, true)
  api.nvim_buf_clear_namespace(buf, ns_hide, 0, -1)
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local inside = inside_rows(buf)
  local env = environment(buf, lines, inside)
  local kws = keyword.scan(lines, function(row)
    return inside[row]
  end)
  local has = {}
  for _, r in ipairs(M.regions(buf)) do
    has[r.s] = true
  end
  local errors = {}
  source.frame(function()
    -- bottom-up: the lines above each keyword stay as they were read
    for i = #kws, 1, -1 do
      local kw = kws[i]
      local spec = keyword.parse(kw.value)
      if spec and not spec.disable_auto and not has[kw.row] then
        local ok, err = materialize(buf, kw.row, env)
        if not ok then
          errors[#errors + 1] = err
        end
      end
    end
  end)
  for _, e in ipairs(errors) do
    utils.warn(tostring(e))
  end
  M.render(buf)
end

-- Take out inserted text of `regs` (bottom-up); returns the keyword rows,
-- as they are afterwards.
local function take_out(buf, regs)
  local rows = {}
  keep_modified(buf, function()
    for i = #regs, 1, -1 do
      delete_rows(buf, owned_rows(regs[i]))
    end
  end)
  local removed = 0
  for _, r in ipairs(regs) do
    rows[#rows + 1] = r.s - removed
    removed = removed + #owned_rows(r)
  end
  touch(M.buffers[buf])
  return rows
end

--- Remove the transclusion at point (org-transclusion-remove): inserted
--- text is taken out; a virtual one is hidden until refreshed.
function M.remove()
  local t = need()
  if not t then
    return
  end
  local buf = api.nvim_get_current_buf()
  if t.region then
    t.region.data.removed = true
    take_out(buf, { t.region })
    api.nvim_win_set_cursor(0, { t.row, 0 })
  else
    api.nvim_buf_set_extmark(buf, ns_hide, t.row - 1, 0, {})
  end
  M.render(buf)
end

--- Take out every inserted transclusion (org-transclusion-remove-all);
--- the buffer shows them as virtual lines again when those are on.
---@param buf? integer
---@return integer[] rows of the keywords whose text was removed
function M.remove_all(buf)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  local regs = M.regions(buf)
  local rows = {}
  if #regs > 0 then
    for _, r in ipairs(regs) do
      r.data.removed = true
    end
    rows = take_out(buf, regs)
  end
  if M.buffers[buf] then
    M.render(buf)
  end
  return rows
end

--- Refresh the transclusion at point, or the whole buffer
--- (org-transclusion-refresh). Hidden ones are shown again.
function M.refresh()
  local buf = api.nvim_get_current_buf()
  local t = M.at_cursor(buf)
  if t then
    pcall(api.nvim_buf_clear_namespace, buf, ns_hide, t.row - 1, t.row)
  else
    api.nvim_buf_clear_namespace(buf, ns_hide, 0, -1)
  end
  source.clear_cache()
  M.render(buf, true)
end

--- Toggle the virtual transclusions of the buffer.
function M.toggle()
  local buf = api.nvim_get_current_buf()
  local st = state(buf, true)
  st.virtual = not st.virtual
  api.nvim_buf_clear_namespace(buf, ns_hide, 0, -1)
  M.render(buf)
  utils.notify("Transclusions " .. (st.virtual and "shown" or "hidden"))
  return true
end

--- Open the source of the transclusion at point in a float to edit it;
--- `:w` writes it back (org-transclusion-live-sync-start).
function M.edit()
  local t = need()
  if not t then
    return
  end
  local buf = api.nvim_get_current_buf()
  local res, err, spec, ctx = resolve_at(buf, t.row)
  if not res then
    utils.warn(tostring(err))
    return
  end
  return edit.open(res, spec, ctx, opts().edit)
end

--- Visit the source of the transclusion at point
--- (org-transclusion-open-source).
function M.open_source()
  local t = need()
  if not t then
    return
  end
  local res, err = resolve_at(api.nvim_get_current_buf(), t.row)
  if not res then
    utils.warn(tostring(err))
    return
  end
  local lnum = res.map and res.map[res.first] or res.first
  if res.path then
    local how = opts().open_source
    utils.open_file(res.path, lnum, { split = how ~= "edit" and how or nil })
  else
    api.nvim_win_set_cursor(0, { lnum, 0 })
  end
end

--- Replace the transclusion at point by a copy of its text
--- (org-transclusion-detach).
function M.detach()
  local t = need()
  if not t then
    return
  end
  local buf = api.nvim_get_current_buf()
  if t.region then
    forget(buf, t.region.id)
    api.nvim_buf_set_lines(buf, t.row - 1, t.row, false, {})
  else
    local res, err = resolve_at(buf, t.row)
    if not res then
      utils.warn(tostring(err))
      return
    end
    api.nvim_buf_set_lines(buf, t.row - 1, t.row, false, res.lines)
  end
  M.render(buf)
end

--- Add a `#+transclude:` line for the link at point below it
--- (org-transclusion-make-from-link).
function M.make_from_link()
  local l = require("org.links").link_at_cursor()
  if not l or not l.target then
    utils.warn("No link at point")
    return
  end
  local link = l.raw and l.raw:sub(1, 2) == "[[" and l.raw or ("[[" .. l.target .. "]]")
  local row = l.end_lnum or api.nvim_win_get_cursor(0)[1]
  local indent = api.nvim_get_current_line():match("^(%s*)")
  api.nvim_buf_set_lines(0, row, row, false, { indent .. "#+transclude: " .. link })
  api.nvim_win_set_cursor(0, { row + 1, 0 })
  M.render(0)
end

--- `:Org transclusion_insert [[link]] [props]`: a `#+transclude:` line
--- below the cursor.
---@param args? string
function M.insert_command(args)
  args = vim.trim(args or "")
  if args == "" then
    args = vim.trim(vim.fn.input("Transclude link: ", "[[file:"))
    if args == "" then
      return
    end
  end
  if not args:match("^%[%[") then
    local first, rest = args:match("^(%S+)(.*)$")
    args = "[[" .. first .. "]]" .. rest
  end
  local row = api.nvim_win_get_cursor(0)[1]
  -- below the inserted text when the cursor is in it
  for _, r in ipairs(M.regions(0)) do
    if row - 1 >= r.s - 1 and row - 1 <= r.e then
      row = r.e + 1
    end
  end
  local indent = api.nvim_get_current_line():match("^(%s*)")
  api.nvim_buf_set_lines(0, row, row, false, { indent .. "#+transclude: " .. args })
  api.nvim_win_set_cursor(0, { row + 1, 0 })
  M.render(0)
end

local function shift(delta)
  local t = need()
  if not t then
    return
  end
  local buf = api.nvim_get_current_buf()
  local res, _, spec = resolve_at(buf, t.row)
  local line = api.nvim_buf_get_lines(buf, t.row - 1, t.row, false)[1]
  local cur = spec and type(spec.level) == "number" and spec.level or nil
  if not cur and res then
    for _, l in ipairs(res.lines) do
      local stars = l:match("^(%*+) ")
      if stars then
        cur = #stars
        break
      end
    end
  end
  if not cur then
    utils.warn("The transclusion has no headline to promote or demote")
    return
  end
  local new = keyword.set_level(line, cur + delta)
  -- in place: the keyword keeps its mark and its inserted text
  api.nvim_buf_set_text(buf, t.row - 1, 0, t.row - 1, #line, { new })
  M.render(buf)
end

--- Promote the transcluded subtree (org-transclusion-promote-subtree).
function M.promote()
  shift(-1)
end

--- Demote the transcluded subtree (org-transclusion-demote-subtree).
function M.demote()
  shift(1)
end

---------------------------------------------------------------------------
-- Saving: inserted text never reaches the file
---------------------------------------------------------------------------

local after_write

-- Take the inserted text out before `buf` is written (all of it, or the
-- part in lines l1..l2 of a partial write).
local function before_write(buf, l1, l2)
  local st = M.buffers[buf]
  if not st or st.saving or not next(st.regions) or not valid(buf) then
    return
  end
  protect(buf)
  adopt_gone(buf)
  local list = collect(buf)
  local saving = { ids = {}, views = {} }
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do
    saving.views[w] = api.nvim_win_call(w, vim.fn.winsaveview)
  end
  keep_modified(buf, function()
    -- every marked line goes, the text of deleted keywords too
    for i = #list, 1, -1 do
      local r = list[i]
      local rows = {}
      for _, row in ipairs(owned_rows(r)) do
        if not st.cache.anchors[row] and (not l1 or (row >= l1 - 1 and row <= l2 - 1)) then
          rows[#rows + 1] = row
        end
      end
      if #rows > 0 then
        delete_rows(buf, rows)
        if not r.gone then
          saving.ids[#saving.ids + 1] = r.id
        end
      end
    end
  end)
  touch(st)
  st.saving = saving
  st.mtime = nil
  -- A write that fails (or is stopped by another autocommand) has no
  -- BufWritePost: put the text back once the write command is over. A
  -- callback can run while autocommands still run (vim.wait in a
  -- formatter): wait until none does.
  local function fallback()
    if M.buffers[buf] ~= st or st.saving ~= saving then
      return
    end
    if vim.fn.state():find("x") then
      vim.defer_fn(fallback, 20)
      return
    end
    after_write(buf)
  end
  vim.schedule(fallback)
end

after_write = function(buf)
  local st = M.buffers[buf]
  if not st or not st.saving or not valid(buf) then
    return
  end
  local saving = st.saving
  st.saving = nil
  local list = collect(buf)
  local left = {}
  for _, r in ipairs(list) do
    left[r.id] = r
  end
  local items = {}
  for _, aid in ipairs(saving.ids) do
    local m = api.nvim_buf_get_extmark_by_id(buf, ns_region, aid, { details = true })
    local data = st.regions[aid]
    if m[1] and not (m[3] and m[3].invalid) and data then
      items[#items + 1] = { row = m[1], id = aid, data = data }
    end
  end
  table.sort(items, function(x, y)
    return x.row > y.row
  end)
  keep_modified(buf, function()
    for _, it in ipairs(items) do
      local kw = api.nvim_buf_get_lines(buf, it.row, it.row + 1, false)[1]
      if kw and keyword.match(kw) then
        -- joined to the removal, so undo doesn't see the save
        undojoin(buf)
        if left[it.id] then
          -- what a partial write left
          delete_rows(buf, owned_rows(left[it.id]))
        end
        api.nvim_buf_set_lines(buf, it.row + 1, it.row + 1, false, it.data.lines)
        mark_lines(buf, it.id, it.row + 1, #it.data.lines)
        gc_marks(buf, it.id)
      end
    end
  end)
  touch(st)
  for w, view in pairs(saving.views) do
    if api.nvim_win_is_valid(w) and api.nvim_win_get_buf(w) == buf then
      api.nvim_win_call(w, function()
        vim.fn.winrestview(view)
      end)
    end
  end
  local name = api.nvim_buf_get_name(buf)
  st.mtime = name ~= "" and source.stamp(name) or nil
  M.render(buf)
end

--- Run `fn` (a write of `buf`) with the inserted text taken out, and put
--- it back afterwards. For writes that skip autocommands, like
--- `utils.save_buffer`'s `:noautocmd write`.
---@param buf integer
---@param fn function
function M.without_inserted(buf, fn)
  local st = M.buffers[buf]
  if not st or st.saving or not next(st.regions) then
    return fn()
  end
  before_write(buf)
  local ok, a1, a2 = pcall(fn)
  after_write(buf)
  if not ok then
    error(a1, 0)
  end
  return a1, a2
end

--- After a write that skipped autocommands (`:noautocmd w`), the file
--- holds the inserted text: take it out of the file again.
local function heal(buf)
  local st = M.buffers[buf]
  if not st or st.saving or not next(st.regions) or not valid(buf) or vim.bo[buf].modified then
    return
  end
  local name = api.nvim_buf_get_name(buf)
  if name == "" or vim.bo[buf].buftype ~= "" then
    return
  end
  local mt = source.stamp(name)
  if not mt or mt == st.mtime then
    return
  end
  st.mtime = mt
  local _, map = M.clean_lines(buf)
  if not map then
    return
  end
  local disk = utils.readfile(name)
  if disk and vim.deep_equal(disk, api.nvim_buf_get_lines(buf, 0, -1, false)) then
    -- written again by Vim, so it knows the file it wrote (no "changed
    -- since editing started" warning); autocommands don't nest, so the
    -- text is taken out here
    local ok = pcall(M.without_inserted, buf, function()
      api.nvim_buf_call(buf, function()
        vim.cmd("silent keepalt write")
      end)
    end)
    if ok then
      utils.warn("transclusion: the file was written without autocommands; its inserted text was taken out again")
    end
  end
end

M.heal = heal

---------------------------------------------------------------------------
-- Export
---------------------------------------------------------------------------

--- Expand `#+transclude:` keywords of exported lines (an
--- `org.export.hooks` preprocessor). Text inserted in the exported buffer
--- is replaced, not doubled.
---@param lines string[]
---@param ctx table { dir, filename, bufnr }
---@return string[]
function M.export_preprocess(lines, ctx)
  if not opts().export then
    return lines
  end
  local regs = ctx.bufnr and valid(ctx.bufnr) and M.regions(ctx.bufnr) or {}
  local skip
  if #regs > 0 and vim.deep_equal(lines, api.nvim_buf_get_lines(ctx.bufnr, 0, -1, false)) then
    lines = M.clean_lines(ctx.bufnr)
  elseif #regs > 0 then
    local inserted = {}
    for _, r in ipairs(regs) do
      inserted[#inserted + 1] = r.data.lines
    end
    skip = function(kw, all)
      for _, ins in ipairs(inserted) do
        if vim.deep_equal(vim.list_slice(all, kw.row + 1, kw.row + #ins), ins) then
          return #ins
        end
      end
      return 0
    end
  end
  local out, errors = source.frame(source.expand, lines, {
    dir = ctx.dir,
    filename = ctx.filename,
    bufnr = ctx.bufnr,
  }, skip)
  for _, e in ipairs(errors) do
    utils.warn("transclusion: " .. tostring(e))
  end
  return out
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

local function attach(buf)
  if not valid(buf) or vim.bo[buf].filetype ~= "org" then
    return
  end
  local st = M.buffers[buf]
  if not st then
    if not opts().mode then
      return
    end
    st = state(buf, true)
    local name = api.nvim_buf_get_name(buf)
    st.mtime = name ~= "" and source.stamp(name) or nil
    M.render(buf)
    if opts().mode == "materialized" then
      M.add_all(buf)
    end
  elseif st.tick ~= api.nvim_buf_get_changedtick(buf) or st.sig ~= source.frame(signature, st.sources) then
    M.render(buf, true)
  end
end

M.attach = attach

local function on_change(buf)
  local st = M.buffers[buf]
  if st and not st.saving then
    local ok, err = pcall(protect, buf)
    if not ok then
      report_once(err)
    end
    later("render:" .. buf, function()
      if valid(buf) and M.buffers[buf] then
        M.render(buf)
      end
    end)
  end
  if opts().live then
    local name = api.nvim_buf_get_name(buf)
    if name ~= "" then
      local path = vim.fs.normalize(name)
      for b, s in pairs(M.buffers) do
        if b ~= buf and source.source_key(s.sources, path) then
          later("deps:" .. path, function()
            M.refresh_dependents(path, buf)
          end)
          break
        end
      end
    end
  end
end

local function range_marks(buf)
  local s = api.nvim_buf_get_mark(buf, "[")[1]
  local e = api.nvim_buf_get_mark(buf, "]")[1]
  if s > 0 and e >= s then
    return s, e
  end
end

function M.setup()
  define_highlights()
  source.opts = opts()
  source.buffer_lines = M.clean_lines
  source.clear_cache()
  reported = {}
  edit.on_written = function(path, sb)
    if path then
      M.refresh_dependents(path)
    elseif sb then
      M.render(sb, true)
    end
  end
  edit.later = later
  require("org.lazy").on_load("org.export.hooks", "transclusion", function(hooks)
    hooks.preprocessors.transclusion = M.export_preprocess
  end)
  api.nvim_clear_autocmds({ group = augroup })
  local function guard(fn)
    return function(ev)
      local ok, err = pcall(fn, ev)
      if not ok then
        report_once(err)
      end
    end
  end
  api.nvim_create_autocmd("ColorScheme", { group = augroup, callback = define_highlights })
  api.nvim_create_autocmd({ "FileType" }, {
    group = augroup,
    pattern = "org",
    callback = guard(function(ev)
      attach(ev.buf)
    end),
  })
  api.nvim_create_autocmd({ "BufWinEnter", "BufEnter", "FocusGained" }, {
    group = augroup,
    callback = guard(function(ev)
      local buf = ev.buf ~= 0 and ev.buf or api.nvim_get_current_buf()
      heal(buf)
      attach(buf)
    end),
  })
  api.nvim_create_autocmd({ "BufLeave", "CursorHold", "FocusLost" }, {
    group = augroup,
    callback = guard(function(ev)
      heal(ev.buf ~= 0 and ev.buf or api.nvim_get_current_buf())
    end),
  })
  api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
    group = augroup,
    callback = guard(function(ev)
      on_change(ev.buf)
    end),
  })
  -- the buffer after :e! holds the file again
  api.nvim_create_autocmd("BufReadPost", {
    group = augroup,
    callback = guard(function(ev)
      local st = M.buffers[ev.buf]
      if st and opts().mode == "materialized" then
        vim.schedule(function()
          if M.buffers[ev.buf] == st and valid(ev.buf) then
            M.add_all(ev.buf)
          end
        end)
      end
    end),
  })
  -- A whole write is a write hook, so `:w` and org's own saves
  -- (`utils.save_buffer`) both leave the inserted text out of the file.
  -- It runs before the other hooks (crypt encrypts the file's text, not
  -- the inserted one).
  require("org.write_hooks").register("transclusion", {
    order = 10,
    pre = function(buf)
      before_write(buf)
    end,
    post = function(buf, ctx)
      after_write(buf)
      local name = api.nvim_buf_get_name(buf)
      if ctx.ok and name ~= "" then
        local ok, err = pcall(M.refresh_dependents, vim.fs.normalize(name), buf)
        if not ok then
          report_once(err)
        end
      end
    end,
  })
  -- A partial write or an append (:w >>), which Vim reports with the '[
  -- and '] marks
  api.nvim_create_autocmd({ "FileWritePre", "FileAppendPre" }, {
    group = augroup,
    callback = function(ev)
      local s, e = range_marks(ev.buf)
      if s then
        before_write(ev.buf, s, e)
      end
    end,
  })
  api.nvim_create_autocmd({ "FileWritePost", "FileAppendPost" }, {
    group = augroup,
    callback = guard(function(ev)
      after_write(ev.buf)
    end),
  })
  api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    group = augroup,
    callback = function(ev)
      if M.buffers[ev.buf] then
        M.buffers[ev.buf] = nil
        local t = timers["render:" .. ev.buf]
        if t then
          timers["render:" .. ev.buf] = nil
          close_handle(t)
        end
        vim.schedule(update_watchers)
      end
    end,
  })
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if valid(buf) and vim.bo[buf].filetype == "org" then
      attach(buf)
    end
  end
end

--- Undo `setup`: inserted text is removed, virtual lines cleared and the
--- edit key given back.
function M.teardown()
  api.nvim_clear_autocmds({ group = augroup })
  require("org.write_hooks").unregister("transclusion")
  for buf in pairs(M.buffers) do
    if valid(buf) then
      pcall(M.remove_all, buf)
      unwrap_key(buf)
      api.nvim_buf_clear_namespace(buf, ns, 0, -1)
      api.nvim_buf_clear_namespace(buf, ns_region, 0, -1)
      api.nvim_buf_clear_namespace(buf, ns_line, 0, -1)
      api.nvim_buf_clear_namespace(buf, ns_hide, 0, -1)
    end
  end
  M.buffers = {}
  stop_all()
  edit.close_all()
  require("org.lazy").if_loaded("org.export.hooks", "transclusion", function(hooks)
    hooks.preprocessors.transclusion = nil
  end)
  source.buffer_lines = function(buf)
    return api.nvim_buf_get_lines(buf, 0, -1, false), nil
  end
  source.clear_cache()
end

function M.health(h, o)
  h.ok("transclusion: mode " .. tostring(o.mode) .. (o.watch and ", watching source files" or ""))
  local ok = pcall(vim.treesitter.language.inspect, "python")
  if ok then
    h.ok("transclusion: tree-sitter parsers colour transcluded code")
  else
    h.info("transclusion: code in virtual lines is coloured only for languages with a tree-sitter parser")
  end
end

return M
