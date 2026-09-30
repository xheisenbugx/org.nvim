---@mod org.extensions.drill.card Drill cards: reading and rendering
---
--- A card is a headline with the drill tag. Its type comes from the
--- DRILL_CARD_TYPE property, inherited like in org-drill (its names):
---
---   simple           (default) the title and body are the question and the
---                    subheadings the answer; without subheadings the body
---                    is the answer. Clozes in the body are hidden.
---   twosided         one of the first two subheadings, at random, is shown
---                    with the title; the other is the answer
---   multisided       one of the subheadings, at random, is shown
---   hide1cloze       one cloze, at random, is hidden (also `multicloze`)
---   hide2cloze       two clozes, at random, are hidden
---   show1cloze       one cloze, at random, is shown and the others hidden
---   show2cloze       two clozes are shown and the others hidden
---   hidefirst        the first cloze is hidden
---   hidelast         the last cloze is hidden
---   hide1_firstmore  usually the first cloze is hidden, every
---                    `cloze_text_weight`th time another one
---   show1_lastmore   usually the last cloze is shown, every Nth time another
---   show1_firstless  usually a cloze other than the first is shown, every
---                    Nth time the first one

local cloze = require("org.extensions.drill.cloze")

local M = {}

M.TYPES = {
  simple = true,
  twosided = true,
  multisided = true,
  hide1cloze = true,
  hide2cloze = true,
  show1cloze = true,
  show2cloze = true,
  multicloze = true,
  hidefirst = true,
  hidelast = true,
  hide1_firstmore = true,
  show1_lastmore = true,
  show1_firstless = true,
}

-- card types asked even with an empty body (DRILL-EMPTY-P in
-- org-drill-card-type-alist)
M.EMPTY_OK = { twosided = true, multisided = true }

local function num(v)
  return v and tonumber(v) or nil
end

--- Lines of a headline's own section or of the subtree range [from, to],
--- without planning lines, property drawers and other drawers; deeper
--- headlines become `{ heading = title, level = n }` entries.
---@param file org.File
---@param from integer first line
---@param to integer last line
---@return (string|{ heading: string, level: integer })[]
local function content(file, from, to, first)
  local skip, heads = {}, {}
  -- the headlines of the range: from `first` (the entry itself) on
  local hls = file.headlines
  local i = first or 1
  while hls[i] and hls[i].line <= to do
    local h = hls[i]
    if h.line >= from - 1 then
      heads[h.line] = h
      if h.planning_line then
        skip[h.planning_line] = true
      end
      if h.properties_range then
        for l = h.properties_range[1], h.properties_range[2] do
          skip[l] = true
        end
      end
      for _, d in ipairs(h.drawers or {}) do
        for l = d.start, d["end"] do
          skip[l] = true
        end
      end
    end
    i = i + 1
  end
  local out = {}
  for l = from, to do
    if not skip[l] then
      local line = file.lines[l]
      local h = heads[l]
      if h then
        out[#out + 1] = { heading = h.title, level = h.level }
      else
        out[#out + 1] = line
      end
    end
  end
  -- trim blank lines at both ends
  while #out > 0 and type(out[#out]) == "string" and vim.trim(out[#out]) == "" do
    out[#out] = nil
  end
  while #out > 0 and type(out[1]) == "string" and vim.trim(out[1]) == "" do
    table.remove(out, 1)
  end
  -- remove the common indentation of text lines
  local indent
  for _, l in ipairs(out) do
    if type(l) == "string" and vim.trim(l) ~= "" then
      local w = #l:match("^%s*")
      indent = indent and math.min(indent, w) or w
    end
  end
  if indent and indent > 0 then
    for i, l in ipairs(out) do
      if type(l) == "string" then
        out[i] = l:sub(indent + 1)
      end
    end
  end
  return out
end

---@class org.drill.Card
---@field path string|nil file name
---@field bufnr integer|nil
---@field lnum integer headline line when read
---@field level integer headline level
---@field title string
---@field type string card type
---@field unknown string|nil a DRILL_CARD_TYPE org-drill doesn't know (the card is skipped)
---@field body (string|table)[] the entry's own text
---@field sides { title: string, lines: (string|table)[] }[] subheadings
---@field data org.drill.ItemData
---@field scheduled table|nil org.date
---@field last_reviewed table|nil org.date
---@field last_quality integer|nil DRILL_LAST_QUALITY
---@field interval number|nil DRILL_LAST_INTERVAL as written (nil when missing)
---@field weight number|nil DRILL_CARD_WEIGHT
---@field leech boolean tagged :leech:
---@field new boolean never reviewed
---@field nclozes integer clozes in the body

-- org-drill's card types this module asks like simple cards
M.ASKED_AS_SIMPLE = {
  simpletyped = true,
  conjugate = true,
  decline_noun = true,
  spanish_verb = true,
  translate_number = true,
}

-- LEARN_DATA, the format before DRILL_* properties: "(interval repeats ef)"
local function learn_data(s)
  local vals = {}
  for v in (s or ""):gmatch("[%d%.%-]+") do
    vals[#vals + 1] = tonumber(v)
  end
  return vals
end

--- Read the card at headline `hl` of `file`.
---@param file org.File
---@param hl org.Headline
---@return org.drill.Card
function M.read(file, hl)
  local p = hl.properties or {}
  -- org-drill reads DRILL_CARD_TYPE with inheritance
  local ok, inherited = pcall(hl.get_property, hl, "DRILL_CARD_TYPE", true)
  local raw = ok and inherited or p.DRILL_CARD_TYPE
  local ctype = vim.trim(raw or "simple"):lower()
  local unknown
  if ctype == "" then
    ctype = "simple"
  elseif not M.TYPES[ctype] then
    if not M.ASKED_AS_SIMPLE[ctype] then
      unknown = raw
    end
    ctype = "simple"
  end
  local body_end = hl.body_end or hl.end_line
  local body = content(file, hl.line + 1, body_end, hl.index)
  local sides = {}
  for _, child in ipairs(hl.children or {}) do
    sides[#sides + 1] = { title = child.title, lines = content(file, child.line + 1, child.end_line, child.index) }
  end
  local n = 0
  for _, l in ipairs(body) do
    if type(l) == "string" then
      n = n + #cloze.parse(l)
    end
  end
  local last = p.DRILL_LAST_REVIEWED and require("org.date").parse(p.DRILL_LAST_REVIEWED) or nil
  local data
  if p.LEARN_DATA then
    -- org-drill-get-item-data: the old format wins when present
    local v = learn_data(p.LEARN_DATA)
    data = {
      last_interval = v[1] or 0,
      repeats = v[2] or 0,
      failures = num(p.DRILL_FAILURE_COUNT) or 0,
      total_repeats = v[2] or 0,
      meanq = num(p.DRILL_LAST_QUALITY),
      ease = v[3],
    }
  else
    data = {
      last_interval = num(p.DRILL_LAST_INTERVAL) or 0,
      repeats = num(p.DRILL_REPEATS_SINCE_FAIL) or 0,
      failures = num(p.DRILL_FAILURE_COUNT) or 0,
      total_repeats = num(p.DRILL_TOTAL_REPEATS) or 0,
      meanq = num(p.DRILL_AVERAGE_QUALITY),
      ease = num(p.DRILL_EASE),
    }
  end
  local leech = false
  for _, t in ipairs(hl.tags or {}) do
    if t == "leech" then
      leech = true
    end
  end
  return {
    path = file.filename,
    bufnr = file.bufnr,
    lnum = hl.line,
    level = hl.level,
    title = hl.title,
    type = ctype,
    unknown = unknown,
    body = body,
    sides = sides,
    data = data,
    scheduled = hl.planning and hl.planning.scheduled or nil,
    last_reviewed = last,
    last_quality = num(p.DRILL_LAST_QUALITY),
    interval = num(p.DRILL_LAST_INTERVAL),
    weight = num(p.DRILL_CARD_WEIGHT),
    leech = leech,
    new = last == nil and data.total_repeats == 0,
    nclozes = n,
  }
end

--- Is there nothing to ask? Like org-drill-entry-empty-p, only the entry's
--- own text counts (not its subheadings); two- and multisided cards are
--- asked even without it.
---@param card org.drill.Card
function M.is_empty(card)
  if M.EMPTY_OK[card.type] and #card.sides > 0 then
    return false
  end
  for _, l in ipairs(card.body) do
    if type(l) == "table" or vim.trim(l) ~= "" then
      return false
    end
  end
  return true
end

--- Is the card due on day number `today`? Cards without a schedule are
--- due.
---@param card org.drill.Card
---@param today integer day number
function M.is_due(card, today)
  return card.scheduled == nil or card.scheduled:days() <= today
end

local function shuffled(n, random)
  local out = {}
  for i = 1, n do
    out[i] = i
  end
  for i = n, 2, -1 do
    local j = random(i)
    out[i], out[j] = out[j], out[i]
  end
  return out
end

--- org-drill-present-multicloze-hide-n: hide `n` of `count` clozes at
--- random (a negative `n` shows -n and hides the rest). Returns the set of
--- hidden cloze numbers.
---@param count integer
---@param n integer
---@param random fun(m: integer): integer
---@param force_show_first? boolean never hide the first
---@param force_show_last? boolean never hide the last
---@param force_hide_first? boolean always hide the first
---@return table<integer, boolean>
function M.hide_n(count, n, random, force_show_first, force_show_last, force_hide_first)
  local set = {}
  if count <= 0 then
    return set
  end
  if n < 0 then
    n = count + n
  end
  local positions = shuffled(count, random)
  local function remove(v)
    for i, x in ipairs(positions) do
      if x == v then
        table.remove(positions, i)
        return
      end
    end
  end
  if force_hide_first then
    remove(1)
    table.insert(positions, 1, 1)
  end
  if force_show_first then
    remove(1)
  end
  if force_show_last then
    remove(count)
  end
  for i = 1, math.min(n, #positions) do
    set[positions[i]] = true
  end
  return set
end

--- org-drill-present-multicloze-hide-nth: hide cloze `k` (negative counts
--- from the end).
---@return table<integer, boolean>
function M.hide_nth(count, k)
  if k < 0 then
    k = k + 1 + count
  end
  if count <= 0 or k < 1 or k > count then
    return {}
  end
  return { [k] = true }
end

--- Pick the random parts of a presentation: which side is shown
--- (two/multisided) or which clozes are hidden (`hidden`, for the cloze
--- types). `weight` is `cloze_text_weight` (nil: the weighted types act
--- like their plain versions).
---@param card org.drill.Card
---@param random fun(m: integer): integer returns 1..m
---@param weight? integer
---@return table choice
function M.choose(card, random, weight)
  local t = card.type
  local c = card.nclozes
  if t == "twosided" and #card.sides > 0 then
    return { side = random(math.min(2, #card.sides)) }
  elseif t == "multisided" and #card.sides > 0 then
    return { side = random(#card.sides) }
  end
  weight = tonumber(weight)
  if weight and weight <= 0 then
    weight = nil
  end
  -- the rare case of the weighted types: every `weight`th repetition
  local rare = weight and ((card.data.total_repeats or 0) + 1) % weight == 0
  if t == "hide1cloze" or t == "multicloze" then
    return { hidden = M.hide_n(c, 1, random) }
  elseif t == "hide2cloze" then
    return { hidden = M.hide_n(c, 2, random) }
  elseif t == "show1cloze" then
    return { hidden = M.hide_n(c, -1, random) }
  elseif t == "show2cloze" then
    return { hidden = M.hide_n(c, -2, random) }
  elseif t == "hidefirst" then
    return { hidden = M.hide_nth(c, 1) }
  elseif t == "hidelast" then
    return { hidden = M.hide_nth(c, -1) }
  elseif t == "hide1_firstmore" then
    if not weight then
      return { hidden = M.hide_n(c, 1, random) }
    elseif rare then
      return { hidden = M.hide_n(c, 1, random, true) }
    end
    return { hidden = M.hide_nth(c, 1) }
  elseif t == "show1_lastmore" then
    if not weight then
      return { hidden = M.hide_n(c, -1, random) }
    elseif rare then
      return { hidden = M.hide_n(c, -1, random, false, false, true) }
    end
    return { hidden = M.hide_n(c, -1, random, false, true) }
  elseif t == "show1_firstless" then
    if not weight then
      return { hidden = M.hide_n(c, -1, random) }
    elseif rare then
      return { hidden = M.hide_n(c, -1, random, true) }
    end
    return { hidden = M.hide_n(c, -1, random, false, false, true) }
  end
  return {}
end

-- how a cloze numbered `k` looks before the answer is shown: "hidden" or
-- "plain" (its text without brackets). Cards without a `hidden` set (simple,
-- two- and multisided) hide every cloze.
local function cloze_state(choice, k)
  if choice.hidden then
    return choice.hidden[k] and "hidden" or "plain"
  end
  return "hidden"
end

---@class org.drill.Rendered
---@field lines string[]
---@field hls { [1]: integer, [2]: integer, [3]: integer, [4]: string }[] row0, col0, end_col0, group

--- The lines shown for a card: the question, and with `revealed` the
--- answer too.
---@param card org.drill.Card
---@param choice table from `choose`
---@param revealed boolean
---@return org.drill.Rendered
function M.render(card, choice, revealed)
  local lines, hls = {}, {}
  local k = 0
  local function add(text, group)
    lines[#lines + 1] = text
    if group and text ~= "" then
      hls[#hls + 1] = { #lines - 1, 0, #text, group }
    end
  end
  local function add_text(l, indent)
    indent = indent or ""
    if type(l) == "table" then
      local depth = math.max(l.level - (card.level or 0) - 2, 0)
      add(indent .. string.rep("  ", depth) .. "▸ " .. l.heading, "OrgDrillHeading")
      return
    end
    local out, pos, marks = {}, 1, {}
    local len = #indent
    for _, c in ipairs(cloze.parse(l)) do
      k = k + 1
      out[#out + 1] = l:sub(pos, c.s - 1)
      len = len + (c.s - pos)
      local state = revealed and "shown" or cloze_state(choice, k)
      local text, group
      if state == "hidden" then
        text, group = cloze.hidden_text(c), "OrgDrillHidden"
      elseif state == "shown" then
        text, group = c.text, "OrgDrillCloze"
      else
        text = c.text
      end
      out[#out + 1] = text
      if group then
        marks[#marks + 1] = { len, len + #text, group }
      end
      len = len + #text
      pos = c.e + 1
    end
    out[#out + 1] = l:sub(pos)
    add(indent .. table.concat(out))
    for _, m in ipairs(marks) do
      hls[#hls + 1] = { #lines - 1, m[1], m[2], m[3] }
    end
  end
  local function add_side(side, indent)
    add(indent .. side.title, "OrgDrillSide")
    for _, l in ipairs(side.lines) do
      add_text(l, indent .. "  ")
    end
  end

  add(card.title, "OrgDrillTitle")
  add("")
  local t = card.type
  local sided = (t == "twosided" or t == "multisided") and choice.side
  local body_is_answer = t == "simple" and #card.sides == 0 and card.nclozes == 0
  if not body_is_answer then
    for _, l in ipairs(card.body) do
      add_text(l)
    end
  end
  if sided then
    if #card.body > 0 then
      add("")
    end
    add_side(card.sides[choice.side], "")
  end
  if not revealed then
    return { lines = lines, hls = hls }
  end
  -- the answer
  local answer = {}
  if body_is_answer then
    answer = { { body = true } }
  else
    for i, side in ipairs(card.sides) do
      if not (sided and i == choice.side) then
        answer[#answer + 1] = side
      end
    end
  end
  if #answer > 0 then
    if lines[#lines] ~= "" then
      add("")
    end
    add("── Answer ──", "OrgDrillRule")
    add("")
    for _, a in ipairs(answer) do
      if a.body then
        for _, l in ipairs(card.body) do
          add_text(l)
        end
      else
        add_side(a, "")
      end
    end
  end
  return { lines = lines, hls = hls }
end

return M
