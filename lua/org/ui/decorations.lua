---@mod org.ui.decorations Visual decorations (bullets, checkboxes, indent mode)
---
--- Enabled through `ui.bullets`, `ui.hide_leading_stars`, `ui.checkboxes`,
--- `ui.indent_mode` and `ui.pretty_entities`. Drawn at redraw time by a
--- decoration provider (see below).

local M = {}

local ns = vim.api.nvim_create_namespace("org.decorations")

--- A few common org entities (org-pretty-entities).
M.entities = {
  alpha = "α", beta = "β", gamma = "γ", delta = "δ", epsilon = "ε", zeta = "ζ", eta = "η",
  theta = "θ", iota = "ι", kappa = "κ", lambda = "λ", mu = "μ", nu = "ν", xi = "ξ", pi = "π",
  rho = "ρ", sigma = "σ", tau = "τ", upsilon = "υ", phi = "φ", chi = "χ", psi = "ψ", omega = "ω",
  Gamma = "Γ", Delta = "Δ", Theta = "Θ", Lambda = "Λ", Xi = "Ξ", Pi = "Π", Sigma = "Σ",
  Phi = "Φ", Psi = "Ψ", Omega = "Ω", to = "→", rarr = "→", larr = "←", leftarrow = "←",
  rightarrow = "→", Rightarrow = "⇒", Leftarrow = "⇐", infin = "∞", infty = "∞", pm = "±",
  times = "×", div = "÷", le = "≤", ge = "≥", ne = "≠", neq = "≠", approx = "≈", deg = "°",
  cdot = "⋅", sum = "∑", prod = "∏", int = "∫", partial = "∂", nabla = "∇", forall = "∀",
  exists = "∃", in_ = "∈", isin = "∈", notin = "∉", sub = "⊂", sup = "⊃", cap = "∩", cup = "∪",
  empty = "∅", check = "✓", star = "⋆", hellip = "…", dots = "…", mdash = "—", ndash = "–",
  copy = "©", reg = "®", trade = "™", euro = "€", pound = "£", yen = "¥", cent = "¢",
  checkmark = "✓", S = "§", P = "¶", dagger = "†", laquo = "«", raquo = "»", nbsp = " ",
}

local function enabled(ui)
  return ui.bullets or ui.hide_leading_stars or ui.checkboxes or ui.indent_mode or ui.pretty_entities
end

--- Decorations of a buffer, per 0-based row: `{ [row] = { { col, opts }, ... } }`.
---@return table<integer, table[]>
function M.compute(bufnr)
  local rows = {}
  local ui = require("org.config").opts.ui
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
  for i, line in ipairs(lines) do
    local row = i - 1
    local stars = line:match("^(%*+) ")
    if stars then
      level = #stars
      in_block = false
      if bullets then
        local b = bullets[((level - 1) % #bullets) + 1]
        local pad = ui.indent_mode and "" or string.rep(" ", level - 1)
        set(row, 0, {
          virt_text = { { pad .. b, "OrgHeadlineLevel" .. (((level - 1) % 8) + 1) } },
          virt_text_pos = "overlay",
          hl_mode = "combine",
        })
        if ui.indent_mode and level > 1 then
          set(row, 0, { end_col = level - 1, conceal = "" })
        end
      elseif ui.hide_leading_stars or ui.indent_mode then
        if level > 1 then
          set(row, 0, {
            virt_text = { { string.rep(" ", level - 1), "OrgHiddenStars" } },
            virt_text_pos = "overlay",
          })
        end
      end
    else
      if line:match("^%s*#%+[bB][eE][gG][iI][nN]_") then
        in_block = true
      elseif line:match("^%s*#%+[eE][nN][dD]_") then
        in_block = false
      end
      if ui.indent_mode and level > 0 and line ~= "" then
        set(row, 0, {
          virt_text = { { string.rep(" ", level + 1), "Normal" } },
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
      if ui.pretty_entities and not in_block then
        for s, name, e in line:gmatch("()\\(%a+)(){?}?") do
          local sym = M.entities[name]
          if sym then
            local stop = e
            if line:sub(e, e + 1) == "{}" then
              stop = e + 2
            end
            set(row, s - 1, { end_col = stop - 1, conceal = sym })
          end
        end
      end
    end
  end
  return rows
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

function M.attach(bufnr)
  local ui = require("org.config").opts.ui
  if not enabled(ui) then
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
