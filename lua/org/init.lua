---@mod org org.nvim - Org mode for Neovim
---
--- Public API. Most functionality lives in feature modules; this file only
--- wires configuration, commands and global keymaps.
---
--- ```lua
--- require("org").setup({ org_directory = "~/org" })
--- vim.keymap.set("n", "<leader>oa", function() require("org").agenda() end)
--- vim.keymap.set("n", "<leader>oc", function() require("org").capture("t") end)
--- ```

---@class org
local M = {}

local did_setup = false

--- Configure org.nvim. Merges `opts` over the defaults (see `:h org-config`),
--- registers `:Org`, the global keymaps and highlights, starts agenda
--- notifications (`notifications.enabled`) and restores a persisted clock
--- (`clock.persist`). Org buffers opened before `setup` are attached too.
--- Calling it again re-applies the configuration.
---
--- ```lua
--- require("org").setup({
---   org_directory = "~/org",
---   agenda_files = { "~/org/**/*.org" },
--- })
--- ```
---@param opts? org.Config user options; omitted fields keep their defaults
---@return org the `org` module itself, so calls can be chained
function M.setup(opts)
  require("org.config").setup(opts)
  did_setup = true
  require("org.commands").setup()
  require("org.mappings").setup_global()
  require("org.highlights").setup()
  local cfg = require("org.config").opts
  if cfg.notifications.enabled then
    vim.schedule(function()
      local ok, n = pcall(require, "org.agenda.notifications")
      if ok then
        n.start()
      end
    end)
  end
  if cfg.clock.persist then
    vim.schedule(function()
      local ok, clock = pcall(require, "org.clock")
      if ok and clock.restore then
        pcall(clock.restore)
      end
    end)
  end
  -- attach to org buffers that were opened before setup ran
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == "org" then
      require("org.buffer").attach(b)
    end
  end
  return M
end

--- Ensure setup ran with defaults (e.g. when a user opens an org file
--- without calling setup). Does nothing when `setup` was already called.
function M.ensure_setup()
  if not did_setup then
    M.setup({})
  end
end

--- Open the agenda dispatcher, or a specific view (see `:h org-agenda`).
---
--- `key` takes the same arguments as `:Org agenda`: a built-in view
--- (`"a"` agenda, `"t"` TODOs, `"T KW"`, `"m MATCH"`, `"M MATCH"`,
--- `"s TEXT"`, `"S TEXT"`, `"n"`, `"#"` stuck projects, `"/ REGEXP"`), a span
--- (`"day"`, `"week"`, `"fortnight"`, `"month"`, `"year"` or a number of
--- days), a key of `agenda.custom_commands`, or a date (`"+2d"`,
--- `"2026-10-01"`). A key that needs input but has none prompts for it.
---
--- ```lua
--- vim.keymap.set("n", "<leader>oa", function() require("org").agenda() end)
--- vim.keymap.set("n", "<leader>ow", function() require("org").agenda("m +work") end)
--- ```
---@param key? string view key and arguments; nil opens the dispatcher menu
function M.agenda(key)
  require("org.utils").run(function()
    if key then
      require("org.agenda").command(key)
    else
      require("org.agenda").prompt()
    end
  end)
end

--- Start a capture (see `:h org-capture`). `key` selects a template of
--- `capture.templates` directly (e.g. `"t"`, or `"wm"` for a template in
--- group `w`); without it the template menu opens. In visual mode the
--- selection becomes the template's `%i`.
---
--- ```lua
--- vim.keymap.set({ "n", "x" }, "<leader>oc", function() require("org").capture() end)
--- vim.keymap.set("n", "<leader>ot", function() require("org").capture("t") end)
--- ```
---@param key? string template key; nil opens the template menu
function M.capture(key)
  require("org.utils").run(function()
    if key then
      require("org.capture").command(key)
    else
      require("org.capture").prompt()
    end
  end)
end

--- Statusline component showing the running clock and timer (empty when
--- idle), e.g. `"⏱ [0:25/1:00] (Write report) ⏲ 0:12:34"`. Cheap enough to
--- call on every redraw.
---
--- ```lua
--- -- lualine
--- table.insert(opts.sections.lualine_x, 1, { function() return require("org").statusline() end })
--- -- built-in statusline
--- vim.o.statusline = "%f %= %{v:lua.require'org'.statusline()}"
--- ```
---@return string component clock and timer text joined by a space, or `""`
function M.statusline()
  local parts = {}
  for _, mod in ipairs({ "org.clock", "org.timer" }) do
    local ok, m = pcall(require, mod)
    local s = ok and m.statusline and m.statusline() or ""
    if s ~= "" then
      parts[#parts + 1] = s
    end
  end
  return table.concat(parts, " ")
end

--- Run a named action (see `:h org-keymaps` and `org.actions`), the same as
--- `:Org <name>`. Most actions operate at the cursor in an org buffer.
---
--- ```lua
--- vim.keymap.set("n", "<leader>oi", function() require("org").action("clock_in") end)
--- ```
---@param name org.ActionName action name, e.g. `"clock_in"`, `"todo_next"`, `"refile"`
---@return boolean handled false when the action did not apply here (a mapping
--- then falls back to the key's default behaviour); unknown names return true
function M.action(name)
  return require("org.actions").run(name)
end

return M
