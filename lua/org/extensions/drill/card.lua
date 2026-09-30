---@mod org.extensions.drill.card Drill cards: reading and rendering
---
--- A card is a headline with the drill tag. Its type comes from the
--- DRILL_CARD_TYPE property (org-drill's names):
---
---   simple      (default) the title and body are the question and the
---               subheadings the answer; without subheadings the body is the
---               answer. Clozes in the body are hidden.
---   twosided    one of the first two subheadings, at random, is shown with
---               the title; the other is the answer
---   multisided  one of the subheadings, at random, is shown
---   hide1cloze  one cloze, at random, is hidden and the others shown
---   show1cloze  one cloze, at random, is shown and the others hidden
---   hide2cloze  two clozes, at random, are hidden and the others shown

local cloze = require("org.extensions.drill.cloze")

local M = {}

M.TYPES = {
  simple = true,
  twosided = true,
  multisided = true,
  hide1cloze = true,
  show1cloze = true,
  hide2cloze = true,
}

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
local function content(file, from, to)
  local skip = {}
  for _, h in ipairs(file.headlines) do
    if h.line >= from - 1 and h.line <= to then
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
  end
  local out = {}
  for l = from, to do
    if not skip[l] then
      local line = file.lines[l]
      local h = file:headline_on(l)
      if h and h.line == l then
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
---@field body (string|table)[] the entry's own text
---@field sides { title: string, lines: (string|table)[] }[] subheadings
---@field data org.drill.ItemData
---@field scheduled table|nil org.date
---@field last_reviewed table|nil org.date
---@field new boolean never reviewed
---@field nclozes integer clozes in the body

--- Read the card at headline `hl` of `file`.
---@param file org.File
---@param hl org.Headline
---@return org.drill.Card
function M.read(file, hl)
  local p = hl.properties or {}
  local ctype = (p.DRILL_CARD_TYPE or "simple"):lower()
  if not M.TYPES[ctype] then
    ctype = "simple"
  end
  local body_end = hl.body_end or hl.end_line
  local body = content(file, hl.line + 1, body_end)
  local sides = {}
  for _, child in ipairs(hl.children or {}) do
    sides[#sides + 1] = { title = child.title, lines = content(file, child.line + 1, child.end_line) }
  end
  local n = 0
  for _, l in ipairs(body) do
    if type(l) == "string" then
      n = n + #cloze.parse(l)
    end
  end
  local last = p.DRILL_LAST_REVIEWED and require("org.date").parse(p.DRILL_LAST_REVIEWED) or nil
  local total = num(p.DRILL_TOTAL_REPEATS) or 0
  return {
    path = file.filename,
    bufnr = file.bufnr,
    lnum = hl.line,
    level = hl.level,
    title = hl.title,
    type = ctype,
    body = body,
    sides = sides,
    data = {
      last_interval = num(p.DRILL_LAST_INTERVAL) or 0,
      repeats = num(p.DRILL_REPEATS_SINCE_FAIL) or 0,
      failures = num(p.DRILL_FAILURE_COUNT) or 0,
      total_repeats = total,
      meanq = num(p.DRILL_AVERAGE_QUALITY),
      ease = num(p.DRILL_EASE),
    },
    scheduled = hl.planning and hl.planning.scheduled or nil,
    last_reviewed = last,
    new = last == nil and total == 0,
    nclozes = n,
  }
end

--- Is there anything to ask? (org-drill skips empty cards.)
---@param card org.drill.Card
function M.is_empty(card)
  local function blank(lines)
    for _, l in ipairs(lines) do
      if type(l) == "table" or vim.trim(l) ~= "" then
        return false
      end
    end
    return true
  end
  return blank(card.body) and #card.sides == 0
end

--- Is the card due on day number `today`? New cards and cards without a
--- schedule are due.
---@param card org.drill.Card
---@param today integer day number
function M.is_due(card, today)
  return card.scheduled == nil or card.scheduled:days() <= today
end

--- Pick the random parts of a presentation: which side is shown
--- (two/multisided) or which clozes (hide1cloze, show1cloze, hide2cloze).
---@param card org.drill.Card
---@param random fun(m: integer): integer returns 1..m
---@return table choice
function M.choose(card, random)
  local t = card.type
  if t == "twosided" and #card.sides > 0 then
    return { side = random(math.min(2, #card.sides)) }
  elseif t == "multisided" and #card.sides > 0 then
    return { side = random(#card.sides) }
  elseif (t == "hide1cloze" or t == "show1cloze") and card.nclozes > 0 then
    return { clozes = { [random(card.nclozes)] = true } }
  elseif t == "hide2cloze" and card.nclozes > 0 then
    local a = random(card.nclozes)
    local set = { [a] = true }
    if card.nclozes > 1 then
      local b = random(card.nclozes - 1)
      if b >= a then
        b = b + 1
      end
      set[b] = true
    end
    return { clozes = set }
  end
  return {}
end

-- how a cloze numbered `k` looks before the answer is shown: "hidden" or
-- "plain" (its text without brackets)
local function cloze_state(card, choice, k)
  local t = card.type
  local picked = choice.clozes and choice.clozes[k]
  if t == "hide1cloze" or t == "hide2cloze" then
    return picked and "hidden" or "plain"
  elseif t == "show1cloze" then
    return picked and "plain" or "hidden"
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
      local state = revealed and "shown" or cloze_state(card, choice, k)
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
