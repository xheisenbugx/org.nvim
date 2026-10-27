---@mod org.extensions.transclusion.regions Materialized regions and their marks
---
--- Inserted text is tracked by an extmark on its keyword line and one on
--- each inserted line: marking lines, collecting the regions of a buffer
--- (`regions`), the line ranges they cover (`ranges`, `clean_lines`) and
--- deleting their rows. Part of org.extensions.transclusion, which loads it.

local shared = require("org.extensions.transclusion.shared")

local M = require("org.extensions.transclusion")

local api = vim.api
local ns_region, ns_line = M.ns_region, M.ns_line
local opts = shared.opts
local valid = shared.valid

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
    pcall(vim.api.nvim_command, "undojoin")
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

--- The lines of `buf` holding inserted (materialized) text, as a set of
--- 1-based line numbers; nil when nothing is inserted. Its keyword lines
--- are not in it.
---@param buf? integer
---@return table<integer, boolean>|nil
function M.inserted_rows(buf)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  local list = collect(buf)
  if #list == 0 then
    return nil
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
  return inside
end

--- Lines of `buf` without its materialized text, and a map from those
--- lines to buffer lines (nil when there is nothing materialized).
---@param buf integer
---@return string[], integer[]|nil
function M.clean_lines(buf)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local inside = M.inserted_rows(buf)
  if not inside then
    return lines, nil
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

shared.touch = touch
shared.keep_modified = keep_modified
shared.undojoin = undojoin
shared.at_tip = at_tip
shared.mark_lines = mark_lines
shared.new_region = new_region
shared.forget = forget
shared.gc_marks = gc_marks
shared.collect = collect
shared.owned_rows = owned_rows
shared.delete_rows = delete_rows
shared.region_below = region_below
