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
  ["0"] = "⁰", ["1"] = "¹", ["2"] = "²", ["3"] = "³", ["4"] = "⁴", ["5"] = "⁵", ["6"] = "⁶", ["7"] = "⁷",
  ["8"] = "⁸", ["9"] = "⁹", ["+"] = "⁺", ["-"] = "⁻", ["="] = "⁼", ["("] = "⁽", [")"] = "⁾", a = "ᵃ",
  b = "ᵇ", c = "ᶜ", d = "ᵈ", e = "ᵉ", f = "ᶠ", g = "ᵍ", h = "ʰ", i = "ⁱ", j = "ʲ", k = "ᵏ", l = "ˡ",
  m = "ᵐ", n = "ⁿ", o = "ᵒ", p = "ᵖ", r = "ʳ", s = "ˢ", t = "ᵗ", u = "ᵘ", v = "ᵛ", w = "ʷ", x = "ˣ",
  y = "ʸ", z = "ᶻ", A = "ᴬ", B = "ᴮ", D = "ᴰ", E = "ᴱ", G = "ᴳ", H = "ᴴ", I = "ᴵ", J = "ᴶ", K = "ᴷ",
  L = "ᴸ", M = "ᴹ", N = "ᴺ", O = "ᴼ", P = "ᴾ", R = "ᴿ", T = "ᵀ", U = "ᵁ", V = "ⱽ", W = "ᵂ",
}
local SUB = {
  ["0"] = "₀", ["1"] = "₁", ["2"] = "₂", ["3"] = "₃", ["4"] = "₄", ["5"] = "₅", ["6"] = "₆", ["7"] = "₇",
  ["8"] = "₈", ["9"] = "₉", ["+"] = "₊", ["-"] = "₋", ["="] = "₌", ["("] = "₍", [")"] = "₎", a = "ₐ",
  e = "ₑ", h = "ₕ", i = "ᵢ", j = "ⱼ", k = "ₖ", l = "ₗ", m = "ₘ", n = "ₙ", o = "ₒ", p = "ₚ", r = "ᵣ",
  s = "ₛ", t = "ₜ", u = "ᵤ", v = "ᵥ", x = "ₓ",
}

--- The `ui` options of a buffer: `#+STARTUP` words and the buffer toggles
--- override the configuration.
---@param file? org.File the parsed buffer, when the caller has it
function M.ui_options(bufnr, file)
  local ui = vim.deepcopy(require("org.config").opts.ui)
  local ok = file ~= nil
  if not ok then
    ok, file = pcall(require("org.files").get_buffer, bufnr)
  end
  local st = ok and file.settings.startup or {}
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

local function enabled(ui)
  return ui.bullets
    or ui.hide_leading_stars
    or ui.checkboxes
    or ui.indent_mode
    or ui.pretty_entities
    or ui.num
    or next(ui.src_block_faces or {}) ~= nil
    or require("org.parser").inlinetask_min_level() ~= nil
end

--- Byte ranges of inline code, verbatim and links in `line`, where
--- entities and scripts are not displayed.
local function protected_ranges(line)
  local out = {}
  for s, e in line:gmatch("()%[%[.-%]%]()") do
    out[#out + 1] = { s, e - 1 }
  end
  for s, e in line:gmatch("()[=~][^%s=~][^\n]-[=~]()") do
    out[#out + 1] = { s, e - 1 }
  end
  for s, e in line:gmatch("()%a+://%S+()") do
    out[#out + 1] = { s, e - 1 }
  end
  return out
end

local function in_ranges(ranges, pos)
  for _, r in ipairs(ranges) do
    if pos >= r[1] and pos <= r[2] then
      return true
    end
  end
  return false
end

--- Headline numbering (org-num-mode): row -> text.
local function numbering(lines, ui)
  local out = {}
  local nums
  local skip_level
  local cfg = require("org.config").opts
  local parser = require("org.parser")
  local footnote_section = cfg.footnote_section
  for i, line in ipairs(lines) do
    local level = parser.outline_level(line)
    if level then
      local p = parser.parse_headline_line(line)
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
  local start, e = 0, first
  while e > 0 do
    local s = math.max(0, e - 256)
    local chunk = vim.api.nvim_buf_get_lines(bufnr, s, e, false)
    for i = #chunk, 1, -1 do
      if outline(chunk[i]) then
        start = s + i - 1
        e = 0
        break
      end
    end
    e = e > 0 and s or e
  end
  local level, in_block, src_lang = 0, false, nil
  for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, start, first, false)) do
    local lvl = outline(line)
    if lvl then
      level, in_block, src_lang = lvl, false, nil
    elseif not (line:byte(1) == 42 and parser.headline_level(line)) then
      if line:match("^%s*#%+[bB][eE][gG][iI][nN]_") then
        in_block = true
        src_lang = line:match("^%s*#%+[bB][eE][gG][iI][nN]_[sS][rR][cC]%s*(%S*)")
      elseif line:match("^%s*#%+[eE][nN][dD]_") then
        in_block, src_lang = false, nil
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

local num_cache = {} ---@type table<integer, { tick: integer, nums: table }>

--- Decorations of a buffer, per 0-based row: `{ [row] = { { col, opts }, ... } }`.
--- With `first` and `last` (0-based, inclusive), only rows in that range.
---@param first? integer
---@param last? integer
---@param ui? table the buffer's `ui` options (see `ui_options`)
---@return table<integer, table[]>
function M.compute(bufnr, first, last, ui)
  local rows = {}
  ui = ui or M.ui_options(bufnr)
  if not enabled(ui) then
    return rows
  end
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
  local min_inline = require("org.parser").inlinetask_min_level()
  local level, in_block, src_lang = 0, false, nil
  if first > 0 then
    level, in_block, src_lang = context_at(bufnr, first, min_inline)
  end
  local src_faces = src_face_groups(ui)
  local lines = vim.api.nvim_buf_get_lines(bufnr, first, last + 1, false)
  local bullets = type(ui.bullets) == "table" and ui.bullets or nil
  local boxes = type(ui.checkboxes) == "table" and ui.checkboxes or nil
  local nums = {}
  if ui.num then
    -- numbers count every headline above: computed for the whole buffer
    local tick = vim.api.nvim_buf_get_changedtick(bufnr)
    local nc = num_cache[bufnr]
    if not nc or nc.tick ~= tick or nc.ui ~= ui then
      nc = { tick = tick, ui = ui, nums = numbering(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), ui) }
      num_cache[bufnr] = nc
    end
    nums = nc.nums
  end
  local scripts = ui.pretty_entities and ui.pretty_entities_include_sub_superscripts ~= false
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
      if line:match("^%s*#%+[bB][eE][gG][iI][nN]_") then
        in_block = true
        src_lang = line:match("^%s*#%+[bB][eE][gG][iI][nN]_[sS][rR][cC]%s*(%S*)")
      elseif line:match("^%s*#%+[eE][nN][dD]_") then
        in_block, src_lang = false, nil
      elseif src_lang and src_faces and src_faces[src_lang] and line ~= "" then
        -- body of a src block: its language's face (org-src-block-faces)
        set(row, 0, { end_col = #line, hl_group = src_faces[src_lang], priority = 90 })
      end
      local _, text_prefix = M.indent_widths(ui, ui.indent_mode and level or 0)
      if text_prefix > 0 and line ~= "" then
        -- org-indent: text of a level-n entry starts at column 2n
        set(row, 0, {
          virt_text = { { string.rep(" ", text_prefix), "Normal" } },
          virt_text_pos = "inline",
          right_gravity = false,
        })
      end
      if boxes and not in_block then
        local pre, box = line:match("^(%s*[-+*]%s+)(%[[ xX%-]%])")
        if not pre then
          pre, box = line:match("^(%s*%d+[.)]%s+)(%[[ xX%-]%])")
        end
        if not pre and line:match("^%s*%a[.)]") and require("org.lists").opt("allow_alphabetical") then
          pre, box = line:match("^(%s*%a[.)]%s+)(%[[ xX%-]%])")
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
    if ui.pretty_entities and not in_block and not line:match("^%s*#%+") then
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
  require("org.utils").notify(on and "Entities are now displayed as UTF8 characters" or "Entities are now displayed as plain text")
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
local cache = {} ---@type table<integer, { tick: integer, rows: table<integer, table[]> }>

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

--- Decorations of rows [top, bot] at the current changedtick, computed
--- once per tick for the rows windows actually draw.
local function rows_for(bufnr, top, bot)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local ui = provider_ui(bufnr)
  local c = cache[bufnr]
  if not c or c.tick ~= tick or c.ui ~= ui then
    c = { tick = tick, ui = ui, rows = {}, done = {} }
    cache[bufnr] = c
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
    for row, marks in pairs(M.compute(bufnr, s, e, ui)) do
      c.rows[row] = marks
    end
    for row = s, e do
      c.done[row] = true
    end
  end
  return c.rows
end

local current ---@type table<integer, table[]>?

-- Inline virtual text (indent mode) can't be ephemeral, so those marks are
-- real extmarks in their own namespace, rebuilt for the rows a window is
-- about to draw whenever the text changed.
local ns_inline = vim.api.nvim_create_namespace("org.decorations.inline")
local inline_synced = {} ---@type table<integer, { tick: integer, rows: table<integer, boolean> }>

--- Marks drawn as real extmarks instead of ephemeral ones: inline virtual
--- text (which can't be ephemeral) and overlays that must be placed after
--- an inline mark at the same column.
local function is_persistent(m)
  return m[3] or m[2].virt_text_pos == "inline"
end

local function sync_inline(bufnr, rows, top, bot)
  local tick = cache[bufnr].tick
  local synced = inline_synced[bufnr]
  if not synced or synced.tick ~= tick then
    synced = { tick = tick, rows = {} }
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

vim.api.nvim_set_decoration_provider(ns, {
  on_win = function(_, _, bufnr, toprow, botrow)
    if not attached[bufnr] then
      return false
    end
    botrow = math.min(botrow, vim.api.nvim_buf_line_count(bufnr) - 1)
    current = rows_for(bufnr, toprow, botrow)
    sync_inline(bufnr, current, toprow, botrow)
    return next(current) ~= nil
  end,
  on_line = function(_, _, bufnr, row)
    local marks = current and current[row]
    if not marks then
      return
    end
    for _, m in ipairs(marks) do
      if not is_persistent(m) then
        local opts = vim.tbl_extend("force", m[2], { ephemeral = true })
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, m[1], opts)
      end
    end
  end,
})

--- Recompute on the next redraw (e.g. after `ui` options changed).
function M.render(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  cache[bufnr] = nil
  ui_cache[bufnr] = nil
  num_cache[bufnr] = nil
  inline_synced[bufnr] = nil
  vim.api.nvim_buf_clear_namespace(bufnr, ns_inline, 0, -1)
  pcall(vim.api.nvim__redraw, { buf = bufnr, valid = false })
end

---@param force? boolean attach even when nothing is enabled (toggles)
function M.attach(bufnr, force)
  local ui = M.ui_options(bufnr)
  if not enabled(ui) and not force then
    return
  end
  if ui.indent_mode then
    vim.api.nvim_buf_call(bufnr, function()
      vim.wo.breakindent = true
      vim.wo.wrap = true
    end)
  end
  if not attached[bufnr] and not force then
    -- the modes turned on when the buffer is set up (org-startup-indented,
    -- org-startup-numerated) run their hooks
    if ui.indent_mode then
      mode_hook("OrgIndentMode", bufnr, true)
    end
    if ui.num then
      mode_hook("OrgNumMode", bufnr, true)
    end
  end
  attached[bufnr] = true
  local group = vim.api.nvim_create_augroup("org.decorations." .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = bufnr,
    callback = function()
      attached[bufnr] = nil
      cache[bufnr] = nil
      ui_cache[bufnr] = nil
      num_cache[bufnr] = nil
      inline_synced[bufnr] = nil
    end,
  })
  M.render(bufnr)
end

function M.refresh(bufnr)
  M.render(bufnr)
end

return M
