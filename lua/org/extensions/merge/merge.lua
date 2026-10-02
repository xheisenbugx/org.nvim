---@mod org.extensions.merge.merge Structural three-way merge of Org files
---
--- Each version (base, ours, theirs) is parsed with `org.parser` into a tree
--- of entries. An entry is matched across versions by its `ID` (or
--- `CUSTOM_ID`) property, else by its outline path and title; an entry
--- renamed on one side is still matched when the rest of its content is
--- unchanged or similar enough, and one that got an ID on one side by its
--- title. Entries are then merged one by one:
---
---   - changes to different entries never conflict;
---   - an entry moved (a different parent or place) is followed; moved to
---     different parents on both sides, it conflicts at both places;
---   - the headline's TODO keyword, priority, COMMENT and title, and each
---     planning keyword, are merged as values: a change on one side wins,
---     different changes on both sides conflict (or `prefer` picks one);
---   - tags: removals on either side are kept and additions are unioned;
---   - the property drawer is merged key by key;
---   - LOGBOOK items (CLOCK lines, state and note items), and those of the
---     other log drawers, are unioned, with removals kept, and sorted newest
---     first when both sides added some;
---   - the rest of the entry's text is merged line by line (diff3).
---
--- Conflict markers only ever wrap the lines of the one entry (or the one
--- property) in conflict.

local parser = require("org.parser")
local diff3 = require("org.extensions.merge.diff3")

local M = {}

---@class org.merge.Opts: org.merge.Diff3Opts
---@field prefer? "ours"|"theirs" side taken when both changed the same headline field, planning keyword or property, or moved an entry to different parents
---@field sort_logbook? boolean sort LOGBOOK items newest first when both sides added some (true)
---@field set_drawers? string[] more drawers merged item by item like LOGBOOK
---@field rename_similarity? number|false share of equal lines for a renamed and edited entry to be matched (0.6)

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

-- Names of the drawers merged as sets of items: LOGBOOK, the log and
-- clock drawers of the configuration, and `opts.set_drawers`.
local function set_drawer_names(opts)
  local names = { LOGBOOK = true }
  local ok, cfg = pcall(function()
    return require("org.config").opts
  end)
  if ok and type(cfg) == "table" then
    if type(cfg.log_into_drawer) == "string" then
      names[cfg.log_into_drawer:upper()] = true
    end
    local into = type(cfg.clock) == "table" and cfg.clock.into_drawer
    if type(into) == "string" then
      names[into:upper()] = true
    end
  end
  for _, n in ipairs(opts and opts.set_drawers or {}) do
    names[tostring(n):upper()] = true
  end
  return names
end

local function new_entry(lines, hl, drawer_names)
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
  -- the log drawers right after the planning line and properties, merged
  -- item by item
  e.drawers = {}
  local at = {}
  for _, d in ipairs(hl.drawers or {}) do
    at[d.start] = d
  end
  while at[i] and at[i]["end"] and drawer_names[(at[i].name or ""):upper()] do
    local d = at[i]
    local name = d.name:upper()
    if e.drawers[name] then
      break
    end
    e.drawers[name] = {
      open = lines[d.start],
      close = lines[d["end"]],
      items = logbook_items(slice(lines, d.start + 1, d["end"] - 1)),
    }
    e.drawers[#e.drawers + 1] = name
    i = d["end"] + 1
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
    -- the closing lines too: without them, ":PROPERTIES:" ":END:"
    -- ":LOGBOOK:" ":END:" would read the same as ":PROPERTIES:"
    -- ":LOGBOOK:" ":END:" (a LOGBOOK line inside the properties)
    parts[#parts + 1] = e.props.close
  end
  for _, name in ipairs(e.drawers) do
    local d = e.drawers[name]
    parts[#parts + 1] = d.open
    vim.list_extend(parts, d.items)
    parts[#parts + 1] = d.close
  end
  parts[#parts + 1] = "\0"
  vim.list_extend(parts, e.body)
  return table.concat(parts, "\n")
end

-- Content apart from the headline, to recognise a renamed entry: its
-- text, or for an entry without text the titles of its children.
local function content_sig(e)
  if e.sig == nil then
    local s = own_text(e, true)
    if not s:find("%S") or s:match("^%s*%z%s*$") then
      s = false
      if #e.children > 0 then
        local titles = {}
        for i, c in ipairs(e.children) do
          titles[i] = c.title
        end
        s = "\1" .. table.concat(titles, "\n")
      end
    end
    e.sig = s
  end
  return e.sig or nil
end

-- The meaningful lines of an entry apart from its headline (no blank
-- lines or drawer delimiters), counted, to compare entries.
local function content_bag(e)
  if not e.bag then
    local bag, n = {}, 0
    local function add(l)
      l = vim.trim(l)
      if l ~= "" and not l:match("^:[%w_-]+:$") then
        bag[l] = (bag[l] or 0) + 1
        n = n + 1
      end
    end
    add(e.planning_raw or "")
    for _, k in ipairs(e.props and e.props.order or {}) do
      add(e.props.map[k])
    end
    for _, name in ipairs(e.drawers) do
      for _, it in ipairs(e.drawers[name].items) do
        add(it)
      end
    end
    for _, l in ipairs(e.body) do
      add(l)
    end
    for _, c in ipairs(e.children) do
      add("\1" .. c.title)
    end
    e.bag, e.bag_n = bag, n
  end
  return e.bag, e.bag_n
end

-- Similarity (Dice coefficient of the content lines) of two entries.
local function similarity(a, b)
  local ba, na = content_bag(a)
  local bb, nb = content_bag(b)
  if na == 0 or nb == 0 then
    return 0
  end
  local common = 0
  for l, c in pairs(ba) do
    if bb[l] then
      common = common + math.min(c, bb[l])
    end
  end
  return 2 * common / (na + nb)
end

-- Pairs of entries compared at most per parent when looking for renamed
-- entries by similarity (beyond that only exact matches are found).
local SIMILARITY_BUDGET = 250000

---@class org.merge.Version
---@field lines string[]
---@field root table
---@field by_key table<string, table>

local function set_keys(version, base, opts)
  local threshold = tonumber(opts and opts.rename_similarity) or 0.6
  if opts and opts.rename_similarity == false then
    threshold = 2
  end
  -- IDs are unique in the whole file: a repeated ID gets a numbered key
  -- (in file order), so no entry is ever dropped
  local id_counts = {}
  local ids = {}
  local function collect(e)
    for _, c in ipairs(e.children) do
      if c.id then
        ids[c.id] = true
      end
      collect(c)
    end
  end
  collect(version.root)
  local function walk(e)
    local counts = {}
    local fresh = {}
    for _, c in ipairs(e.children) do
      local k
      if c.id then
        k = "id:" .. c.id
        id_counts[k] = (id_counts[k] or 0) + 1
        if id_counts[k] > 1 then
          k = k .. DUP .. id_counts[k]
        end
      else
        k = e.key .. SEP .. c.title
        counts[k] = (counts[k] or 0) + 1
        if counts[k] > 1 then
          k = k .. DUP .. counts[k]
        end
      end
      c.key = k
      if base and not base.by_key[k] then
        fresh[#fresh + 1] = c
      end
    end
    -- an entry renamed on this side, or one that got an ID here: an
    -- unmatched base child with the same title, the same content, or
    -- (without an ID) similar content
    local bparent = base and base.by_key[e.key]
    if #fresh > 0 and bparent then
      local taken = {}
      for _, c in ipairs(e.children) do
        taken[c.key] = true
      end
      local function free(b)
        -- a base entry whose ID is still somewhere in this version is
        -- matched by that ID, not here
        return not taken[b.key] and not (b.id and ids[b.id])
      end
      local by_title, by_sig = {}, {}
      local cands = {}
      for _, b in ipairs(bparent.children) do
        if free(b) then
          cands[#cands + 1] = b
          by_title[b.title] = by_title[b.title] or b
          local sig = content_sig(b)
          if sig then
            by_sig[sig] = by_sig[sig] or {}
            table.insert(by_sig[sig], b)
          end
        end
      end
      local matched = {}
      local function take(c, b)
        taken[b.key] = true
        c.key = b.key
        matched[c] = true
      end
      local rest = {}
      for _, c in ipairs(fresh) do
        local b = by_title[c.title]
        if b and c.id and not taken[b.key] and not b.id then
          -- an ID added on this side
          take(c, b)
        else
          local found
          for _, x in ipairs(by_sig[content_sig(c) or false] or {}) do
            if not taken[x.key] and not (c.id and x.id) then
              found = x
              break
            end
          end
          if found then
            take(c, found)
          elseif not c.id then
            rest[#rest + 1] = c
          end
        end
      end
      -- renamed and edited: the most similar remaining base entry
      if #rest > 0 and threshold <= 1 and #rest * #cands <= SIMILARITY_BUDGET then
        for _, c in ipairs(rest) do
          local best, score = nil, threshold
          for _, b in ipairs(cands) do
            if not taken[b.key] and not b.id then
              local s = similarity(c, b)
              if s >= score then
                best, score = b, s
              end
            end
          end
          if best then
            take(c, best)
          end
        end
      end
      -- a headline edited in place (no text to compare): the base entry
      -- between the same two neighbours
      if #rest > 0 then
        local pos = {}
        for i, c in ipairs(e.children) do
          pos[c] = i
        end
        local function around(list, i)
          local p, n = list[i - 1], list[i + 1]
          return (p and p.key or "^") .. SEP .. (n and n.key or "$")
        end
        local by_place = {}
        for i, b in ipairs(bparent.children) do
          if not taken[b.key] and not b.id and not content_sig(b) then
            by_place[around(bparent.children, i)] = b
          end
        end
        for _, c in ipairs(rest) do
          local b = by_place[around(e.children, pos[c])]
          if b and not taken[b.key] and not matched[c] and not content_sig(c) then
            take(c, b)
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
---@param opts? org.merge.Opts
---@return org.merge.Version
function M.read(lines, base, opts)
  local file = parser.parse(lines)
  local drawer_names = set_drawer_names(opts)
  local root = { key = "", level = 0, children = {}, preamble = slice(lines, 1, file.preamble_end or #lines) }
  local map = {}
  for _, hl in ipairs(file.headlines) do
    if not hl.inlinetask then
      local e = new_entry(lines, hl, drawer_names)
      map[hl] = e
      local parent = hl.parent and map[hl.parent] or root
      parent.children[#parent.children + 1] = e
    end
  end
  local version = { lines = lines, root = root, by_key = {} }
  set_keys(version, base, opts)
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
  -- items as multisets: an item repeated on purpose (two identical CLOCK
  -- lines) keeps its copies
  local function count(l)
    local c = {}
    for _, x in ipairs(l) do
      c[x] = (c[x] or 0) + 1
    end
    return c
  end
  local cb, co, ct = count(b), count(o), count(t)
  local want = {}
  for _, src in ipairs({ co, ct }) do
    for x in pairs(src) do
      local nb, no, nt = cb[x] or 0, co[x] or 0, ct[x] or 0
      if no == nb then
        want[x] = nt
      elseif nt == nb then
        want[x] = no
      else
        want[x] = math.max(no, nt)
      end
    end
  end
  local out, used = {}, {}
  for _, l in ipairs({ o, t }) do
    for _, x in ipairs(l) do
      if (used[x] or 0) < want[x] then
        used[x] = (used[x] or 0) + 1
        out[#out + 1] = x
      end
    end
  end
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
    for _, name in ipairs(e.drawers) do
      local d = e.drawers[name]
      l[#l + 1] = d.open
      for _, it in ipairs(d.items) do
        vim.list_extend(l, vim.split(it, "\n", { plain = true }))
      end
      l[#l + 1] = d.close
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
    -- (not ipairs{ o.props, t.props }: it stops at a side without a drawer)
    for _, src in ipairs({ o.props or {}, t.props or {} }) do
      for _, k in ipairs(src.order or {}) do
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
  -- LOGBOOK and the other log drawers, item by item
  local names, seen_name = {}, {}
  for _, e in ipairs({ o, t }) do
    for _, name in ipairs(e.drawers) do
      if not seen_name[name] then
        seen_name[name], names[#names + 1] = true, name
      end
    end
  end
  for _, name in ipairs(names) do
    local bd, od, td = b and b.drawers[name], o.drawers[name], t.drawers[name]
    local items = logbook_merge(bd and bd.items, od and od.items, td and td.items, self.opts.sort_logbook ~= false)
    if #items > 0 or (od and td) then
      local d = od or td
      out[#out + 1] = d.open
      for _, it in ipairs(items) do
        vim.list_extend(out, vim.split(it, "\n", { plain = true }))
      end
      out[#out + 1] = d.close
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
  -- CRLF line ends and a UTF-8 BOM are taken off for the parser and put
  -- back on the result, in the style of ours (theirs when ours is empty)
  local BOM = "\239\187\191"
  local function style(lines)
    local cr, n = 0, 0
    for _, l in ipairs(lines) do
      if l ~= "" then
        n = n + 1
        if l:sub(-1) == "\r" then
          cr = cr + 1
        end
      end
    end
    return n > 0 and cr * 2 > n, (lines[1] or ""):sub(1, 3) == BOM
  end
  local function clean(lines)
    local crlf, bom = style(lines)
    if not (crlf or bom) then
      return lines, crlf, bom
    end
    local out = {}
    for i, l in ipairs(lines) do
      if crlf and l:sub(-1) == "\r" then
        l = l:sub(1, -2)
      end
      if i == 1 and bom then
        l = l:sub(4)
      end
      out[i] = l
    end
    return out, crlf, bom
  end
  local crlf, bom
  base = clean(base)
  local oc, ob, tc, tb
  ours, oc, ob = clean(ours)
  theirs, tc, tb = clean(theirs)
  if #ours > 0 then
    crlf, bom = oc, ob
  else
    crlf, bom = tc, tb
  end
  local res = M.merge_lines(base, ours, theirs, opts)
  if crlf then
    for i, l in ipairs(res.lines) do
      res.lines[i] = l .. "\r"
    end
  end
  if bom and res.lines[1] then
    res.lines[1] = BOM .. res.lines[1]
  end
  return res
end

--- `M.merge` of lines without CRLF line ends or a BOM.
---@param base string[]
---@param ours string[]
---@param theirs string[]
---@param opts? org.merge.Opts
---@return org.merge.Result
function M.merge_lines(base, ours, theirs, opts)
  opts = opts or {}
  local B = M.read(base, nil, opts)
  local O = M.read(ours, B, opts)
  local T = M.read(theirs, B, opts)
  local self = setmetatable({ opts = opts, conflicts = 0 }, Merger)

  -- which entries stay, and where
  -- moved[k]: theirs' parent of an entry both sides moved to different
  -- parents (it goes under ours', with a conflict at both places)
  local state, parent_of, moved = {}, {}, {}
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
        -- moved to different parents on both sides: `prefer` picks one,
        -- else it is a conflict (see `moved`)
        p = opts.prefer == "theirs" and t.parent_key or o.parent_key
        if not opts.prefer then
          moved[k] = t.parent_key
        end
      end
      parent_of[k] = p
    end
  end
  -- moves on both sides can make a cycle (ours put X under Y, theirs Y
  -- under X): an entry of a cycle goes back under its parent in ours (or
  -- theirs), and the other side's place becomes a conflict
  local function cycle_at(k)
    local visiting, x = {}, k
    while x and x ~= "" and parent_of[x] and not visiting[x] do
      visiting[x] = true
      x = parent_of[x]
    end
    return x and x ~= "" and visiting[x] and x or nil
  end
  for _, k in ipairs(keys) do
    local x = cycle_at(k)
    if x then
      local o, t = O.by_key[x], T.by_key[x]
      local b = B.by_key[x]
      local alt = {}
      for _, e in ipairs({ o, t, b }) do
        if e and e.parent_key ~= parent_of[x] then
          alt[#alt + 1] = e.parent_key
        end
      end
      if alt[1] then
        if o and t and o.parent_key ~= t.parent_key and not opts.prefer then
          moved[x] = parent_of[x]
        end
        parent_of[x] = alt[1]
      end
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
  for _, k in ipairs(keys) do
    local x = cycle_at(k)
    if x then
      -- still a cycle: keep the entry at the top level rather than lose it
      parent_of[x] = ""
    end
  end
  local children = {}
  -- ghost[p][k]: theirs' place (under p) of an entry moved both ways
  local ghost = {}
  for _, k in ipairs(keys) do
    if state[k] ~= "deleted" then
      local p = parent_of[k]
      children[p] = children[p] or {}
      children[p][k] = true
      local gp = moved[k]
      if gp and gp ~= p and state[k] == "both" then
        children[gp] = children[gp] or {}
        children[gp][k] = true
        ghost[gp] = ghost[gp] or {}
        ghost[gp][k] = true
      else
        moved[k] = nil
      end
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
    local placed = {}
    for _, k in ipairs(basis) do
      placed[k] = true
    end
    -- an entry only in `other` goes right after the one before it there
    -- (after[""]: at the start); linear, not an insert per entry
    local after = {}
    for i, k in ipairs(other) do
      if not placed[k] then
        after[other[i - 1] or ""] = k
        placed[k] = true
      end
    end
    local result = {}
    local function put(k)
      while k do
        result[#result + 1] = k
        k = after[k]
      end
    end
    put(after[""])
    for _, k in ipairs(basis) do
      put(k)
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

  local emit
  local function emit_entry(p, plevel, k)
    local src = source(k)
    local rel = rel_level(src)
    do
      -- the depth below the parent is merged like a value: a level changed
      -- on one side only (`* A` / `*** B` -> `** B`) is kept
      local b, o, t = B.by_key[k], O.by_key[k], T.by_key[k]
      if o and t and o.parent_key == p and t.parent_key == p then
        local v = merge3(b and b.parent_key == p and rel_level(b) or nil, rel_level(o), rel_level(t))
        rel = v or rel
      end
    end
    local level = math.max(1, plevel + rel)
    local st = state[k]
    local skip = {}
    if ghost[p] and ghost[p][k] then
      -- theirs' place of an entry both sides moved: theirs' subtree on
      -- the theirs side of a conflict
      local t = T.by_key[k]
      local lines = verbatim(T, t, math.max(1, plevel + rel_level(t)))
      vim.list_extend(out, self:conflict({}, lines))
    elseif moved[k] then
      -- ours' place of it: the merged subtree on the ours side (unless it
      -- has conflicts of its own, which markers can't nest)
      local saved, before = out, self.conflicts
      out = {}
      moved[k] = nil
      emit_entry(p, plevel, k)
      local lines = out
      out = saved
      if self.conflicts > before then
        vim.list_extend(out, lines)
      else
        vim.list_extend(out, self:conflict(lines, {}))
      end
    elseif st == "del_ours" or st == "del_theirs" then
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
  emit = function(p, plevel)
    for _, k in ipairs(order_children(p)) do
      emit_entry(p, plevel, k)
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
