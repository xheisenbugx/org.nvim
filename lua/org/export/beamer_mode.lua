---@mod org.export.beamer_mode Beamer editing support (org-beamer-mode)
---
--- A buffer-local mode for Beamer presentations: `beamer_select_environment`
--- (<C-c><C-b> while the mode is on) picks the BEAMER_env of an entry with
--- the fast tag selection, and the B_ENV / BMCOL tags that mirror
--- BEAMER_env / BEAMER_col get the `OrgBeamerTag` highlight. Turned on by
--- `startup_with_beamer_mode` or `#+STARTUP: beamer`. Toggling the mode
--- fires the `OrgBeamerMode` User autocmd (org-beamer-mode-hook) with
--- `data = { bufnr, enabled }`.

local config = require("org.config")
local edit = require("org.edit")
local utils = require("org.utils")

local M = {}

--- org-beamer-environments-special: handled by the back-end itself.
M.SPECIAL = {
  { "againframe", "A" },
  { "appendix", "x" },
  { "column", "c" },
  { "columns", "C" },
  { "frame", "f" },
  { "fullframe", "F" },
  { "ignoreheading", "i" },
  { "note", "n" },
  { "noteNH", "N" },
}

--- The environments offered by the selection: special ones first, then
--- `export.beamer.environments_extra`, then the defaults (so the special
--- keys win, like Emacs).
function M.environments()
  local envs = vim.deepcopy(M.SPECIAL)
  local beamer_cfg = (config.opts.export or {}).beamer or {}
  for _, e in ipairs(beamer_cfg.environments_extra or {}) do
    envs[#envs + 1] = { e[1], e[2] }
  end
  local ok, beamer = pcall(require, "org.export.beamer")
  for _, e in ipairs(ok and beamer.environments_default or {}) do
    envs[#envs + 1] = { e[1], e[2] }
  end
  return envs
end

local hook_installed = false

--- Keep the B_ENV / BMCOL tags in step with BEAMER_env / BEAMER_col
--- (org-beamer-property-changed on org-property-changed-functions).
local function install_property_hook()
  if hook_installed then
    return
  end
  hook_installed = true
  vim.api.nvim_create_autocmd("User", {
    pattern = "OrgPropertyChanged",
    group = vim.api.nvim_create_augroup("OrgBeamerProperty", { clear = true }),
    callback = function(ev)
      local d = ev.data or {}
      if d.name == "BEAMER_env" or d.name == "BEAMER_col" then
        pcall(M.property_changed, d.bufnr, d.lnum, d.name, d.value)
      end
    end,
  })
end

--- org-beamer-property-changed
function M.property_changed(bufnr, lnum, name, value)
  local _, _, hl = edit.resolve_headline({ bufnr = bufnr, lnum = lnum })
  if not hl then
    return
  end
  local tags = {}
  if name == "BEAMER_env" then
    for _, t in ipairs(hl.tags) do
      if not t:match("^B_") then
        tags[#tags + 1] = t
      end
    end
    if value and value:match("%S") then
      table.insert(tags, 1, "B_" .. value)
    end
  else
    local on = value and value:match("%S")
    for _, t in ipairs(hl.tags) do
      if t ~= "BMCOL" then
        tags[#tags + 1] = t
      end
    end
    if on then
      tags[#tags + 1] = "BMCOL"
    end
  end
  if not vim.deep_equal(tags, hl.tags) then
    edit.update_headline(bufnr, hl.line, { tags = tags })
  end
end

local function entry_delete(bufnr, lnum, name)
  edit.set_property(bufnr, lnum, name, nil)
end

--- Select the Beamer environment of the entry (org-beamer-select-environment):
--- a fast tag selection of B_ENV tags (one key each, exclusive) and BMCOL
--- (`|`). The choice sets the BEAMER_env property (and its tag); `|` asks
--- for the column width (BEAMER_col), `A` for the frame reference and
--- overlay of an "againframe" (pressed again, it removes them).
function M.select_environment()
  local bufnr, _, hl = edit.resolve_headline()
  if not hl then
    utils.warn("Before first headline")
    return false
  end
  install_property_hook()
  local envs = M.environments()
  local defs = { { group = "{" } }
  for _, e in ipairs(envs) do
    defs[#defs + 1] = { name = "B_" .. e[1], key = e[2] }
  end
  defs[#defs + 1] = { group = "}" }
  defs[#defs + 1] = { name = "BMCOL", key = "|" }
  local tags, key = require("org.tags").fast_select(hl.tags, defs, {}, { single = true })
  if not tags then
    return
  end
  local lnum = hl.line
  edit.update_headline(bufnr, lnum, { tags = tags })
  local props = require("org.properties")
  local function get(name)
    local _, _, h = edit.resolve_headline({ bufnr = bufnr, lnum = lnum })
    return h and h:get_property(name, false)
  end
  if key == "|" then
    if vim.tbl_contains(tags, "BMCOL") then
      local width = utils.input({ prompt = "Column width: " })
      props.set_property({ bufnr = bufnr, lnum = lnum }, "BEAMER_col", width or "")
    else
      props.delete_property({ bufnr = bufnr, lnum = lnum }, "BEAMER_col")
    end
  elseif key == "A" then
    if get("BEAMER_env") == "againframe" then
      entry_delete(bufnr, lnum, "BEAMER_env")
      entry_delete(bufnr, lnum, "BEAMER_ref")
      entry_delete(bufnr, lnum, "BEAMER_act")
    else
      props.entry_put(bufnr, lnum, "BEAMER_env", "againframe")
      local ref = utils.input({ prompt = "Frame reference (*Title, #custom-id, id:...): " })
      props.set_property({ bufnr = bufnr, lnum = lnum }, "BEAMER_ref", ref or "")
      local act = utils.input({ prompt = "Overlay specification: " })
      props.set_property({ bufnr = bufnr, lnum = lnum }, "BEAMER_act", act or "")
    end
  else
    local names = {}
    for _, e in ipairs(envs) do
      names[e[1]] = true
    end
    local env
    for _, t in ipairs(tags) do
      local n = t:match("^B_(.+)$")
      if n and names[n] then
        env = n
        break
      end
    end
    if env then
      props.entry_put(bufnr, lnum, "BEAMER_env", env)
    else
      entry_delete(bufnr, lnum, "BEAMER_env")
    end
  end
end

--- Is org-beamer-mode on in `bufnr`?
function M.enabled(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  return vim.b[bufnr].org_beamer_mode == true
end

local function keys()
  local maps = config.opts.mappings or {}
  if maps.disable_all then
    return {}
  end
  local section = maps.beamer or {}
  return config.lhs_list(section.beamer_select_environment)
end

--- Turn org-beamer-mode on or off (toggle when `on` is nil) in `bufnr`.
function M.mode(bufnr, on)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  if on == nil then
    on = not M.enabled(bufnr)
  end
  if on == M.enabled(bufnr) then
    return on
  end
  vim.b[bufnr].org_beamer_mode = on
  local saved = vim.b[bufnr].org_beamer_saved_maps or {}
  if on then
    install_property_hook()
    saved = {}
    for _, lhs in ipairs(keys()) do
      local old = vim.api.nvim_buf_call(bufnr, function()
        return vim.fn.maparg(lhs, "n", false, true)
      end)
      if old and old.buffer == 1 then
        saved[#saved + 1] = old
      end
      vim.keymap.set("n", lhs, function()
        require("org.utils").run(M.select_environment)
      end, { buffer = bufnr, desc = "org: Select Beamer environment" })
    end
    vim.b[bufnr].org_beamer_saved_maps = saved
    pcall(vim.api.nvim_set_hl, 0, "OrgBeamerTag", { default = true, link = "Special" })
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd([=[syntax match orgBeamerTag /:\zs\(B_\l\+\|BMCOL\)\ze:/ contained containedin=orgTags]=])
      vim.cmd("highlight default link orgBeamerTag OrgBeamerTag")
    end)
  else
    for _, lhs in ipairs(keys()) do
      pcall(vim.keymap.del, "n", lhs, { buffer = bufnr })
    end
    for _, m in ipairs(saved) do
      vim.api.nvim_buf_call(bufnr, function()
        pcall(vim.fn.mapset, "n", false, m)
      end)
    end
    vim.b[bufnr].org_beamer_saved_maps = nil
    vim.api.nvim_buf_call(bufnr, function()
      pcall(vim.cmd, "syntax clear orgBeamerTag")
    end)
  end
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "OrgBeamerMode",
    data = { bufnr = bufnr, enabled = on },
    modeline = false,
  })
  return on
end

--- Toggle org-beamer-mode in the current buffer (the `beamer_mode` action).
function M.toggle()
  local on = M.mode(0)
  utils.notify("Org Beamer mode " .. (on and "enabled" or "disabled"))
  return true
end

--- Turn the mode on when the buffer is opened with
--- `startup_with_beamer_mode` (org-startup-with-beamer-mode) or
--- `#+STARTUP: beamer`.
function M.setup_buffer(bufnr)
  local on = config.opts.startup_with_beamer_mode == true
  if not on then
    local ok, file = pcall(function()
      return require("org.files").get_buffer(bufnr)
    end)
    on = ok and file and file.settings and file.settings.startup and file.settings.startup.beamer or false
  end
  if on then
    M.mode(bufnr, true)
  end
end

return M
