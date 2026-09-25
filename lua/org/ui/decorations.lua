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
function M.ui_options(bufnr)
  local ui = vim.deepcopy(require("org.config").opts.ui)
  local ok, file = pcall(require("org.files").get_buffer, bufnr)
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

local function enabled(ui)
  return ui.bullets
    or ui.hide_leading_stars
    or ui.checkboxes
    or ui.indent_mode
    or ui.pretty_entities
    or ui.num
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

--- Decorations of a buffer, per 0-based row: `{ [row] = { { col, opts }, ... } }`.
---@return table<integer, table[]>
function M.compute(bufnr)
  local rows = {}
  local ui = M.ui_options(bufnr)
  if not enabled(ui) then
    return rows
  end
  local function set(row, col, opts)
    local r = rows[row]
    if not r then
      r = {}
      rows[row] = r
    end
    r[#r + 1] = { col, opts }
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local level = 0
  local in_block = false
  local bullets = type(ui.bullets) == "table" and ui.bullets or nil
  local boxes = type(ui.checkboxes) == "table" and ui.checkboxes or nil
  local nums = ui.num and numbering(lines, ui) or {}
  local scripts = ui.pretty_entities and ui.pretty_entities_include_sub_superscripts ~= false
    and ui.use_sub_superscripts ~= false
  local braces_only = ui.use_sub_superscripts == "{}"
  for i, line in ipairs(lines) do
    local row = i - 1
    local stars = line:match("^(%*+) ")
    local min_inline = require("org.parser").inlinetask_min_level()
    if stars and min_inline and #stars >= min_inline then
      -- inline task: only the last two stars show (org-inlinetask-fontify)
      if #stars > 2 then
        set(row, 0, {
          virt_text = { { string.rep(" ", #stars - 2), "OrgHiddenStars" } },
          virt_text_pos = "overlay",
        })
      end
      set(row, #stars - 2, { end_col = #line, hl_group = "OrgInlinetask", priority = 150 })
    elseif stars then
      level = #stars
      in_block = false
      local group = "OrgHeadlineLevel" .. (((level - 1) % 8) + 1)
      if ui.indent_mode and level > 1 then
        -- org-indent: headlines get level - 1 columns of prefix
        set(row, 0, {
          virt_text = { { string.rep(" ", level - 1), "OrgHiddenStars" } },
          virt_text_pos = "inline",
          right_gravity = false,
        })
      end
      if bullets then
        local b = bullets[((level - 1) % #bullets) + 1]
        local pad = ui.indent_mode and "" or string.rep(" ", level - 1)
        set(row, 0, {
          virt_text = { { pad .. b, group } },
          virt_text_pos = "overlay",
          hl_mode = "combine",
        })
        if ui.indent_mode and level > 1 then
          set(row, 0, { end_col = level - 1, conceal = "" })
        end
      elseif ui.hide_leading_stars then
        if level > 1 then
          set(row, 0, {
            virt_text = { { string.rep(" ", level - 1), "OrgHiddenStars" } },
            virt_text_pos = "overlay",
          })
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
      elseif line:match("^%s*#%+[eE][nN][dD]_") then
        in_block = false
      end
      if ui.indent_mode and level > 0 and line ~= "" then
        -- org-indent: text of a level-n entry starts at column 2n
        set(row, 0, {
          virt_text = { { string.rep(" ", 2 * level), "Normal" } },
          virt_text_pos = "inline",
          right_gravity = false,
        })
      end
      if boxes and not in_block then
        local pre, box = line:match("^(%s*[-+*]%s+)(%[[ xX%-]%])")
        if not pre then
          pre, box = line:match("^(%s*%d+[.)]%s+)(%[[ xX%-]%])")
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
        if sym and not after:match("%a") and not in_ranges(protected, s) then
          local stop = e
          if line:sub(e + 1, e + 2) == "{}" then
            stop = e + 2
          end
          set(row, s - 1, { end_col = stop, conceal = vim.fn.strcharpart(sym, 0, 1) })
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

--- org-num-mode: toggle virtual headline numbering in this buffer.
function M.toggle_num_mode()
  local bufnr = vim.api.nvim_get_current_buf()
  local on = not M.ui_options(bufnr).num
  vim.b[bufnr].org_num_mode = on
  M.attach(bufnr, true)
  require("org.utils").notify(on and "Org-Num mode enabled" or "Org-Num mode disabled")
end

-- Decorations are drawn by a decoration provider from the buffer text at
-- redraw time, so they can never lag behind an edit. (Persistent extmarks
-- updated after a debounce were dragged to wrong rows/columns by line
-- replacements and showed up in odd places until the next render.)
-- Results are cached per changedtick.
local attached = {} ---@type table<integer, boolean>
local cache = {} ---@type table<integer, { tick: integer, rows: table<integer, table[]> }>

local function rows_for(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local c = cache[bufnr]
  if not c or c.tick ~= tick then
    c = { tick = tick, rows = M.compute(bufnr) }
    cache[bufnr] = c
  end
  return c.rows
end

local current ---@type table<integer, table[]>?

-- Inline virtual text (indent mode) can't be ephemeral, so those marks are
-- real extmarks in their own namespace, rebuilt before the window is drawn
-- whenever the text changed.
local ns_inline = vim.api.nvim_create_namespace("org.decorations.inline")
local inline_tick = {} ---@type table<integer, integer>

local function is_inline(opts)
  return opts.virt_text_pos == "inline"
end

local function sync_inline(bufnr, rows)
  local tick = cache[bufnr].tick
  if inline_tick[bufnr] == tick then
    return
  end
  inline_tick[bufnr] = tick
  vim.api.nvim_buf_clear_namespace(bufnr, ns_inline, 0, -1)
  for row, marks in pairs(rows) do
    for _, m in ipairs(marks) do
      if is_inline(m[2]) then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_inline, row, m[1], m[2])
      end
    end
  end
end

vim.api.nvim_set_decoration_provider(ns, {
  on_win = function(_, _, bufnr)
    if not attached[bufnr] then
      return false
    end
    current = rows_for(bufnr)
    sync_inline(bufnr, current)
    return next(current) ~= nil
  end,
  on_line = function(_, _, bufnr, row)
    local marks = current and current[row]
    if not marks then
      return
    end
    for _, m in ipairs(marks) do
      if not is_inline(m[2]) then
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
  inline_tick[bufnr] = nil
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
  attached[bufnr] = true
  local group = vim.api.nvim_create_augroup("org.decorations." .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = bufnr,
    callback = function()
      attached[bufnr] = nil
      cache[bufnr] = nil
      inline_tick[bufnr] = nil
    end,
  })
  M.render(bufnr)
end

function M.refresh(bufnr)
  M.render(bufnr)
end

return M
