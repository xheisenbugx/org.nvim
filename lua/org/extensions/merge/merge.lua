---@mod org.extensions.merge.merge Structural three-way merge of Org files
---
--- Each version (base, ours, theirs) is parsed with `org.parser` into a tree
--- of entries. An entry is matched across versions by its `ID` (or
--- `CUSTOM_ID`) property, else by its outline path and title; an entry
--- renamed on one side is still matched when the rest of its content is
--- unchanged. Entries are then merged one by one:
---
---   - changes to different entries never conflict;
---   - an entry moved (a different parent or place) is followed;
---   - the headline's TODO keyword, priority, COMMENT and title, and each
---     planning keyword, are merged as values: a change on one side wins,
---     different changes on both sides conflict (or `prefer` picks one);
---   - tags: removals on either side are kept and additions are unioned;
---   - the property drawer is merged key by key;
---   - LOGBOOK items (CLOCK lines, state and note items) are unioned, with
---     removals kept, and sorted newest first when both sides added some;
---   - the rest of the entry's text is merged line by line (diff3).
---
--- Conflict markers only ever wrap the lines of the one entry (or the one
--- property) in conflict.

local parser = require("org.parser")
local diff3 = require("org.extensions.merge.diff3")

local M = {}

---@class org.merge.Opts: org.merge.Diff3Opts
---@field prefer? "ours"|"theirs" side taken when both changed the same headline field, planning keyword or property
---@field sort_logbook? boolean sort LOGBOOK items newest first when both sides added some (true)

local SEP = "\31"
local DUP = "\30"

---------------------------------------------------------------------------
-- Reading a version into entries
---------------------------------------------------------------------------

local function slice(lines, from, to)
  local out = {}
  for i = from, to do
    out[#out + 1] = lines[i]
  end
  return out
end

local PLANNING_ORDER = { "CLOSED", "DEADLINE", "SCHEDULED" }

-- `KEYWORD: <timestamp>` pairs of a planning line, and their order.
local function parse_planning(line)
  local map, order = {}, {}
  for kw, ts in line:gmatch("(%u+):%s*(%b<>)") do
    map[kw], order[#order + 1] = ts, kw
  end
  for kw, ts in line:gmatch("(%u+):%s*(%b[])") do
    map[kw], order[#order + 1] = ts, kw
  end
  -- keep the order of the line
  table.sort(order, function(a, b)
    return (line:find(a .. ":", 1, true) or 0) < (line:find(b .. ":", 1, true) or 0)
  end)
  return map, order
end

-- LOGBOOK items: a CLOCK line or a `- ` item with its continuation lines.
local function logbook_items(lines)
  local items = {}
  for _, l in ipairs(lines) do
    if #items == 0 or l:match("^%s*CLOCK:") or l:match("^%s*%- ") then
      items[#items + 1] = l
    else
      items[#items] = items[#items] .. "\n" .. l
    end
  end
  return items
end

local function new_entry(lines, hl)
  local e = {
    level = hl.level,
    raw = lines[hl.line],
    todo = hl.todo,
    priority = hl.priority,
    commented = hl.commented or false,
    title = hl.title or "",
    tags = vim.list_extend({}, hl.tags or {}),
    children = {},
    first = hl.line,
    last = hl.end_line,
  }
  local props = hl.properties or {}
  e.id = props.ID or props.CUSTOM_ID
  local i = hl.line + 1
  if hl.planning_line == i then
    e.planning_raw = lines[i]
    e.planning, e.planning_order = parse_planning(lines[i])
    i = i + 1
  end
  local pr = hl.properties_range
  if pr and pr[1] == i then
    e.props = { open = lines[pr[1]], close = lines[pr[2]], order = {}, map = {} }
    local seen = {}
    for j = pr[1] + 1, pr[2] - 1 do
      local key = parser.parse_property_line(lines[j])
      key = (key or lines[j]):upper()
      seen[key] = (seen[key] or 0) + 1
      if seen[key] > 1 then
        key = key .. DUP .. seen[key]
      end
      e.props.order[#e.props.order + 1] = key
      e.props.map[key] = lines[j]
    end
    i = pr[2] + 1
  end
  local lb = hl.logbook
  if lb and lb.start == i then
    e.logbook = {
      open = lines[lb.start],
      close = lines[lb["end"]],
      items = logbook_items(slice(lines, lb.start + 1, lb["end"] - 1)),
    }
    i = lb["end"] + 1
  end
  e.body = slice(lines, i, hl.body_end)
  return e
end

-- The entry's own lines (headline to its first child) as one string.
local function own_text(e, no_head)
  -- the stars are left out: a move to another level is not a change
  local parts = { no_head and "" or (e.raw:gsub("^%*+", "")), e.planning_raw or "" }
  if e.props then
    parts[#parts + 1] = e.props.open
    for _, k in ipairs(e.props.order) do
      parts[#parts + 1] = e.props.map[k]
    end
  end
  if e.logbook then
    parts[#parts + 1] = e.logbook.open
    vim.list_extend(parts, e.logbook.items)
  end
  parts[#parts + 1] = "\0"
  vim.list_extend(parts, e.body)
  return table.concat(parts, "\n")
end

-- Content apart from the headline, to recognise a renamed entry.
local function content_sig(e)
  local s = own_text(e, true)
  if not s:find("%S") or s:match("^%s*%z%s*$") then
    return nil
  end
  return s
end

---@class org.merge.Version
---@field lines string[]
---@field root table
---@field by_key table<string, table>

local function set_keys(version, base)
  local function walk(e)
    local counts = {}
    local fresh = {}
    for _, c in ipairs(e.children) do
      local k = c.id and ("id:" .. c.id) or (e.key .. SEP .. c.title)
      counts[k] = (counts[k] or 0) + 1
      if counts[k] > 1 then
        k = k .. DUP .. counts[k]
      end
      c.key = k
      if base and not c.id and not base.by_key[k] then
        fresh[#fresh + 1] = c
      end
    end
    -- an entry renamed on this side: an unmatched base child with the same
    -- content
    local bparent = base and base.by_key[e.key]
    if #fresh > 0 and bparent then
      local taken = {}
      for _, c in ipairs(e.children) do
        taken[c.key] = true
      end
      for _, c in ipairs(fresh) do
        local sig = content_sig(c)
        if sig then
          for _, b in ipairs(bparent.children) do
            if not b.id and not taken[b.key] and content_sig(b) == sig then
              taken[b.key] = true
              c.key = b.key
              break
            end
          end
        end
      end
    end
    for idx, c in ipairs(e.children) do
      c.parent_key = e.key
      c.index = idx
      c.parent = e
      version.by_key[c.key] = c
      walk(c)
    end
  end
  version.by_key[""] = version.root
  walk(version.root)
end

--- Parse `lines` into a version (entries keyed for matching with `base`).
---@param lines string[]
---@param base? org.merge.Version
---@return org.merge.Version
function M.read(lines, base)
  local file = parser.parse(lines)
  local root = { key = "", level = 0, children = {}, preamble = slice(lines, 1, file.preamble_end or #lines) }
  local map = {}
  for _, hl in ipairs(file.headlines) do
    if not hl.inlinetask then
      local e = new_entry(lines, hl)
      map[hl] = e
      local parent = hl.parent and map[hl.parent] or root
      parent.children[#parent.children + 1] = e
    end
  end
  local version = { lines = lines, root = root, by_key = {} }
  set_keys(version, base)
  return version
end

---------------------------------------------------------------------------
-- Merging values
---------------------------------------------------------------------------

-- Three-way merge of one value: the value and whether it conflicts.
local function merge3(b, o, t)
  if o == t then
    return o, false
  elseif o == b then
    return t, false
  elseif t == b then
    return o, false
  end
  return nil, true
end

local function tags_merge(b, o, t)
  local bs, ts = {}, {}
  for _, x in ipairs(b or {}) do
    bs[x] = true
  end
  for _, x in ipairs(t or {}) do
    ts[x] = true
  end
  local out, seen = {}, {}
  local function add(x)
    if not seen[x] then
      seen[x] = true
      out[#out + 1] = x
    end
  end
  for _, x in ipairs(o or {}) do
    -- dropped when theirs removed it
    if not (bs[x] and not ts[x]) then
      add(x)
    end
  end
  -- added by theirs (kept tags are already in ours)
  for _, x in ipairs(t or {}) do
    if not bs[x] then
      add(x)
    end
  end
  return out
end

local function same_list(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

-- Sort key of a LOGBOOK item: its first timestamp, or nil.
local function item_time(item)
  local date = require("org.date")
  for br in item:gmatch("%b[]") do
    local d = date.parse(br)
    if d then
      return string.format("%04d%02d%02d%02d%02d", d.year, d.month, d.day, d.hour or 0, d.min or 0)
    end
  end
end

local function logbook_merge(b, o, t, sort)
  b, o, t = b or {}, o or {}, t or {}
  if same_list(o, t) or same_list(b, t) then
    return vim.list_extend({}, o)
  elseif same_list(b, o) then
    return vim.list_extend({}, t)
  end
  local bs, ts = {}, {}
  for _, x in ipairs(b) do
    bs[x] = true
  end
  for _, x in ipairs(t) do
    ts[x] = true
  end
  local out, seen = {}, {}
  for _, x in ipairs(o) do
    if not seen[x] and not (bs[x] and not ts[x]) then
      seen[x] = true
      out[#out + 1] = x
    end
  end
  local tail = {}
  for _, x in ipairs(t) do
    if not seen[x] and not bs[x] then
      seen[x] = true
      tail[#tail + 1] = x
    end
  end
  vim.list_extend(out, tail)
  if sort then
    local keys, all = {}, true
    for i, x in ipairs(out) do
      keys[x] = { item_time(x), i }
      all = all and keys[x][1] ~= nil
    end
    if all then
      table.sort(out, function(x, y)
        if keys[x][1] ~= keys[y][1] then
          return keys[x][1] > keys[y][1]
        end
        return keys[x][2] < keys[y][2]
      end)
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

local function tags_column()
  local ok, cfg = pcall(function()
    return require("org.config").opts.tags_column
  end)
  return ok and tonumber(cfg) or -77
end

local function compose_headline(level, f)
  local s = string.rep("*", level) .. " "
  if f.todo then
    s = s .. f.todo .. " "
  end
  if f.priority then
    s = s .. "[#" .. f.priority .. "] "
  end
  if f.commented then
    s = s .. "COMMENT "
  end
  s = s .. f.title
  s = s:gsub("%s+$", "")
  if #f.tags > 0 then
    local tagstr = ":" .. table.concat(f.tags, ":") .. ":"
    local col = tags_column()
    local width = vim.fn.strdisplaywidth(s)
    local pad
    if col < 0 then
      pad = -col - width - vim.fn.strdisplaywidth(tagstr)
    else
      pad = col - width - 1
    end
    s = s .. string.rep(" ", math.max(1, pad)) .. tagstr
  end
  return s
end

local function with_level(raw, level)
  return (raw:gsub("^%*+", string.rep("*", level), 1))
end

local function fields(e)
  return { todo = e.todo, priority = e.priority, commented = e.commented, title = e.title, tags = e.tags }
end

local function same_fields(a, b)
  return a.todo == b.todo
    and a.priority == b.priority
    and a.commented == b.commented
    and a.title == b.title
    and same_list(a.tags, b.tags)
end

local function headline_for(f, level, o, t)
  if o and same_fields(f, fields(o)) then
    return with_level(o.raw, level)
  elseif t and same_fields(f, fields(t)) then
    return with_level(t.raw, level)
  end
  return compose_headline(level, f)
end

local function planning_line(map, o, t)
  local function same_map(e)
    if not e or not e.planning then
      return next(map) == nil
    end
    for k, v in pairs(map) do
      if e.planning[k] ~= v then
        return false
      end
    end
    for k in pairs(e.planning) do
      if map[k] == nil then
        return false
      end
    end
    return true
  end
  if next(map) == nil then
    return nil
  end
  if o and o.planning_raw and same_map(o) then
    return o.planning_raw
  elseif t and t.planning_raw and same_map(t) then
    return t.planning_raw
  end
  local order, seen = {}, {}
  for _, src in ipairs({ o, t }) do
    for _, k in ipairs(src and src.planning_order or {}) do
      if map[k] and not seen[k] then
        seen[k], order[#order + 1] = true, k
      end
    end
  end
  for _, k in ipairs(PLANNING_ORDER) do
    if map[k] and not seen[k] then
      seen[k], order[#order + 1] = true, k
    end
  end
  for k in pairs(map) do
    if not seen[k] then
      order[#order + 1] = k
    end
  end
  local parts = {}
  for _, k in ipairs(order) do
    parts[#parts + 1] = k .. ": " .. map[k]
  end
  local indent = ((o and o.planning_raw) or (t and t.planning_raw) or ""):match("^(%s*)") or ""
  return indent .. table.concat(parts, " ")
end

---@class org.merge.Result
---@field lines string[]
---@field conflicts integer

local Merger = {}
Merger.__index = Merger

function Merger:conflict(ours, theirs, base)
  self.conflicts = self.conflicts + 1
  return diff3.markers(ours, theirs, self.opts, base)
end

-- Merge the own lines of an entry present on both sides (b may be nil).
function Merger:own(b, o, t, level)
  local out = {}
  local ot, tt = own_text(o), own_text(t)
  local bt = b and own_text(b)
  local function side_lines(e)
    local l = { with_level(e.raw, level) }
    if e.planning_raw then
      l[#l + 1] = e.planning_raw
    end
    if e.props then
      l[#l + 1] = e.props.open
      for _, k in ipairs(e.props.order) do
        l[#l + 1] = e.props.map[k]
      end
      l[#l + 1] = e.props.close
    end
    if e.logbook then
      l[#l + 1] = e.logbook.open
      for _, it in ipairs(e.logbook.items) do
        vim.list_extend(l, vim.split(it, "\n", { plain = true }))
      end
      l[#l + 1] = e.logbook.close
    end
    return vim.list_extend(l, e.body)
  end
  if ot == tt or ot == bt then
    return side_lines(ot == bt and t or o)
  elseif tt == bt then
    return side_lines(o)
  end
  local prefer = self.opts.prefer
  local bf = b and fields(b) or {}
  -- headline fields and planning
  local fo, ft = fields(o), fields(t)
  local merged, mo, mt = {}, {}, {}
  local head_conflict = false
  local _, todo_conflict = merge3(bf.todo, fo.todo, ft.todo)
  for _, k in ipairs({ "todo", "priority", "commented", "title" }) do
    local v, c = merge3(bf[k], fo[k], ft[k])
    if c then
      if prefer then
        v = prefer == "theirs" and ft[k] or fo[k]
        merged[k], mo[k], mt[k] = v, v, v
      else
        head_conflict = true
        mo[k], mt[k] = fo[k], ft[k]
      end
    else
      merged[k], mo[k], mt[k] = v, v, v
    end
  end
  local tags = tags_merge(bf.tags, fo.tags, ft.tags)
  merged.tags, mo.tags, mt.tags = tags, tags, tags
  local bp, op, tp = b and b.planning or {}, o.planning or {}, t.planning or {}
  local plan, plan_o, plan_t = {}, {}, {}
  for _, k in ipairs(vim.tbl_keys(vim.tbl_extend("force", {}, bp, op, tp))) do
    local v, c = merge3(bp[k], op[k], tp[k])
    if k == "CLOSED" and todo_conflict then
      -- CLOSED goes with the TODO keyword of its side
      if prefer then
        v = prefer == "theirs" and tp[k] or op[k]
        plan[k], plan_o[k], plan_t[k] = v, v, v
      else
        plan_o[k], plan_t[k] = op[k], tp[k]
      end
    elseif c then
      if prefer then
        v = prefer == "theirs" and tp[k] or op[k]
        plan[k], plan_o[k], plan_t[k] = v, v, v
      else
        head_conflict = true
        plan_o[k], plan_t[k] = op[k], tp[k]
      end
    else
      plan[k], plan_o[k], plan_t[k] = v, v, v
    end
  end
  if head_conflict then
    local a = { headline_for(mo, level, o, t) }
    a[#a + 1] = planning_line(plan_o, o, t)
    local z = { headline_for(mt, level, o, t) }
    z[#z + 1] = planning_line(plan_t, o, t)
    vim.list_extend(out, self:conflict(a, z))
  else
    out[#out + 1] = headline_for(merged, level, o, t)
    out[#out + 1] = planning_line(plan, o, t)
  end
  -- properties, key by key
  if o.props or t.props then
    local bm = b and b.props and b.props.map or {}
    local om, tm = o.props and o.props.map or {}, t.props and t.props.map or {}
    local order, seen = {}, {}
    for _, src in ipairs({ o.props, t.props }) do
      for _, k in ipairs(src and src.order or {}) do
        if not seen[k] then
          seen[k], order[#order + 1] = true, k
        end
      end
    end
    local lines = {}
    for _, k in ipairs(order) do
      local v, c = merge3(bm[k], om[k], tm[k])
      if c then
        if prefer then
          v = prefer == "theirs" and tm[k] or om[k]
          lines[#lines + 1] = v
        else
          vim.list_extend(lines, self:conflict({ om[k] }, { tm[k] }))
        end
      else
        lines[#lines + 1] = v
      end
    end
    if #lines > 0 or (o.props and t.props) then
      local p = o.props or t.props
      out[#out + 1] = p.open
      vim.list_extend(out, lines)
      out[#out + 1] = p.close
    end
  end
  -- LOGBOOK
  if o.logbook or t.logbook then
    local items = logbook_merge(
      b and b.logbook and b.logbook.items,
      o.logbook and o.logbook.items,
      t.logbook and t.logbook.items,
      self.opts.sort_logbook ~= false
    )
    if #items > 0 or (o.logbook and t.logbook) then
      local lb = o.logbook or t.logbook
      out[#out + 1] = lb.open
      for _, it in ipairs(items) do
        vim.list_extend(out, vim.split(it, "\n", { plain = true }))
      end
      out[#out + 1] = lb.close
    end
  end
  -- the rest of the text, line by line
  local body, n = diff3.merge(b and b.body or {}, o.body, t.body, self.opts)
  self.conflicts = self.conflicts + n
  return vim.list_extend(out, body)
end

---------------------------------------------------------------------------
-- The tree
---------------------------------------------------------------------------

--- Merge three versions of an Org file.
---@param base string[]
---@param ours string[]
---@param theirs string[]
---@param opts? org.merge.Opts
---@return org.merge.Result
function M.merge(base, ours, theirs, opts)
  opts = opts or {}
  local B = M.read(base)
  local O = M.read(ours, B)
  local T = M.read(theirs, B)
  local self = setmetatable({ opts = opts, conflicts = 0 }, Merger)

  -- which entries stay, and where
  local state, parent_of = {}, {}
  local keys, seen = {}, {}
  for _, V in ipairs({ O, T, B }) do
    local function walk(e)
      for _, c in ipairs(e.children) do
        if not seen[c.key] then
          seen[c.key] = true
          keys[#keys + 1] = c.key
        end
        walk(c)
      end
    end
    walk(V.root)
  end
  for _, k in ipairs(keys) do
    local b, o, t = B.by_key[k], O.by_key[k], T.by_key[k]
    if o and t then
      state[k] = "both"
    elseif o or t then
      local present = o or t
      if not b then
        state[k] = o and "ours" or "theirs"
      elseif own_text(present) == own_text(b) then
        state[k] = "deleted"
      else
        -- deleted on one side, changed on the other
        state[k] = o and "del_theirs" or "del_ours"
      end
    else
      state[k] = "deleted"
    end
    if state[k] ~= "deleted" then
      local p, c = merge3(b and b.parent_key, o and o.parent_key, t and t.parent_key)
      if not (o and t) then
        p = (o or t).parent_key
      elseif c then
        -- moved to different places on both sides: ours wins
        p = o.parent_key
      end
      parent_of[k] = p
    end
  end
  -- an entry deleted on one side stays (as a conflict) while something
  -- that stays is below it
  local changed = true
  while changed do
    changed = false
    for _, k in ipairs(keys) do
      local p = parent_of[k]
      if state[k] ~= "deleted" and p and p ~= "" and state[p] == "deleted" then
        state[p] = O.by_key[p] and "del_theirs" or "del_ours"
        local src = O.by_key[p] or T.by_key[p]
        parent_of[p] = src.parent_key
        changed = true
      end
    end
  end
  local children = {}
  for _, k in ipairs(keys) do
    if state[k] ~= "deleted" then
      local p = parent_of[k]
      children[p] = children[p] or {}
      children[p][k] = true
    end
  end

  local function child_keys(V, p, set)
    local out = {}
    local e = V.by_key[p]
    for _, c in ipairs(e and e.children or {}) do
      if set[c.key] then
        out[#out + 1] = c.key
      end
    end
    return out
  end
  local function order_children(p)
    local set = children[p]
    if not set then
      return {}
    end
    local lb, lo, lt = child_keys(B, p, set), child_keys(O, p, set), child_keys(T, p, set)
    local in_o, in_t = {}, {}
    for _, k in ipairs(lo) do
      in_o[k] = true
    end
    for _, k in ipairs(lt) do
      in_t[k] = true
    end
    local function common(l)
      local out = {}
      for _, k in ipairs(l) do
        if in_o[k] and in_t[k] then
          out[#out + 1] = k
        end
      end
      return out
    end
    local basis, other = lo, lt
    if same_list(common(lo), common(lb)) then
      basis, other = lt, lo
    end
    local result, placed = vim.list_extend({}, basis), {}
    for _, k in ipairs(result) do
      placed[k] = true
    end
    for i, k in ipairs(other) do
      if not placed[k] then
        local at = 0
        for j = i - 1, 1, -1 do
          if placed[other[j]] then
            for x, rk in ipairs(result) do
              if rk == other[j] then
                at = x
              end
            end
            break
          end
        end
        table.insert(result, at + 1, k)
        placed[k] = true
      end
    end
    local rest = {}
    for k in pairs(set) do
      if not placed[k] then
        rest[#rest + 1] = k
      end
    end
    table.sort(rest)
    return vim.list_extend(result, rest)
  end

  local out = {}
  -- the text before the first headline
  local pre, n = diff3.merge(B.root.preamble, O.root.preamble, T.root.preamble, opts)
  self.conflicts = self.conflicts + n
  vim.list_extend(out, pre)

  local function rel_level(e)
    return e.level - (e.parent and e.parent.level or 0)
  end
  local function source(k)
    local p = parent_of[k]
    local o, t = O.by_key[k], T.by_key[k]
    if o and o.parent_key == p then
      return o
    elseif t and t.parent_key == p then
      return t
    end
    return o or t
  end
  -- the subtree of `e` in its own version, stars shifted to `level`
  local function verbatim(V, e, level)
    local delta = level - e.level
    local lines, keys_in = {}, {}
    local function mark(x)
      keys_in[x.key] = true
      for _, c in ipairs(x.children) do
        mark(c)
      end
    end
    mark(e)
    local heads = {}
    local function heads_of(x)
      heads[x.first] = x.level
      for _, c in ipairs(x.children) do
        heads_of(c)
      end
    end
    heads_of(e)
    for i = e.first, e.last do
      local l = V.lines[i]
      if heads[i] then
        l = with_level(l, heads[i] + delta)
      end
      lines[#lines + 1] = l
    end
    return lines, keys_in
  end

  local function emit(p, plevel)
    for _, k in ipairs(order_children(p)) do
      local src = source(k)
      local level = math.max(1, plevel + rel_level(src))
      local st = state[k]
      local skip = {}
      if st == "del_ours" or st == "del_theirs" then
        local V = st == "del_ours" and T or O
        local lines, keys_in = verbatim(V, V.by_key[k], level)
        skip = keys_in
        if st == "del_ours" then
          vim.list_extend(out, self:conflict({}, lines))
        else
          vim.list_extend(out, self:conflict(lines, {}))
        end
        -- merged children that are not in that copy (moved in from elsewhere)
        local extra = {}
        for c in pairs(children[k] or {}) do
          if not skip[c] then
            extra[c] = true
          end
        end
        if next(extra) then
          local saved = children[k]
          children[k] = extra
          emit(k, level)
          children[k] = saved
        end
      else
        local o, t = O.by_key[k], T.by_key[k]
        if o and t then
          vim.list_extend(out, self:own(B.by_key[k], o, t, level))
        else
          local e = o or t
          vim.list_extend(out, self:own(e, e, e, level))
        end
        emit(k, level)
      end
    end
  end
  emit("", 0)
  return { lines = out, conflicts = self.conflicts }
end

---------------------------------------------------------------------------
-- Files
---------------------------------------------------------------------------

--- Lines of a file and whether it ends with a newline.
---@param path string
---@return string[]|nil lines
---@return boolean eol
function M.read_file(path)
  local fh = io.open(path, "rb")
  if not fh then
    return nil, true
  end
  local data = fh:read("*a")
  fh:close()
  if data == "" then
    return {}, true
  end
  local eol = data:sub(-1) == "\n"
  if eol then
    data = data:sub(1, -2)
  end
  return vim.split(data, "\n", { plain = true }), eol
end

--- Merge three files, writing the result over `ours` (as git's %A).
---@param base_path string
---@param ours_path string
---@param theirs_path string
---@param opts? org.merge.Opts
---@return integer conflicts
function M.merge_files(base_path, ours_path, theirs_path, opts)
  local base = M.read_file(base_path) or {}
  local ours, eol = M.read_file(ours_path)
  local theirs = M.read_file(theirs_path) or {}
  ours = ours or {}
  local ok, res = pcall(M.merge, base, ours, theirs, opts)
  if not ok then
    -- the structure could not be merged: fall back to a plain line merge
    local lines, n = diff3.merge(base, ours, theirs, opts)
    res = { lines = lines, conflicts = n, error = res }
  end
  local fh = assert(io.open(ours_path, "wb"))
  local text = table.concat(res.lines, "\n")
  if #res.lines > 0 and eol then
    text = text .. "\n"
  end
  fh:write(text)
  fh:close()
  return res.conflicts, res.error
end

return M
