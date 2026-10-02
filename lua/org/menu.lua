---@mod org.menu Menus (easymenu)
---
--- The menus Emacs Org defines with easy-menu-define, as Neovim menus
--- (|:menu|): "Org" and "Table" in org buffers (org-org-menu,
--- org-tbl-menu), "Agenda" in the agenda (org-agenda-menu), "Column" in
--- column view (org-columns-menu), "Edit-Formulas" in the formula editor
--- (org-table-fedit-menu) and "OrgTbl" where orgtbl-mode is on
--- (orgtbl-mode-menu), with the same entries in the same order. Neovim
--- menus are global, so a menu is added when a buffer it belongs to is
--- entered and removed when another buffer is: they behave like Emacs's
--- mode-local menus. GUIs show them in the menu bar; anywhere they can be
--- run with |:emenu| (`:emenu Org.<Tab>`) or shown with |:popup|
--- (`:popup Org`). `ui.menus = false` turns them off.
---
--- An entry that is greyed out in Emacs (its :active form is false at
--- point) is disabled before a |:popup| and does nothing, with a message,
--- when run otherwise.

local config = require("org.config")
local utils = require("org.utils")

local M = {}

---@class org.MenuEntry
---@field [1] string label
---@field action? string an org action (`org.actions`)
---@field agenda? string an agenda action (`org.agenda.view`)
---@field keys? string keys fed with remapping (the buffer's own keys)
---@field fn? fun() run in a coroutine
---@field count? integer the prefix argument (4 = C-u, 16 = C-u C-u)
---@field visual? boolean run on the Visual selection (keeps it)
---@field active? fun(): boolean greyed out when false
---@field hint? string|false key text shown right of the label
---@field items? (org.MenuEntry|string)[] a submenu
---@field title? boolean a label that is not a command
---@field dynamic? fun(): (org.MenuEntry|string)[] items built when the menu is added

--- root -> { [id] = entry }
M._registry = {}
--- Roots currently defined, root -> true.
M._defined = {}
--- The item lists of the defined roots, for `update`.
M._items = {}

--- Escape one menu path component for |:menu|.
---@param s string
---@return string
function M.escape(s)
  s = s:gsub("\\", "\\\\"):gsub("%.", "\\."):gsub(" ", "\\ "):gsub("|", "\\|"):gsub("&", "&&")
  -- "<Tab>" would start the key hint
  return (s:gsub("<Tab>", "Tab"))
end

--- The first key of an org action in the org / Emacs key sections, for the
--- hint shown right of a menu label (Emacs shows the binding).
---@param name string
---@param section? string mapping section: "agenda" for agenda actions
---@return string|nil
function M.key_for(name, section)
  local maps = config.opts.mappings or {}
  local sections = section and { section } or { "org", "emacs", "global", "emacs_global" }
  for _, s in ipairs(sections) do
    local lhs = config.lhs_list((maps[s] or {})[name])[1]
    if lhs then
      return lhs
    end
  end
  return nil
end

local function hint_of(e)
  if e.hint ~= nil then
    return e.hint or nil
  end
  local key
  if e.action then
    key = M.key_for(e.action)
  elseif e.agenda then
    key = M.key_for(e.agenda, "agenda")
  elseif e.keys then
    key = e.keys
  end
  if key and e.count then
    key = e.count .. key
  end
  return key
end

--- Define the menu `root` (a menu path, e.g. "Org" or "]OrgMouse") with
--- `items`, replacing it when it exists.
---@param root string
---@param items (org.MenuEntry|string)[]
function M.define(root, items)
  M.remove(root)
  local reg = {}
  M._registry[root] = reg
  local sep = 0
  local function emit(prefix, list)
    for _, e in ipairs(list) do
      if type(e) == "string" then
        -- "--" and "-": separators
        sep = sep + 1
        vim.cmd(string.format("silent anoremenu %s.-sep%d- <Nop>", prefix, sep))
      else
        local path = prefix .. "." .. M.escape(e[1])
        local items_ = e.items or (e.dynamic and e.dynamic())
        if items_ then
          if #items_ == 0 then
            -- an empty submenu (Emacs shows it greyed out)
            vim.cmd(string.format("silent anoremenu %s.(empty) <Nop>", path))
            vim.cmd(string.format("silent! amenu disable %s.(empty)", path))
          else
            emit(path, items_)
          end
        elseif e.title then
          vim.cmd(string.format("silent anoremenu %s <Nop>", path))
          vim.cmd(string.format("silent! amenu disable %s", path))
        else
          local id = #reg + 1
          reg[id] = e
          local hint = hint_of(e)
          local name = path .. (hint and ("<Tab>" .. M.escape(hint)) or "")
          local call = string.format("<Cmd>lua require('org.menu')._run(%q, %d)<CR>", root, id)
          -- the count of fed keys goes with the keys
          local count = (e.count and not e.keys) and tostring(e.count) or ""
          vim.cmd(string.format("silent nnoremenu <silent> %s %s%s", name, count, call))
          vim.cmd(string.format("silent inoremenu <silent> %s <C-\\><C-O>%s%s", name, count, call))
          if e.visual then
            vim.cmd(string.format("silent vnoremenu <silent> %s %s", name, call))
          else
            vim.cmd(string.format("silent vnoremenu <silent> %s <Esc>%s%s", name, count, call))
          end
        end
      end
    end
  end
  emit(root, items)
  M._defined[root] = true
  M._items[root] = items
end

--- Remove the menu `root`.
---@param root string
function M.remove(root)
  if M._defined[root] then
    vim.cmd("silent! aunmenu " .. root)
  end
  M._defined[root] = nil
  M._registry[root] = nil
  M._items[root] = nil
end

local function is_active(e)
  if not e.active then
    return true
  end
  local ok, res = pcall(e.active)
  return ok and res and true or false
end

--- Enable or disable the entries of `root` by their :active predicate,
--- at the cursor (before a popup, like Emacs's menu update).
---@param root string
function M.update(root)
  local function walk(prefix, list)
    for _, e in ipairs(list) do
      if type(e) == "table" and not e.title then
        local path = prefix .. "." .. M.escape(e[1])
        local items_ = e.items
        if items_ then
          walk(path, items_)
        elseif not e.dynamic then
          vim.cmd(string.format("silent! amenu %s %s", is_active(e) and "enable" or "disable", path))
        end
      end
    end
  end
  if M._items[root] then
    walk(root, M._items[root])
  end
end

--- Run entry `id` of menu `root` (the rhs of every menu entry).
---@param root string
---@param id integer
function M._run(root, id)
  local e = (M._registry[root] or {})[id]
  if not e then
    return
  end
  if not is_active(e) then
    utils.warn(string.format("Menu entry “%s” is not available here", e[1]))
    return
  end
  if e.action then
    if not require("org.actions").run(e.action) then
      utils.warn(string.format("“%s” does not apply here", e[1]))
    end
  elseif e.agenda then
    require("org.agenda.view").run_action(e.agenda)
  elseif e.keys then
    vim.api.nvim_feedkeys((e.count and tostring(e.count) or "") .. vim.keycode(e.keys), "m", false)
  elseif e.fn then
    utils.run(e.fn)
  end
end

--- Show the menu `root` at the mouse or cursor (|:popup|). Replaced in
--- tests.
---@param root string
function M._popup(root)
  vim.cmd("popup " .. root)
end

--- Update and show the menu `root` as a popup menu.
---@param root string
function M.popup(root)
  M.update(root)
  M._popup(root)
end

--- Menus that belong in the current buffer: root -> builder.
---@return table<string, fun(): (org.MenuEntry|string)[]>
function M.wanted()
  -- org.menu_defs is loaded only once a buffer wants a menu (not on
  -- setup() or entering any other buffer)
  local defs = setmetatable({}, {
    __index = function(_, k)
      return require("org.menu_defs")[k]
    end,
  })
  local want = {}
  local buf = vim.api.nvim_get_current_buf()
  local ft = vim.bo[buf].filetype
  if ft == "org" then
    want.Org = defs.org
    want.Table = defs.table
    if package.loaded["org.columns"] and require("org.columns").is_active(buf) then
      want.Column = defs.columns
    end
  elseif ft == "orgagenda" then
    want.Agenda = defs.agenda
  elseif ft == "orgcolumns" then
    want.Column = defs.columns
  elseif ft == "orgformulas" then
    want["Edit-Formulas"] = defs.fedit
  end
  if vim.b[buf].orgtbl_mode then
    want.OrgTbl = defs.orgtbl
  end
  return want
end

--- The mode-local menus: add the menus of the current buffer and remove
--- the others. Floating windows (prompts, the calendar) leave them alone.
---@param force? boolean rebuild the wanted menus too
function M.sync(force)
  if vim.api.nvim_win_get_config(0).relative ~= "" then
    return
  end
  local want = (config.opts.ui or {}).menus == false and {} or M.wanted()
  for _, root in ipairs({ "Org", "Table", "Agenda", "Column", "Edit-Formulas", "OrgTbl" }) do
    if want[root] then
      if force or not M._defined[root] then
        M.define(root, want[root]())
      end
    elseif M._defined[root] then
      M.remove(root)
    end
  end
end

--- Install the autocmds keeping the menus in step with the current buffer.
function M.setup()
  local group = vim.api.nvim_create_augroup("org.menu", { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "FileType", "WinEnter" }, {
    group = group,
    callback = function()
      M.sync()
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "OrgtblMode",
    callback = function()
      vim.schedule(M.sync)
    end,
  })
  vim.api.nvim_create_autocmd("MenuPopup", {
    group = group,
    callback = function()
      for root in pairs(M._defined) do
        M.update(root)
      end
    end,
  })
  M.sync(true)
end

---------------------------------------------------------------------------
-- The clock menu (org-clock-menu)
---------------------------------------------------------------------------

--- The entries of org-clock-menu.
---@return (org.MenuEntry|string)[]
function M.clock_items()
  return {
    { "Clock out", action = "clock_out" },
    { "Change effort estimate", action = "clock_modify_effort" },
    { "Go to clock entry", action = "clock_goto" },
    { "Switch task", action = "clock_in", count = 4 },
  }
end

--- Pop up the clock menu (org-clock-menu; Emacs: mouse-1 on the clock in
--- the mode line). See `:h org-clock-menu` for a statusline click handler.
function M.clock_menu()
  M.define("]OrgClock", M.clock_items())
  M.popup("]OrgClock")
  return true
end

--- A statusline click handler (|statusline| `%@`) popping up the clock
--- menu on a left click and going to the clocked task on a middle click,
--- like the clock in Emacs's mode line.
function M.clock_click(_, _, button)
  if button == "m" then
    require("org.actions").run("clock_goto")
  else
    M.clock_menu()
  end
end

return M
