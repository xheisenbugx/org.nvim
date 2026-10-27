---@mod org.ui.decorations Visual decorations (bullets, checkboxes, indent mode, entities, numbering)
---
--- Enabled through `ui.bullets`, `ui.hide_leading_stars`, `ui.checkboxes`,
--- `ui.indent_mode`, `ui.pretty_entities` and `ui.num`, or per buffer by
--- `#+STARTUP:` (indent/noindent, hidestars/showstars,
--- entitiespretty/entitiesplain, num/nonum) and the toggles
--- toggle_pretty_entities (org-toggle-pretty-entities) and num_mode
--- (org-num-mode). Drawn at redraw time by a decoration provider (see
--- below).

local M = {}

local ns = vim.api.nvim_create_namespace("org.decorations")

--- The UTF-8 form of an entity (org-entities), e.g. `M.entities.alpha`.
M.entities = setmetatable({}, {
  __index = function(_, name)
    return require("org.entities").utf8(name)
  end,
})

local SUPER = {
  ["0"] = "⁰",
  ["1"] = "¹",
  ["2"] = "²",
  ["3"] = "³",
  ["4"] = "⁴",
  ["5"] = "⁵",
  ["6"] = "⁶",
  ["7"] = "⁷",
  ["8"] = "⁸",
  ["9"] = "⁹",
  ["+"] = "⁺",
  ["-"] = "⁻",
  ["="] = "⁼",
  ["("] = "⁽",
  [")"] = "⁾",
  a = "ᵃ",
  b = "ᵇ",
  c = "ᶜ",
  d = "ᵈ",
  e = "ᵉ",
  f = "ᶠ",
  g = "ᵍ",
  h = "ʰ",
  i = "ⁱ",
  j = "ʲ",
  k = "ᵏ",
  l = "ˡ",
  m = "ᵐ",
  n = "ⁿ",
  o = "ᵒ",
  p = "ᵖ",
  r = "ʳ",
  s = "ˢ",
  t = "ᵗ",
  u = "ᵘ",
  v = "ᵛ",
  w = "ʷ",
  x = "ˣ",
  y = "ʸ",
  z = "ᶻ",
  A = "ᴬ",
  B = "ᴮ",
  D = "ᴰ",
  E = "ᴱ",
  G = "ᴳ",
  H = "ᴴ",
  I = "ᴵ",
  J = "ᴶ",
  K = "ᴷ",
  L = "ᴸ",
  M = "ᴹ",
  N = "ᴺ",
  O = "ᴼ",
  P = "ᴾ",
  R = "ᴿ",
  T = "ᵀ",
  U = "ᵁ",
  V = "ⱽ",
  W = "ᵂ",
}
local SUB = {
  ["0"] = "₀",
  ["1"] = "₁",
  ["2"] = "₂",
  ["3"] = "₃",
  ["4"] = "₄",
  ["5"] = "₅",
  ["6"] = "₆",
  ["7"] = "₇",
  ["8"] = "₈",
  ["9"] = "₉",
  ["+"] = "₊",
  ["-"] = "₋",
  ["="] = "₌",
  ["("] = "₍",
  [")"] = "₎",
  a = "ₐ",
  e = "ₑ",
  h = "ₕ",
  i = "ᵢ",
  j = "ⱼ",
  k = "ₖ",
  l = "ₗ",
  m = "ₘ",
  n = "ₙ",
  o = "ₒ",
  p = "ₚ",
  r = "ᵣ",
  s = "ₛ",
  t = "ₜ",
  u = "ᵤ",
  v = "ᵥ",
  x = "ₓ",
}

--- Which `^` and `_` are sub/superscripts in a buffer: `#+OPTIONS: ^:`
--- overrides `default` (org-use-sub-superscripts, set buffer-locally by
--- org-set-regexps-and-options). `^:nil` is displayed like `^:{}`, as
--- org-raise-scripts treats anything but t as braces only.
---@param file? org.File
---@return boolean|string
function M.sub_superscripts(file, default)
  local value = default
  local opts = file and file.settings and file.settings.keywords and file.settings.keywords.OPTIONS
  for _, v in ipairs(opts or {}) do
    for item in tostring(v):gmatch("%S+") do
      local w = item:match("^%^:(.*)$")
      if w == "t" then
        value = true
      elseif w == "{}" or w == "nil" then
        value = "{}"
      end
    end
  end
  return value
end

--- The `ui` options of a buffer: `#+STARTUP` words and the buffer toggles
--- override the configuration.
---@param file? org.File the parsed buffer, when the caller has it
function M.ui_options(bufnr, file)
  local ui = vim.deepcopy(require("org.config").opts.ui)
  local ok = file ~= nil
  if not ok then
    ok, file = pcall(require("org.files").get_buffer, bufnr)
  end
  local st = ok and file and file.settings.startup or {}
  local function flag(key, on, off)
    if st[on] then
      ui[key] = true
    elseif st[off] then
      ui[key] = false
    end
  end
  flag("indent_mode", "indent", "noindent")
  flag("hide_leading_stars", "hidestars", "showstars")
  flag("pretty_entities", "entitiespretty", "entitiesplain")
  flag("num", "num", "nonum")
  if ok then
    ui.use_sub_superscripts = M.sub_superscripts(file, ui.use_sub_superscripts)
  end
  if vim.api.nvim_buf_is_valid(bufnr) then
    if vim.b[bufnr].org_indent_mode ~= nil then
      ui.indent_mode = vim.b[bufnr].org_indent_mode
    end
    if vim.b[bufnr].org_pretty_entities ~= nil then
      ui.pretty_entities = vim.b[bufnr].org_pretty_entities
    end
    if vim.b[bufnr].org_num_mode ~= nil then
      ui.num = vim.b[bufnr].org_num_mode
    end
    -- `ui` options set for one buffer (presentation slides draw their own
    -- headlines)
    for k, v in pairs(vim.b[bufnr].org_ui or {}) do
      ui[k] = v
    end
  end
  if ui.indent_mode then
    -- org-indent-mode-turns-on-hiding-stars
    ui.hide_leading_stars = true
  end
  return ui
end

--- Virtual indentation widths of org-indent-mode
--- (org-indent--compute-prefixes): the prefix of a level-n headline and of
--- the text under it, `ui.indent_indentation_per_level` columns per level
--- (org-indent-indentation-per-level). 0 turns the prefixes off.
---@return integer heading, integer text
function M.indent_widths(ui, level)
  local per = ui.indent_indentation_per_level or 2
  if per <= 0 or level <= 0 then
    return 0, 0
  end
  local indentation = level <= 1 and 0 or (per - 1) * (level - 1)
  return indentation, level + indentation + 1
end

--- org-adapt-indentation in buffer `bufnr`: off while indent mode is on
--- (org-indent-mode-turns-off-org-adapt-indentation).
function M.adapt_indentation(bufnr)
  local cfg = require("org.config").opts
  if not cfg.adapt_indentation then
    return false
  end
  if cfg.ui.indent_mode_turns_off_adapt_indentation == false then
    return cfg.adapt_indentation
  end
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local ok, ui = pcall(M.ui_options, bufnr)
  if ok and ui.indent_mode then
    return false
  end
  return cfg.adapt_indentation
end

local EMPH_PRE = "[%s%(%'\"{%-]"
local EMPH_POST = "[%s%-%.,:!%?;%'\"%)}%[]"

--- Byte ranges [s, e] of the emphasis (any marker) in `line`, as
--- org-do-emphasis-faces finds it on one line: a marker after the start or
--- a pre character, a non-blank text, the same marker after a non-blank and
--- before a post character or the end.
local function emphasis_ranges(line, out)
  -- Whether a marker closes doesn't depend on the opening one: per marker,
  -- the last search (from where it started to the closing marker it found,
  -- or to the end of the line) answers for any opening in between. Without
  -- it, a long line of unclosed markers was searched to its end from each.
  local last = {}
  for i = 1, #line do
    local m = line:sub(i, i)
    if
      m:find("^[*/_+=~]")
      and (i == 1 or line:sub(i - 1, i - 1):find("^" .. EMPH_PRE))
      and line:sub(i + 1, i + 1):find("^%S")
      and not (m == "*" and i == 1 and line:find("^%*+ "))
    then
      local from = i + 2
      local l = last[m]
      local close
      if l and from >= l.from and (not l.at or from <= l.at) then
        close = l.at
      else
        local j = i + 1
        close = false
        while true do
          j = line:find(m, j + 1, true)
          if not j then
            break
          end
          local after = line:sub(j + 1, j + 1)
          if line:sub(j - 1, j - 1):find("^%S") and (after == "" or after:find("^" .. EMPH_POST)) then
            close = j
            break
          end
        end
        last[m] = { from = from, at = close }
      end
      if close then
        out[#out + 1] = { i, close }
      end
    end
  end
end

--- Byte ranges of `line` where entities and scripts are not displayed
--- (org-raise-scripts skips emphasis, links, footnotes, tags and property
--- names): bracket and plain links, emphasis, footnote references, a
--- headline's tags, a node property's name.
local function protected_ranges(line)
  local out = {}
  -- "[[" to the next "]]", "[fn:" to the next "]": when there is no closing
  -- one, there is none for a later opening either (a pattern match went on
  -- trying from each, to the end of the line)
  local function spans(open, close)
    local init = 1
    while true do
      local s = line:find(open, init, true)
      if not s then
        return
      end
      local e = line:find(close, s + #open, true)
      if not e then
        return
      end
      e = e + #close - 1
      out[#out + 1] = { s, e }
      init = e + 1
    end
  end
  spans("[[", "]]")
  emphasis_ranges(line, out)
  -- plain links: the matches of "()(%a[%w+%-]*):[^%s%[%]<>()]+()" found
  -- from each colon back, as a gmatch would find them. The pattern itself
  -- went back over a run of letters from each of its characters, quadratic
  -- in its length: seconds for a line holding a long hash.
  local schemes = require("org.links.schemes")
  local init = 1
  while true do
    local c = line:find(":", init, true)
    if not c then
      break
    end
    local r = c
    while r > init and line:sub(r - 1, r - 1):find("^[%w+%-]") do
      r = r - 1
    end
    local a = line:sub(r, c - 1):find("%a")
    local s = a and r + a - 1
    local e = s and line:match("^[^%s%[%]<>()]+()", c + 1)
    if e then
      local scheme = line:sub(s, c - 1)
      if schemes[scheme:lower()] and (s == 1 or not line:sub(s - 1, s - 1):find("^%w")) then
        out[#out + 1] = { s, e - 1 }
      end
      init = e
    else
      init = c + 1
    end
  end
  spans("[fn:", "]")
  if line:byte(1) == 42 then
    local s = line:match("^%*+ .-%s():[^%s]+:%s*$")
    if s then
      out[#out + 1] = { s, #line }
    end
  else
    local e = line:match("^%s*:[^%s]-:()%s") or line:match("^%s*:[^%s]-:()$")
    if e then
      out[#out + 1] = { 1, e - 1 }
    end
  end
  return out
end
M._protected_ranges = protected_ranges

local function in_ranges(ranges, pos)
  for _, r in ipairs(ranges) do
    if pos >= r[1] and pos <= r[2] then
      return true
    end
  end
  return false
end

--- Headline numbering (org-num-mode): row -> text.
local function numbering(lines, ui, bufnr)
  local out = {}
  local nums
  local skip_level
  local cfg = require("org.config").opts
  local parser = require("org.parser")
  local footnote_section = cfg.footnote_section
  for i, line in ipairs(lines) do
    local level = parser.outline_level(line, bufnr)
    local p = level and parser.parse_headline_line(line)
    if level and p then
      local skip = false
      if ui.num_skip_footnotes and footnote_section and p.title == footnote_section then
        skip = true
      elseif ui.num_skip_commented and p.commented then
        skip = true
      elseif #(ui.num_skip_tags or {}) > 0 then
        for _, t in ipairs(p.tags) do
          if vim.tbl_contains(ui.num_skip_tags, t) then
            skip = true
          end
        end
      end
      if not skip and ui.num_skip_unnumbered then
        -- UNNUMBERED property in the drawer after the headline
        for j = i + 1, math.min(#lines, i + 20) do
          local l = lines[j]
          if parser.headline_level(l) or l:match("^%s*:[Ee][Nn][Dd]:") then
            break
          end
          local v = l:match("^%s*:UNNUMBERED:%s*(.-)%s*$")
          if v and v ~= "nil" then
            skip = true
          end
        end
      end
      if skip_level and level > skip_level then
        -- skipped by inheritance
      elseif skip then
        skip_level = level
      else
        skip_level = nil
        -- nums[l] is the number at level l (org-num--current-numbering)
        if not nums then
          nums = {}
          for l = 1, level - 1 do
            nums[l] = 0
          end
          nums[level] = 1
        elseif level == #nums then
          nums[level] = nums[level] + 1
        elseif level < #nums then
          for l = #nums, level + 1, -1 do
            nums[l] = nil
          end
          nums[level] = nums[level] + 1
        else
          for l = #nums + 1, level - 1 do
            nums[l] = 0
          end
          nums[level] = 1
        end
        if not ui.num_max_level or level <= ui.num_max_level then
          local text
          if type(ui.num_format_function) == "function" then
            text = ui.num_format_function(vim.deepcopy(nums))
          else
            text = table.concat(nums, ".") .. " "
          end
          if text then
            out[i - 1] = { text = text, col = level + 1, level = level }
          end
        end
      end
    end
  end
  return out
end

-- Blocks whose contents are not Org text (org-protecting-blocks, and
-- comment blocks): no entities, scripts or checkboxes are drawn in them.
local VERBATIM_BLOCKS = { src = true, example = true, export = true, comment = true }

--- For a `#+begin_` / `#+end_` line: whether a verbatim block is open after
--- it, and the language of a src block; nil for other lines. (Quote, verse,
--- center and special blocks hold ordinary Org text.)
---@return boolean? in_block, string? src_lang
function M.block_line(line)
  local kind = line:match("^%s*#%+[bB][eE][gG][iI][nN]_(%S+)")
  if kind then
    if VERBATIM_BLOCKS[kind:lower()] then
      return true, kind:lower() == "src" and line:match("^%s*#%+%S+%s*(%S*)") or nil
    end
    return false, nil
  end
  if line:match("^%s*#%+[eE][nN][dD]_") then
    return false, nil
  end
end

--- Headline level and whether a block is open at the start of row `first`
--- (0-based): the state the loop in `compute` has when it gets there. Only
--- the entry containing the row is read.
local function context_at(bufnr, first, min_inline)
  local parser = require("org.parser")
  local function outline(l)
    local lvl = l:byte(1) == 42 and parser.headline_level(l)
    return lvl and not (min_inline and lvl >= min_inline) and lvl or nil
  end
  -- the nearest outline headline above
  -- (read back in chunks that grow: it is usually near)
  local start, e, size = 0, first, 16
  while e > 0 do
    local s = math.max(0, e - size)
    local chunk = vim.api.nvim_buf_get_lines(bufnr, s, e, false)
    for i = #chunk, 1, -1 do
      if outline(chunk[i]) then
        start = s + i - 1
        e = 0
        break
      end
    end
    e = e > 0 and s or e
    size = math.min(2 * size, 256)
  end
  local level, in_block, src_lang = 0, false, nil
  for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, start, first, false)) do
    local lvl = outline(line)
    if lvl then
      level, in_block, src_lang = lvl, false, nil
    elseif not (line:byte(1) == 42 and parser.headline_level(line)) then
      local b, l = M.block_line(line)
      if b ~= nil then
        in_block, src_lang = b, l
      end
    end
  end
  return level, in_block, src_lang
end

--- Highlight groups of `ui.src_block_faces` by language (org-src-block-faces).
local src_faces_defined
local function src_face_groups(ui)
  local faces = ui.src_block_faces
  if not faces or next(faces) == nil then
    return nil
  end
  local hl = require("org.highlights")
  local groups = {}
  for lang in pairs(faces) do
    groups[lang] = hl.face_group("orgSrcBlockFace_", lang)
  end
  if src_faces_defined ~= faces then
    src_faces_defined = faces
    hl.apply_todo_faces()
  end
  return groups
end

local num_cache = {} ---@type table<integer, { tick: integer, ui: table, nums: table }>

--- Decorations of a buffer, per 0-based row: `{ [row] = { { col, opts }, ... } }`.
--- With `first` and `last` (0-based, inclusive), only rows in that range.
---@param first? integer
---@param last? integer
---@param ui? table the buffer's `ui` options (see `ui_options`)
---@return table<integer, table[]>
function M.compute(bufnr, first, last, ui)
  local rows = {}
  ui = ui or M.ui_options(bufnr)
  local n = vim.api.nvim_buf_line_count(bufnr)
  first = math.max(0, first or 0)
  last = math.min(n - 1, last or n - 1)
  ---@param persist? boolean draw as a real extmark (see `is_persistent`)
  local function set(row, col, opts, persist)
    local r = rows[row]
    if not r then
      r = {}
      rows[row] = r
    end
    r[#r + 1] = { col, opts, persist }
  end
  local min_inline = require("org.parser").inlinetask_min_level(bufnr)
  local src_faces = src_face_groups(ui)
  local boxes = type(ui.checkboxes) == "table" and ui.checkboxes or nil
  local level, in_block, src_lang = 0, false, nil
  -- (the level draws the prefixes of indent mode; whether a block is open,
  -- its checkboxes, entities and src block faces)
  if first > 0 and (ui.indent_mode or boxes or ui.pretty_entities or src_faces) then
    level, in_block, src_lang = context_at(bufnr, first, min_inline)
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, first, last + 1, false)
  local bullets = type(ui.bullets) == "table" and ui.bullets or nil
  local nums = {}
  if ui.num then
    -- numbers count every headline above: computed for the whole buffer
    local tick = vim.api.nvim_buf_get_changedtick(bufnr)
    local nc = num_cache[bufnr]
    if not nc or nc.tick ~= tick or nc.ui ~= ui then
      nc = { tick = tick, ui = ui, nums = numbering(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), ui, bufnr) }
      num_cache[bufnr] = nc
    end
    nums = nc.nums
  end
  local scripts = ui.pretty_entities
    and ui.pretty_entities_include_sub_superscripts ~= false
    and ui.use_sub_superscripts ~= false
  local braces_only = ui.use_sub_superscripts == "{}"
  for i, line in ipairs(lines) do
    local row = first + i - 1
    local stars = line:match("^(%*+) ")
    if stars and min_inline and #stars >= min_inline then
      -- inline task: only the last two stars show (org-inlinetask-fontify)
      local prefix = ui.indent_mode and M.indent_widths(ui, #stars) or 0
      local first_star = require("org.config").opts.inlinetask_show_first_star
      if prefix > 0 then
        -- org-indent--inlinetask-line-prefixes: the heading prefix, its
        -- first column a star with org-inlinetask-show-first-star
        local chunks = { { string.rep(" ", prefix), "OrgHiddenStars" } }
        if first_star then
          chunks = { { "*", "OrgInlinetaskFirstStar" }, { string.rep(" ", prefix - 1), "OrgHiddenStars" } }
        end
        set(row, 0, { virt_text = chunks, virt_text_pos = "inline", right_gravity = false })
      end
      if #stars > 2 then
        local chunks = { { string.rep(" ", #stars - 2), "OrgHiddenStars" } }
        if first_star and not (ui.indent_mode and (ui.indent_indentation_per_level or 2) > 1) then
          -- org-inlinetask-show-first-star: the first star as a marker
          chunks = { { "*", "OrgInlinetaskFirstStar" }, { string.rep(" ", #stars - 3), "OrgHiddenStars" } }
        end
        set(row, 0, { virt_text = chunks, virt_text_pos = "overlay" }, prefix > 0)
      end
      set(row, #stars - 2, { end_col = #line, hl_group = "OrgInlinetask", priority = 150 })
    elseif stars then
      level = #stars
      in_block, src_lang = false, nil
      local group = "OrgHeadlineLevel" .. (((level - 1) % 8) + 1)
      local heading_prefix = ui.indent_mode and M.indent_widths(ui, level) or 0
      if heading_prefix > 0 then
        -- org-indent: headlines get (per-level - 1) * (level - 1) columns
        -- of prefix
        set(row, 0, {
          virt_text = { { string.rep(" ", heading_prefix), "OrgHiddenStars" } },
          virt_text_pos = "inline",
          right_gravity = false,
        })
      end
      -- Overlays on the stars share column 0 with the indent-mode prefix;
      -- an ephemeral overlay there is drawn over the inline prefix instead
      -- of the stars, so they are real extmarks like the prefix.
      local persist = heading_prefix > 0
      if bullets then
        -- leading stars hidden, the last one replaced by the level's bullet
        -- (org-superstar), so the title stays at column 2n in indent mode
        local b = bullets[((level - 1) % #bullets) + 1]
        local chunks = { { b, group } }
        if level > 1 then
          table.insert(chunks, 1, { string.rep(" ", level - 1), "OrgHiddenStars" })
        end
        set(row, 0, {
          virt_text = chunks,
          virt_text_pos = "overlay",
          hl_mode = "combine",
        }, persist)
      elseif ui.hide_leading_stars then
        if level > 1 then
          set(row, 0, {
            virt_text = { { string.rep(" ", level - 1), "OrgHiddenStars" } },
            virt_text_pos = "overlay",
          }, persist)
        end
      end
      local n = nums[row]
      if n then
        set(row, n.col, {
          virt_text = { { n.text, ui.num_face or group } },
          virt_text_pos = "inline",
          right_gravity = false,
        })
      end
    else
      local b, l = M.block_line(line)
      if b ~= nil then
        in_block, src_lang = b, l
      elseif src_lang and src_faces and src_faces[src_lang] and line ~= "" then
        -- body of a src block: its language's face (org-src-block-faces)
        set(row, 0, { end_col = #line, hl_group = src_faces[src_lang], priority = 90 })
      end
      local _, text_prefix = M.indent_widths(ui, ui.indent_mode and level or 0)
      if text_prefix > 0 then
        -- org-indent: text of a level-n entry starts at column 2n (empty
        -- lines too, so the cursor sits there)
        set(row, 0, {
          virt_text = { { string.rep(" ", text_prefix), "Normal" } },
          virt_text_pos = "inline",
          right_gravity = false,
        })
      end
      if boxes and not in_block then
        -- the item's checkbox, after an optional [@N] counter, followed by
        -- a blank; "[x]" is no checkbox (org-list-full-item-re)
        local item = line:find("^%s*[-+*%w]") and require("org.lists").parse_item_line(line)
        local pre, box
        if item and item.checkbox then
          local col = item.ind_len + #item.bullet_ws
          local counter = line:match("^%[@[^%]]*%][ \t]*", col + 1) or ""
          col = col + #counter
          box = line:match("^%[[ X%-]%]", col + 1)
          pre = box and line:sub(1, col)
        end
        if box then
          local state = box:sub(2, 2)
          local icon, grp
          if state == " " then
            icon, grp = boxes[1], "OrgCheckbox"
          elseif state == "-" then
            icon, grp = boxes[2], "OrgCheckboxPartial"
          else
            icon, grp = boxes[3], "OrgCheckboxChecked"
          end
          if icon then
            local text = icon
            local w = vim.api.nvim_strwidth(text)
            if w < 3 then
              text = "[" .. text .. "]"
              if vim.api.nvim_strwidth(text) > 3 then
                text = icon .. string.rep(" ", 3 - w)
              end
            end
            set(row, #pre, { virt_text = { { text, grp } }, virt_text_pos = "overlay" })
          end
        end
      end
    end
    -- (not in keywords and comments: org-at-comment-p)
    if ui.pretty_entities and not in_block and not line:match("^%s*#[%s+]") and not line:match("^%s*#$") then
      local protected = protected_ranges(line)
      -- \name, \name{} (org-fontify-entities)
      local init = 1
      while true do
        local s, e, name = line:find("\\(%a+)", init)
        if not s then
          break
        end
        local nm = name
        local sym = require("org.entities").utf8(nm)
        if not sym then
          -- \sup1, \frac12 and the like end in digits
          local w = line:match("^\\(%a+%d%d?)", s)
          if w then
            sym = require("org.entities").utf8(w)
            if sym then
              e = s + #w
            end
          end
        end
        local after = line:sub(e + 1, e + 1)
        -- only one-character replacements are shown (org-fontify-entities
        -- skips \sin, \deg-like operators and other multi-character UTF-8)
        if sym and vim.fn.strchars(sym) == 1 and not after:match("%a") and not in_ranges(protected, s) then
          local stop = e
          if line:sub(e + 1, e + 2) == "{}" then
            stop = e + 2
          end
          set(row, s - 1, { end_col = stop, conceal = sym })
        end
        init = e + 1
      end
      if scripts then
        -- x^2, a_{i} (org-raise-scripts)
        local pos = 2
        while pos <= #line do
          local s = line:find("[_^]", pos)
          if not s then
            break
          end
          local base = line:sub(s - 1, s - 1)
          local mark = line:sub(s, s)
          local body, body_s, body_e, braces
          if line:sub(s + 1, s + 1) == "{" then
            local close = line:find("}", s + 2, true)
            if close then
              body, body_s, body_e, braces = line:sub(s + 2, close - 1), s + 2, close - 1, true
            end
          elseif not braces_only then
            local b = line:match("^%*", s + 1) or line:match("^[+-]?[%w.,\\]*%w", s + 1)
            if b then
              body, body_s, body_e = b, s + 1, s + #b
            end
          end
          if body and s > 1 and base:match("%S") and body ~= "" and not in_ranges(protected, s) then
            local map = mark == "^" and SUPER or SUB
            local all = true
            for ch in body:gmatch(".") do
              if not map[ch] then
                all = false
              end
            end
            set(row, s - 1, { end_col = s, conceal = "" })
            if braces then
              set(row, s, { end_col = s + 1, conceal = "" })
              set(row, body_e, { end_col = body_e + 1, conceal = "" })
            end
            local grp = mark == "^" and "OrgSuperscript" or "OrgSubscript"
            if all then
              for k = body_s, body_e do
                set(row, k - 1, { end_col = k, conceal = map[line:sub(k, k)] })
              end
            else
              set(row, body_s - 1, { end_col = body_e, hl_group = grp })
            end
            pos = (braces and body_e + 2 or body_e + 1)
          else
            pos = s + 1
          end
        end
      end
    end
  end
  -- the faces of the text (org.ui.highlight)
  require("org.ui.highlight").add_marks(bufnr, first, last, ui, rows)
  -- column view rows stand for the whole line (Emacs turns org-num off)
  local colview = package.loaded["org.columns"]
  for lnum in pairs(colview and colview.overlay_lines(bufnr) or {}) do
    rows[lnum - 1] = nil
  end
  return rows
end

--- org-toggle-pretty-entities (C-c C-x \): show entities (and sub- and
--- superscripts) as UTF-8 characters, or as typed, in this buffer.
function M.toggle_pretty_entities()
  local bufnr = vim.api.nvim_get_current_buf()
  local on = not M.ui_options(bufnr).pretty_entities
  vim.b[bufnr].org_pretty_entities = on
  M.attach(bufnr, true)
  require("org.utils").notify(
    on and "Entities are now displayed as UTF8 characters" or "Entities are now displayed as plain text"
  )
end

--- Run the User autocmd of a mode hook (org-indent-mode-hook,
--- org-num-mode-hook) with `data.enabled`.
local function mode_hook(pattern, bufnr, on)
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = pattern,
    data = { bufnr = bufnr, enabled = on },
    modeline = false,
  })
end

--- org-num-mode: toggle virtual headline numbering in this buffer.
function M.toggle_num_mode()
  local bufnr = vim.api.nvim_get_current_buf()
  local on = not M.ui_options(bufnr).num
  vim.b[bufnr].org_num_mode = on
  M.attach(bufnr, true)
  require("org.utils").notify(on and "Org-Num mode enabled" or "Org-Num mode disabled")
  mode_hook("OrgNumMode", bufnr, on)
end

--- org-indent-mode: toggle virtual indentation in this buffer.
function M.toggle_indent_mode()
  local bufnr = vim.api.nvim_get_current_buf()
  local on = not M.ui_options(bufnr).indent_mode
  vim.b[bufnr].org_indent_mode = on
  M.attach(bufnr, true)
  require("org.utils").notify(on and "Org-Indent mode enabled" or "Org-Indent mode disabled")
  mode_hook("OrgIndentMode", bufnr, on)
end

-- Decorations are drawn by a decoration provider from the buffer text at
-- redraw time, so they can never lag behind an edit. (Persistent extmarks
-- updated after a debounce were dragged to wrong rows/columns by line
-- replacements and showed up in odd places until the next render.)
-- Results are cached per changedtick.
local attached = {} ---@type table<integer, boolean>
---@class org.ui.decorations.Cache
---@field tick integer
---@field ui table
---@field rows table<integer, table[]>
---@field done table<integer, boolean>
---@field text table<integer, string> the text of the rows done
---@field lo table<integer, integer> per row done, the first row its marks depend on
---@field hi table<integer, integer> and the last
---@field wlo table<integer, integer> per row done, the first row its computation read
---@field whi table<integer, integer> and the last
---@field spans table<integer, boolean> per row done, whether its computation read the start of a macro or a footnote reference
---@field ndone integer how many rows are done
---@field reach { [1]: integer, [2]: integer } how far above and below its row the first and last rows a row done depends on are, at most
---@field wreach { [1]: integer, [2]: integer } likewise for the rows its computation read
---@field file? org.File|false the parse org.ui.highlight drew with (false: more than one)
---@field bvars string the buffer variables the drawing follows
---@field before? org.ui.decorations.Before what the rows drew before the edits since the last tick drawn
local cache = {} ---@type table<integer, org.ui.decorations.Cache>

--- The `ui` options the provider draws with. Reading `#+STARTUP` needs a
--- parse of the buffer, too slow for every redraw of a large file: they
--- are refreshed by `render` (attach, toggles, C-c C-c on a keyword), when
--- the configuration changes and whenever a parse of the current text is
--- cached anyway.
local ui_cache = {} ---@type table<integer, { ui: table, cfg: table, file: org.File? }>

local function provider_ui(bufnr)
  local cfg = require("org.config").opts.ui
  local c = ui_cache[bufnr]
  local file = require("org.files").cached_buffer(bufnr)
  if not c or c.cfg ~= cfg or (file and file ~= c.file) then
    local ok, ui = pcall(M.ui_options, bufnr, file)
    c = { ui = ok and ui or vim.deepcopy(cfg), cfg = cfg, file = file or require("org.files").cached_buffer(bufnr) }
    ui_cache[bufnr] = c
  end
  return c.ui
end

-- Typing keeps the decorations of the rows it can't change. After an edit
-- inside one line, the rows whose marks depend on that line (org.ui.highlight
-- `last_reads`: those a scan of the row alone reads, the paragraphs around
-- it and the lines that bound them; all the rows the scan of the rows
-- computed together read, `last_read`, when the line holds what draws rows
-- together; and every row below a line that holds, or held, the start of
-- a macro or a footnote reference, or a bracket or quote when its scan read
-- such a start: one opened or closed there runs on over rows whose scan
-- didn't read the line) are computed again and the others keep theirs,
-- when the line before and after the edit holds nothing the scans read
-- from further away: no line of stars (levels, where blocks end) but a
-- headline that keeps its stars and the blank after them, no `#` line
-- (block delimiters, keywords), no backslash (LaTeX environments) and the
-- same paragraph separation; and the rest is as it
-- was: the same `ui` options, buffer variables and parse (in-buffer
-- settings, radio targets), no numbering (it counts every headline above)
-- and no column view. Anything else computes the rows again.

-- (the rows whose inline marks are placed, see `sync_inline` below)
local inline_synced = {} ---@type table<integer, { tick: integer, ui: table, rows: table<integer, boolean> }>

--- (how many times rows were kept over an edit, and how many rows done
--- were looked at to keep them, for the specs)
M._carried = 0
M._carried_rows = 0
---@class org.ui.decorations.Edits
---@field since integer the changedtick of the cache the edits follow
---@field tick integer the changedtick after the last of them
---@field rows table<integer, boolean>|false the rows edited, false when an edit added or removed lines
---@field first? integer the first row an edit changed
---@field last? integer the last row an edit changed (or the row before `first`: lines removed)
---@field shift integer the lines added (less those removed)
local edits = {} ---@type table<integer, org.ui.decorations.Edits>
local tracked = {} ---@type table<integer, boolean>

local function on_bytes(_, bufnr, tick, start_row, start_col, _, old_rows, old_col, _, new_rows, new_col)
  if not attached[bufnr] then
    tracked[bufnr] = nil
    edits[bufnr] = nil
    return true
  end
  local e = edits[bufnr]
  if e then
    if e.rows and old_rows == 0 and new_rows == 0 then
      e.rows[start_row] = true
    else
      e.rows = false
    end
    -- (the rows after the edit move by the lines it added; the row the
    -- edit ends on is one of them when it only moved, whole lines added
    -- or removed before it: Neovim scrolls it in the other windows on the
    -- buffer, it doesn't draw it again)
    local last = start_row + new_rows
    if new_col == 0 and old_col == 0 and (start_col == 0 or (new_rows > 0 and old_rows > 0)) then
      last = last - 1
    end
    if e.last and e.last >= start_row then
      e.last = e.last + new_rows - old_rows
    end
    e.first = math.min(e.first or start_row, start_row)
    e.last = math.max(e.last or last, last)
    e.shift = e.shift + new_rows - old_rows
    -- (the changedtick before the edit: the edit makes it tick + 1)
    e.tick = tick + 1
  end
end

-- (a reload replaces every line without on_bytes: nothing is kept over it)
local function on_reload(_, bufnr)
  local e = edits[bufnr]
  if e then
    e.rows = false
  end
end

-- (`:edit!` and unloading the buffer stop the listener: `attach` starts it
-- again when the buffer is set up anew)
local function on_detach(_, bufnr)
  tracked[bufnr] = nil
  edits[bufnr] = nil
end

--- The buffer variables the decorations follow (org.ui.highlight `add_marks`).
local function bvars(bufnr)
  local b = vim.b[bufnr]
  return tostring(b.org_hide_emphasis_markers) .. tostring(b.org_link_descriptive)
end

--- Whether an edit that turned line `old` into `new` changes only the
--- rows whose scan reads it (see above).
local function local_edit(old, new)
  -- (a headline that keeps its stars and the blank after them: the rows
  -- after it read only its level and that it is one)
  local stars = old:match("^%*+[ \t]")
  if stars and (stars ~= new:match("^%*+[ \t]") or old:find("^%*+[ \t]*$") or new:find("^%*+[ \t]*$")) then
    return false
  end
  for _, l in ipairs({ old, new }) do
    if (not stars and l:byte(1) == 42) or l:find("^%s*#") or l:find("\\", 1, true) then
      return false
    end
  end
  local sep = require("org.ui.emphasis").separates
  return sep(old) == sep(new)
end

--- `c` brought to changedtick `tick`, its rows an edit may have changed
--- dropped (see above), or nil when it can't be.
---@param c org.ui.decorations.Cache
---@return org.ui.decorations.Cache?
local function carried(bufnr, c, tick, ui)
  local e = edits[bufnr]
  if not (e and e.rows and e.since == c.tick and e.tick == tick and next(e.rows)) or c.ui ~= ui or ui.num then
    return nil
  end
  local colview = package.loaded["org.columns"]
  if colview and next(colview.overlay_lines(bufnr) or {}) then
    return nil
  end
  local hl = package.loaded["org.ui.highlight"]
  if c.file == false or (hl and c.file and hl.file_in_use(bufnr) ~= c.file) or c.bvars ~= bvars(bufnr) then
    return nil
  end
  -- (whether an edited line holds what draws rows together, and whether
  -- the scan of the lines after it reads it differently)
  -- (and the first row from which on every row is dropped: a macro or a
  -- footnote reference opened, or closed, there can run on over any row
  -- below, whatever it read)
  local together, above = false, false
  local below = math.huge
  local E = package.loaded["org.ui.emphasis"]
  for row in pairs(e.rows) do
    local old = c.text[row]
    local new = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
    if not (old and new and local_edit(old, new)) then
      return nil
    end
    local spans = hl ~= nil and (hl.spans_paragraphs(old) or hl.spans_paragraphs(new))
    together = together or spans
    if spans or (c.spans[row] and (old:find('[][(){}<>"]') or new:find('[][(){}<>"]'))) then
      below = math.min(below, row)
    end
    above = above or E ~= nil and E.line_above(old) ~= E.line_above(new)
  end
  local lo, hi = together and c.wlo or c.lo, together and c.whi or c.hi
  local up = above and 1 or 0
  -- (the inline marks of the rows kept stay where they are)
  local synced = inline_synced[bufnr] ---@type { tick: integer, ui: table, rows: table<integer, boolean> }?
  if synced and not (synced.tick == c.tick and synced.ui == ui) then
    synced = nil
  end
  -- (what the rows dropped drew, see `redraw_changed`)
  local before = { rows = {}, done = {}, edits = e } ---@type org.ui.decorations.Before
  local function drop(row)
    M._carried_rows = M._carried_rows + 1
    for edited in pairs(e.rows) do
      if row >= below or (lo[row] - up <= edited and edited <= hi[row]) then
        before.rows[row], before.done[row] = c.rows[row], true
        c.rows[row], c.done[row], c.text[row] = nil, nil, nil
        c.lo[row], c.hi[row], c.wlo[row], c.whi[row], c.spans[row] = nil, nil, nil, nil, nil
        c.ndone = c.ndone - 1
        if synced then
          synced.rows[row] = nil
        end
        return
      end
    end
  end
  -- (only the rows whose reads can reach an edited row, unless every row
  -- below one is dropped: the rows done grow with every screen drawn since
  -- the cache was made, all the rows of the file once scrolled through)
  local reach = together and c.wreach or c.reach
  local min, max = math.huge, -1
  for edited in pairs(e.rows) do
    min, max = math.min(min, edited), math.max(max, edited)
  end
  local from, to = min - reach[2], max + reach[1] + up
  if below == math.huge and to - from <= 4 * c.ndone then
    for row = from, to do
      if c.done[row] then
        drop(row)
      end
    end
  else
    for row in pairs(c.done) do
      drop(row)
    end
  end
  if synced then
    synced.tick = tick
  end
  c.tick = tick
  c.before = before
  M._carried = M._carried + 1
  return c
end

-- Neovim redraws the lines an edit changed (and scrolls those below when it
-- added or removed lines), but the marks of a row can change with the text
-- of another: markup over two lines, a link over the lines of a paragraph,
-- the end line of a block. So the rows drawn again after an edit are
-- compared with what they drew before it, and those whose marks changed
-- and that Neovim doesn't redraw are redrawn too.

---@class org.ui.decorations.Before
---@field rows table<integer, table[]> the marks of the rows before the edits, by their rows before them
---@field done table<integer, boolean>
---@field edits? org.ui.decorations.Edits nil: not known

--- What the rows of `c` drew before the edits since (see above), for
--- a cache of the edited text made anew.
---@param c org.ui.decorations.Cache
---@return org.ui.decorations.Before
local function before_edits(bufnr, c)
  local e = edits[bufnr]
  return { rows = c.rows, done = c.done, edits = e and e.since == c.tick and e or nil }
end

--- Whether two lists of marks (`compute`) draw the same.
local function same_marks(a, b)
  if a == b then
    return true
  end
  a, b = a or {}, b or {}
  if #a ~= #b then
    return false
  end
  for k = 1, #a do
    local x, y = a[k], b[k]
    if x[1] ~= y[1] or x[3] ~= y[3] or x[4] ~= y[4] then
      return false
    end
    local ox, oy = x[2], y[2]
    for key, v in pairs(ox) do
      local w = oy[key]
      if v ~= w and not (type(v) == "table" and type(w) == "table" and vim.deep_equal(v, w)) then
        return false
      end
    end
    for key in pairs(oy) do
      if ox[key] == nil then
        return false
      end
    end
  end
  return true
end

--- Redraw the rows of [s, e] (computed again at `c.tick`) whose marks
--- changed with an edit of other rows (see above).
---@param c org.ui.decorations.Cache
local function redraw_changed(bufnr, c, s, e)
  local before = c.before ---@type org.ui.decorations.Before
  local ed = before.edits
  local lo, hi ---@type integer?, integer?
  for row = s, e do
    -- (the row it was before the edits, nil when Neovim redraws it anyway:
    -- the rows edited; it scrolls those below the lines added or removed)
    local old ---@type integer?
    if not ed then
      old = row
    elseif ed.rows then
      old = not ed.rows[row] and row or nil
    elseif ed.first and row < ed.first then
      old = row
    elseif ed.last and row > ed.last then
      old = row - ed.shift
    end
    if old and before.done[old] and not same_marks(before.rows[old], c.rows[row]) then
      lo, hi = lo or row, row
    end
  end
  if lo then
    pcall(vim.api.nvim__redraw, { buf = bufnr, range = { lo, hi + 1 } })
  end
end

--- Decorations of rows [top, bot] at the current changedtick, computed
--- once per tick for the rows windows actually draw.
local function rows_for(bufnr, top, bot)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local ui = provider_ui(bufnr)
  local c = cache[bufnr]
  -- (`b:org_hide_emphasis_markers` and the like set since: drawn anew, on
  -- the next redraw of the window)
  if not c or c.tick ~= tick or c.ui ~= ui or c.bvars ~= bvars(bufnr) then
    local old = c
    local kept = old and old.tick ~= tick and carried(bufnr, old, tick, ui)
    c = kept
      or {
        tick = tick,
        ui = ui,
        rows = {},
        done = {},
        text = {},
        lo = {},
        hi = {},
        wlo = {},
        whi = {},
        spans = {},
        ndone = 0,
        reach = { 0, 0 },
        wreach = { 0, 0 },
        bvars = bvars(bufnr),
        before = old and before_edits(bufnr, old) or nil,
      }
    cache[bufnr] = c
    if tracked[bufnr] then
      edits[bufnr] = { since = tick, tick = tick, rows = {}, shift = 0 }
    end
  end
  local s = top
  while s <= bot and c.done[s] do
    s = s + 1
  end
  local e = bot
  while e >= s and c.done[e] do
    e = e - 1
  end
  if s <= e then
    local hl = package.loaded["org.ui.highlight"]
    if hl then
      hl.last_read, hl.last_reads, hl.last_spans = nil, nil, false
    end
    for row, marks in pairs(M.compute(bufnr, s, e, ui)) do
      c.rows[row] = marks
    end
    -- (`compute` loads org.ui.highlight the first time: what it read is
    -- known from then on, the rows of the first buffer drawn too)
    hl = hl or package.loaded["org.ui.highlight"]
    if c.before then
      redraw_changed(bufnr, c, s, e)
    end
    -- (the rows the computation read: the rows themselves, or the window
    -- org.ui.highlight scanned for them; and those each row depends on)
    local read = hl and hl.last_read
    local reads = read and hl.last_reads
    local spans = hl and hl.last_spans or false
    for k, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, s, e + 1, false)) do
      local row = s + k - 1
      if not c.done[row] then
        c.ndone = c.ndone + 1
      end
      c.done[row], c.text[row] = true, line
      local wlo, whi = read and read[1] or row, read and read[2] or row
      local rlo, rhi = reads and reads.lo[row] or wlo, reads and reads.hi[row] or whi
      c.wlo[row], c.whi[row], c.spans[row] = wlo, whi, spans
      c.lo[row], c.hi[row] = rlo, rhi
      local reach, wreach = c.reach, c.wreach
      reach[1], reach[2] = math.max(reach[1], row - rlo), math.max(reach[2], rhi - row)
      wreach[1], wreach[2] = math.max(wreach[1], row - wlo), math.max(wreach[2], whi - row)
    end
    local file = hl and hl.file_in_use(bufnr) or nil
    if c.file == nil then
      c.file = file
    elseif c.file ~= file then
      c.file = false
    end
  end
  return c.rows
end

-- Inline virtual text (indent mode) can't be ephemeral, so those marks are
-- real extmarks in their own namespace, rebuilt for the rows a window is
-- about to draw whenever the text changed.
local ns_inline = vim.api.nvim_create_namespace("org.decorations.inline")

--- Marks drawn as real extmarks instead of ephemeral ones: inline virtual
--- text (which can't be ephemeral) and overlays that must be placed after
--- an inline mark at the same column.
local function is_persistent(m)
  return m[3] or m[2].virt_text_pos == "inline"
end

local function sync_inline(bufnr, rows, top, bot)
  local tick, ui = cache[bufnr].tick, cache[bufnr].ui
  local synced = inline_synced[bufnr]
  if not synced or synced.tick ~= tick or synced.ui ~= ui then
    if synced and synced.ui ~= ui then
      -- (indent mode turned off without an edit: no row may keep its prefix)
      vim.api.nvim_buf_clear_namespace(bufnr, ns_inline, 0, -1)
    end
    synced = { tick = tick, ui = ui, rows = {} }
    inline_synced[bufnr] = synced
  end
  local row = top
  while row <= bot do
    if synced.rows[row] then
      row = row + 1
    else
      local e = row
      while e + 1 <= bot and not synced.rows[e + 1] do
        e = e + 1
      end
      vim.api.nvim_buf_clear_namespace(bufnr, ns_inline, row, e + 1)
      for r = row, e do
        synced.rows[r] = true
        for _, m in ipairs(rows[r] or {}) do
          if is_persistent(m) then
            pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_inline, r, m[1], m[2])
          end
        end
      end
      row = e + 1
    end
  end
end

--- The row ranges of [top, bot] a window draws: of a closed fold only its
--- first row.
local function drawn_ranges(win, top, bot)
  local out = {}
  local ok = pcall(vim.api.nvim_win_call, win, function()
    local row = top
    local s = top
    while row <= bot do
      local fend = vim.fn.foldclosedend(row + 1)
      if fend ~= -1 then
        out[#out + 1] = { s, row }
        row = fend
        s = row
      else
        row = row + 1
      end
    end
    if s <= bot then
      out[#out + 1] = { s, bot }
    end
  end)
  return ok and out or { { top, bot } }
end

--- Spell checking outside a redraw (`]s`, `[s`, `z=`, spellbadword()):
--- the `spell` of the marks of rows [srow, erow], as ephemeral marks that
--- Neovim reads for the words it looks at. (Drawing reads them from
--- on_line; without this, `]s` would stop on the words the screen doesn't
--- mark, in verbatim, links, tags, ...)
local function spell_nav(bufnr, srow, erow)
  local last = vim.api.nvim_buf_line_count(bufnr) - 1
  erow = math.min(math.max(erow or srow, srow), last)
  if srow > erow then
    return
  end
  local rows = rows_for(bufnr, srow, erow)
  for row = srow, erow do
    for _, m in ipairs(rows[row] or {}) do
      local o = m[2]
      if o.spell ~= nil and not is_persistent(m) then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, m[1], {
          end_col = o.end_col,
          end_row = o.end_row,
          spell = o.spell,
          priority = o.priority,
          ephemeral = true,
        })
      end
    end
  end
end

--- Compute the rows from `row` on (a screenful at most), drawn past the
--- rows on_win computed; their inline marks (real extmarks, which can't be
--- placed while the screen is drawn) are placed right after the redraw.
local function late_rows(bufnr, row)
  local last = math.min(row + 60, vim.api.nvim_buf_line_count(bufnr) - 1)
  if last < row then
    return
  end
  local rows = rows_for(bufnr, row, last)
  for r = row, last do
    for _, m in ipairs(rows[r] or {}) do
      if is_persistent(m) then
        vim.schedule(function()
          if attached[bufnr] and vim.api.nvim_buf_is_valid(bufnr) then
            last = math.min(last, vim.api.nvim_buf_line_count(bufnr) - 1)
            sync_inline(bufnr, rows_for(bufnr, row, last), row, last)
          end
        end)
        return
      end
    end
  end
end

--- The rows of `bufnr` window `win` draws, [toprow, botrow], computed for
--- on_line.
local function draw_win(win, bufnr, toprow, botrow)
  -- (`botrow` is the last row of the last redraw: the virtual indentation
  -- placed below can make the lines take fewer screen rows, no less than
  -- a row each; the rows past it are computed by on_line, but their
  -- indentation would come a redraw late)
  if vim.wo[win].wrap and provider_ui(bufnr).indent_mode then
    botrow = math.max(botrow, toprow + vim.api.nvim_win_get_height(win) - 1)
  end
  botrow = math.min(botrow, vim.api.nvim_buf_line_count(bufnr) - 1)
  local ranges = (vim.wo[win].foldenable and botrow - toprow > 0) and drawn_ranges(win, toprow, botrow)
    or { { toprow, botrow } }
  for _, r in ipairs(ranges) do
    sync_inline(bufnr, rows_for(bufnr, r[1], r[2]), r[1], r[2])
  end
end

-- An error raised in a decoration provider is reported by Neovim on every
-- redraw, at every keystroke: the callbacks catch it, draw nothing for that
-- window and report each error once.
local reported = {} ---@type table<string, boolean>
local function failed(err)
  err = tostring(err)
  if reported[err] then
    return
  end
  reported[err] = true
  vim.schedule(function()
    require("org.utils").notify("org.nvim: drawing the buffer failed: " .. err, vim.log.levels.ERROR)
  end)
end

local function on_spell_nav(_, _, bufnr, srow, _, erow)
  if not attached[bufnr] then
    return
  end
  local ok, err = pcall(spell_nav, bufnr, srow, erow)
  if not ok then
    failed(err)
  end
end

local provider = {
  on_win = function(_, win, bufnr, toprow, botrow)
    if not attached[bufnr] then
      return false
    end
    local ok, err = pcall(draw_win, win, bufnr, toprow, botrow)
    if not ok then
      failed(err)
      return false
    end
    -- (on_line computes the rows past `botrow`: on_line is needed even
    -- when the rows on_win was told of draw nothing)
    return true
  end,
  on_line = function(_, _, bufnr, row)
    local c = cache[bufnr]
    if not (c and c.done[row]) then
      -- a row past the last one on_win was told of: Neovim guesses it from
      -- the last redraw, and draws more rows when an edit or a fold made the
      -- lines take fewer screen rows
      local ok, err = pcall(late_rows, bufnr, row)
      if not ok then
        failed(err)
        return
      end
      c = cache[bufnr]
    end
    local marks = c and c.rows[row]
    if not marks then
      return
    end
    for _, m in ipairs(marks) do
      if not is_persistent(m) then
        -- (org.ui.emphasis makes its marks ephemeral: no copy per redraw)
        local opts = m[2].ephemeral and m[2] or vim.tbl_extend("force", m[2], { ephemeral = true })
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, m[1], opts)
      end
    end
  end,
  -- (not in the documented API, but what vim.treesitter's highlighter
  -- uses for the same purpose)
  _on_spell_nav = on_spell_nav,
}
if not pcall(vim.api.nvim_set_decoration_provider, ns, provider) then
  provider._on_spell_nav = nil
  vim.api.nvim_set_decoration_provider(ns, provider)
end

--- The decorations drawn on 0-based `row` of `bufnr`, as `{ col, opts }`
--- pairs for `nvim_buf_set_extmark` (the sticky headline context copies
--- them), from the per-changedtick cache, each with what drew it third
--- ("parser", "emphasis": the parser highlighter). Empty when the buffer
--- draws none.
---@param bufnr integer
---@param row integer
---@return { [1]: integer, [2]: vim.api.keyset.set_extmark, [3]: string? }[]
function M.line_marks(bufnr, row)
  if not attached[bufnr] then
    return {}
  end
  local out = {}
  for _, m in ipairs(rows_for(bufnr, row, row)[row] or {}) do
    local o = m[2]
    if o.ephemeral then
      -- (callers set these marks for good)
      o = vim.tbl_extend("force", {}, o)
      o.ephemeral = nil
    end
    out[#out + 1] = { m[1], o, m[4] }
  end
  return out
end

--- What the parser highlighter (org.ui.emphasis) hides at byte `col`
--- (0-based) of row `row`: "" for a concealed emphasis marker or link
--- bracket, nil when it hides nothing there. (Syntax concealing is
--- `synconcealed()`; the entities shown as UTF-8 aren't hidden text.)
---@param bufnr integer
---@param row integer
---@param col integer
---@return string?
function M.concealed(bufnr, row, col)
  if not attached[bufnr] then
    return nil
  end
  for _, m in ipairs(rows_for(bufnr, row, row)[row] or {}) do
    local o = m[2]
    if (m[4] == "emphasis" or m[4] == "parser") and o.conceal and col >= m[1] and col < (o.end_col or m[1] + 1) then
      return o.conceal
    end
  end
  return nil
end

--- Recompute on the next redraw (e.g. after `ui` options changed), and
--- redraw now unless `later`.
---@param later? boolean
function M.render(bufnr, later)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  cache[bufnr] = nil
  edits[bufnr] = nil
  ui_cache[bufnr] = nil
  num_cache[bufnr] = nil
  inline_synced[bufnr] = nil
  vim.api.nvim_buf_clear_namespace(bufnr, ns_inline, 0, -1)
  pcall(vim.api.nvim__redraw, { buf = bufnr, valid = false, flush = not later })
end

--- Indent mode wraps lines with 'breakindent', set for the buffer in the
--- windows that show it (not globally: other buffers keep theirs; nor in a
--- buffer that only sets 'syntax' to org, like the drill window).
local function set_win_opts(bufnr, win)
  if vim.api.nvim_win_get_buf(win) == bufnr and vim.bo[bufnr].filetype == "org" and M.ui_options(bufnr).indent_mode then
    vim.wo[win][0].breakindent = true
    vim.wo[win][0].wrap = true
  end
end

--- Stop drawing the decorations of `bufnr` (its filetype changed).
function M.detach(bufnr)
  attached[bufnr] = nil
  -- (the BufWipeout autocmd that forgets the rest goes with the group)
  pcall(vim.api.nvim_del_augroup_by_name, "org.decorations." .. bufnr)
  local hl = package.loaded["org.ui.highlight"]
  if hl then
    hl.detach(bufnr)
  end
  M.render(bufnr)
end

---@param force? boolean attached by a toggle (the modes the buffer starts
--- with don't run their hooks)
function M.attach(bufnr, force)
  local ui = M.ui_options(bufnr)
  if ui.indent_mode then
    for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
      set_win_opts(bufnr, win)
    end
  end
  if not attached[bufnr] and not force and vim.bo[bufnr].filetype == "org" then
    -- the modes turned on when the buffer is set up (org-startup-indented,
    -- org-startup-numerated) run their hooks (in org buffers only: not in
    -- one that only sets 'syntax' to org)
    if ui.indent_mode then
      mode_hook("OrgIndentMode", bufnr, true)
    end
    if ui.num then
      mode_hook("OrgNumMode", bufnr, true)
    end
  end
  local first = not attached[bufnr]
  attached[bufnr] = true
  if not tracked[bufnr] then
    tracked[bufnr] = vim.api.nvim_buf_attach(bufnr, false, {
      on_bytes = on_bytes,
      on_reload = on_reload,
      on_detach = on_detach,
    }) or nil
  end
  local group = vim.api.nvim_create_augroup("org.decorations." .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    buffer = bufnr,
    callback = function()
      set_win_opts(bufnr, vim.api.nvim_get_current_win())
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = bufnr,
    callback = function()
      attached[bufnr] = nil
      cache[bufnr] = nil
      edits[bufnr], tracked[bufnr] = nil, nil
      ui_cache[bufnr] = nil
      num_cache[bufnr] = nil
      inline_synced[bufnr] = nil
      local hl = package.loaded["org.ui.highlight"]
      if hl then
        hl.detach(bufnr)
      end
    end,
  })
  -- (a buffer attached as it is opened is drawn when the opening is done:
  -- drawing it now, before the rest of its setup, would draw it twice)
  M.render(bufnr, first)
end

function M.refresh(bufnr)
  if not attached[bufnr] and vim.api.nvim_buf_is_valid(bufnr) and vim.b[bufnr].org_attached then
    -- (an org buffer not drawn yet)
    M.attach(bufnr)
    return
  end
  M.render(bufnr)
end

return M
