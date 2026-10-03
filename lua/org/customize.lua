---@mod org.customize Browsing and setting options (org-customize)
---
--- `:Org customize` opens a buffer listing every option with its value, in
--- the order and sections of `lua/org/config.lua`, like Emacs's
--- customize-browse of the org group. Keys: <CR> or K shows the option's
--- documentation (the comment above it in config.lua) with its default and
--- current value, `c` changes the value for this session (a Lua
--- expression, Emacs's "Set for Current Session"), `R` resets it to the
--- default, `q` closes the buffer. Options that differ from their default
--- are marked "[changed]". To keep a change, put it in `setup()`.
---
--- `:Org customize_menu` (org-create-customize-menu) puts every option into
--- the Org menu's Customize submenu.

local config = require("org.config")
local utils = require("org.utils")

local M = {}

---@class org.CustomizeOption
---@field path string[]
---@field doc string[]
---@field section boolean a table of options (shown as a heading)

--- The options of config.lua in source order, with their documentation.
---@type org.CustomizeOption[]|nil
M._options = nil

local function config_source()
  local src = debug.getinfo(config.lhs_list, "S").source:sub(2)
  local ok, lines = pcall(vim.fn.readfile, src)
  return ok and lines or {}
end

local function get(tbl, path)
  local t = tbl
  for _, k in ipairs(path) do
    if type(t) ~= "table" then
      return nil
    end
    t = t[k]
  end
  return t
end

local function is_dict(v)
  return type(v) == "table" and next(v) ~= nil and not vim.islist(v)
end

--- Read the option tree from config.lua's `M.defaults = { ... }`: a line
--- `key = value` at the indentation of its table is an option, `key = {`
--- opens a section when the default is a table of options.
---@return org.CustomizeOption[]
function M.options()
  if M._options then
    return M._options
  end
  local out, stack, doc = {}, {}, {}
  local inside = false
  for _, line in ipairs(config_source()) do
    if not inside then
      inside = line:match("^M%.defaults = {") ~= nil
    elseif line:match("^}") then
      break
    else
      local indent, key, rest = line:match("^(%s*)([%a_][%w_]*) = (.*)$")
      local c = line:match("^%s*%-%-%-%s?(.*)$")
      if line:match("^%s*%-%-%-%-") or (not c and line:match("^%s*%-%-")) then
        -- a rule or a section comment
        doc = {}
      elseif c then
        doc[#doc + 1] = c
      elseif key then
        local depth = #indent / 2
        while #stack >= depth and #stack > 0 do
          table.remove(stack)
        end
        if #stack == depth - 1 then
          local path = vim.list_extend(vim.deepcopy(stack), { key })
          local parent = #stack == 0 and config.defaults or get(config.defaults, stack)
          if is_dict(parent) or #stack == 0 then
            local trailing = rest:match("%-%-%s*(.-)%s*$")
            if trailing and trailing ~= "" then
              doc[#doc + 1] = trailing
            end
            local section = rest:match("^{%s*$") ~= nil and is_dict(get(config.defaults, path))
            out[#out + 1] = { path = path, doc = doc, section = section }
            if rest:match("^{%s*$") then
              stack[#stack + 1] = key
            end
          end
        end
        doc = {}
      elseif not line:match("^%s*$") then
        if not line:match("^%s*%-%-") then
          doc = {}
        end
      end
    end
  end
  M._options = out
  return out
end

--- One-line rendering of a value.
---@param v any
---@return string
function M.show(v)
  if v == nil then
    return "nil"
  elseif type(v) == "function" then
    return "<function>"
  end
  local s = vim.inspect(v, { newline = " ", indent = "" })
  if #s > 200 then
    s = s:sub(1, 197) .. "..."
  end
  return s
end

local function name(path)
  return table.concat(path, ".")
end

local function find(path)
  local key = name(path)
  for _, o in ipairs(M.options()) do
    if name(o.path) == key then
      return o
    end
  end
  return nil
end

---@param path string[]
---@param value any
function M.set(path, value)
  local t = config.opts
  for i = 1, #path - 1 do
    if type(t[path[i]]) ~= "table" then
      t[path[i]] = {}
    end
    t = t[path[i]]
  end
  t[path[#path]] = value
end

--- The buffer lines and the option of each line.
---@return string[], table<integer, org.CustomizeOption>
function M.render()
  local lines = {
    "Org options (org.nvim)  <CR>/K: documentation  c: change  R: reset to default  q/Esc: quit",
    "Changes last for this session; put them in setup() to keep them.",
    "",
  }
  local rows = {}
  for _, o in ipairs(M.options()) do
    local pad = string.rep("  ", #o.path - 1)
    local key = o.path[#o.path]
    if o.section then
      lines[#lines + 1] = pad .. key
    else
      local cur = get(config.opts, o.path)
      local changed = not vim.deep_equal(cur, get(config.defaults, o.path))
      lines[#lines + 1] = pad .. key .. " = " .. M.show(cur) .. (changed and "  [changed]" or "")
    end
    rows[#lines] = o
  end
  return lines, rows
end

M._buf = nil

local function refresh(buf)
  local lines, rows = M.render()
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.b[buf].org_customize_rows = nil
  M._rows = rows
end

local function option_at_cursor()
  return (M._rows or {})[vim.api.nvim_win_get_cursor(0)[1]]
end

--- The documentation of an option, with its default and current values
--- (what the Emacs customize buffer shows).
---@param o org.CustomizeOption
---@return string[]
function M.describe(o)
  local lines = { name(o.path) }
  vim.list_extend(lines, #o.doc > 0 and o.doc or { "(no documentation)" })
  if not o.section then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Default: " .. M.show(get(config.defaults, o.path))
    lines[#lines + 1] = "Value:   " .. M.show(get(config.opts, o.path))
  end
  return lines
end

--- Show the documentation of the option at the cursor.
function M.help()
  local o = option_at_cursor()
  if o then
    require("org.ui").float(M.describe(o), { title = "Option" })
  end
end

--- Change the option at the cursor for this session.
function M.change()
  local o = option_at_cursor()
  if not o or o.section then
    return
  end
  local text = utils.input({
    prompt = "Set " .. name(o.path) .. " (Lua): ",
    default = M.show(get(config.opts, o.path)),
  })
  if not text or text == "" then
    return
  end
  local chunk, err = load("return " .. text)
  if not chunk then
    utils.error("Invalid value: " .. tostring(err))
    return
  end
  local ok, value = pcall(chunk)
  if not ok then
    utils.error("Invalid value: " .. tostring(value))
    return
  end
  M.set(o.path, value)
  if M._buf and vim.api.nvim_buf_is_valid(M._buf) then
    local cur = vim.api.nvim_win_get_cursor(0)
    refresh(M._buf)
    pcall(vim.api.nvim_win_set_cursor, 0, cur)
  end
  utils.notify(name(o.path) .. " set for this session")
end

--- Reset the option at the cursor to its default.
function M.reset()
  local o = option_at_cursor()
  if not o or o.section then
    return
  end
  M.set(o.path, vim.deepcopy(get(config.defaults, o.path)))
  if M._buf and vim.api.nvim_buf_is_valid(M._buf) then
    local cur = vim.api.nvim_win_get_cursor(0)
    refresh(M._buf)
    pcall(vim.api.nvim_win_set_cursor, 0, cur)
  end
end

--- Open the options buffer (org-customize), on `opts.option` when given
--- (customize-variable).
---@param opts? { option?: string[] }
function M.open(opts)
  opts = opts or {}
  local buf = M._buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    buf = vim.api.nvim_create_buf(false, true)
    M._buf = buf
    vim.bo[buf].bufhidden = "wipe"
    pcall(vim.api.nvim_buf_set_name, buf, "org-customize")
    vim.bo[buf].filetype = "orgcustomize"
    local function map(lhs, fn)
      vim.keymap.set("n", lhs, function()
        utils.run(fn)
      end, { buffer = buf, nowait = true })
    end
    map("<CR>", M.help)
    map("K", M.help)
    map("c", M.change)
    map("R", M.reset)
    for _, lhs in ipairs({ "q", "<Esc>" }) do
      map(lhs, function()
        vim.api.nvim_buf_delete(buf, { force = true })
      end)
    end
  end
  refresh(buf)
  if vim.fn.bufwinid(buf) == -1 then
    require("org.ui").open_buffer_window(buf, config.opts.win_split_mode or "split", { title = "Customize" })
  else
    vim.api.nvim_set_current_win(vim.fn.bufwinid(buf))
  end
  if opts.option then
    for l, o in pairs(M._rows or {}) do
      if name(o.path) == name(opts.option) then
        pcall(vim.api.nvim_win_set_cursor, 0, { l, 0 })
      end
    end
  end
  return true
end

--- The customize entries of the Org menu (org-create-customize-menu):
--- one submenu per section, one entry per option opening it here.
---@return (org.MenuEntry|string)[]
function M.menu_items()
  local root = {}
  local by_path = { [""] = root }
  for _, o in ipairs(M.options()) do
    local parent = by_path[table.concat(o.path, ".", 1, #o.path - 1)]
    if parent then
      local key = o.path[#o.path]
      if o.section then
        local sub = {}
        by_path[name(o.path)] = sub
        parent[#parent + 1] = { key, items = sub }
      else
        local path = o.path
        parent[#parent + 1] = {
          key,
          hint = false,
          fn = function()
            M.open({ option = path })
          end,
        }
      end
    end
  end
  return root
end

--- Whether the Customize submenu lists every option.
M.menu_expanded = false

--- org-create-customize-menu: list every option in Org > Customize.
function M.create_menu()
  M.menu_expanded = true
  require("org.menu").sync(true)
  utils.notify('"Org"-menu now contains full customization menu')
  return true
end

return M
