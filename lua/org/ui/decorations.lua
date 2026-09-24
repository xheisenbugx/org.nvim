---@mod org.ui.decorations Visual decorations (bullets, checkboxes, indent mode)
---
--- Enabled through `ui.bullets`, `ui.hide_leading_stars`, `ui.checkboxes`,
--- `ui.indent_mode` and `ui.pretty_entities`. Extmarks are recomputed for
--- the whole buffer after changes (debounced), which keeps rendering simple
--- and works with inline virtual text.

local M = {}

local ns = vim.api.nvim_create_namespace("org.decorations")
local timers = {}

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

function M.render(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local ui = require("org.config").opts.ui
  if not enabled(ui) then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local level = 0
  local in_block = false
  local set = vim.api.nvim_buf_set_extmark
  local bullets = type(ui.bullets) == "table" and ui.bullets or nil
  local boxes = type(ui.checkboxes) == "table" and ui.checkboxes or nil
  for i, line in ipairs(lines) do
    local row = i - 1
    local stars = line:match("^(%*+)%s") or line:match("^(%*+)$")
    if stars then
      level = #stars
      in_block = false
      if bullets then
        local b = bullets[((level - 1) % #bullets) + 1]
        local pad = ui.indent_mode and "" or string.rep(" ", level - 1)
        set(bufnr, ns, row, 0, {
          virt_text = { { pad .. b, "OrgHeadlineLevel" .. (((level - 1) % 8) + 1) } },
          virt_text_pos = "overlay",
          hl_mode = "combine",
        })
        if ui.indent_mode and level > 1 then
          set(bufnr, ns, row, 0, { end_col = level - 1, conceal = "" })
        end
      elseif ui.hide_leading_stars or ui.indent_mode then
        if level > 1 then
          set(bufnr, ns, row, 0, {
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
        set(bufnr, ns, row, 0, {
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
            set(bufnr, ns, row, #pre, { virt_text = { { text, grp } }, virt_text_pos = "overlay" })
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
            set(bufnr, ns, row, s - 1, { end_col = stop - 1, conceal = sym })
          end
        end
      end
    end
  end
end

function M.schedule(bufnr)
  local t = timers[bufnr]
  if t then
    t:stop()
  else
    t = vim.uv.new_timer()
    timers[bufnr] = t
  end
  t:start(
    120,
    0,
    vim.schedule_wrap(function()
      M.render(bufnr)
    end)
  )
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
  M.render(bufnr)
  local group = vim.api.nvim_create_augroup("org.decorations." .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      M.schedule(bufnr)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = bufnr,
    callback = function()
      local t = timers[bufnr]
      if t then
        t:stop()
        t:close()
        timers[bufnr] = nil
      end
    end,
  })
end

function M.refresh(bufnr)
  M.render(bufnr)
end

return M
