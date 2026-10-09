---@mod org.pickers Picker integrations
---
--- Fuzzy pickers over headlines, tags, agenda entries, files, capture
--- templates and roam nodes, shown with snacks.nvim, fzf-lua,
--- telescope.nvim, mini.pick or `vim.ui.select` (the `picker` option). A
--- source builds a list of `org.PickerItem`s; `pick()` hands them to the
--- backend, which shows each item's `display` chunks with their highlight
--- groups and previews `filename`/`bufnr` at `lnum`. None of these plugins
--- is required: a backend is loaded (with `pcall(require)`) only when a
--- picker opens.
---
--- ```lua
--- require("org.pickers").pick({
---   title = "Fruit",
---   items = { { display = { { "Apple", "Title" } }, value = 1 } },
---   on_choice = function(items) print(items[1].value) end,
--- })
--- ```

local utils = require("org.utils")

local M = {}

---@class org.PickerItem
---@field display { [1]: string, [2]: string? }[] chunks of text and highlight group
---@field text? string matched text (default: the display chunks joined)
---file previewed (its buffer, when loaded) and jumped to
---@field filename? string
---@field bufnr? integer buffer, for an entry without a file
---@field lnum? integer line (1-based)
---@field col? integer column (1-based)
---@field value? any whatever the source needs back

--- What to pick from; `choose()` takes this, `pick()` an org.PickerSpec.
---@class org.PickerOpts
---@field title string
---@field items org.PickerItem[]
---Several items can be chosen (<Tab> in snacks / fzf-lua / telescope, <C-x>
---in mini.pick); vim.ui.select chooses one.
---@field multi? boolean
---Confirming when nothing matches calls `on_choice({}, query)` with the
---typed text. mini.pick lists a `create_label` entry that takes the typed
---text; vim.ui.select offers one that asks for it.
---@field allow_query? boolean
---Label of the entry vim.ui.select and mini.pick offer for `allow_query`.
---@field create_label? string
---@field query? string initial query (not vim.ui.select)
---@field preview? boolean show a preview of the item's file (default: when items have one)
---The items are places to go to: the `picker_keys` (split, vsplit, tab,
---qflist) choose too, and `on_choice` gets how to open the items as its
---third argument (`pick_*` pass it on to `go()`). The qflist key chooses
---the selected items, or every item that matches the query when none is
---selected (fzf-lua: the current one).
---@field split? boolean

---@class org.PickerSpec: org.PickerOpts
---Called with the chosen items (and the typed query) once the picker has
---closed, inside a coroutine, so it may prompt. The picker plugins' resume
---(snacks.nvim, fzf-lua, telescope, mini.pick) reopens the picker, which
---calls it again for what is chosen then. With `split`, `how` says which
---of the `picker_keys` chose ("split", "vsplit", "tab", "qflist"; nil for
---<CR>).
---@field on_choice fun(items: org.PickerItem[], query?: string, how?: org.PickerHow)
---Called when the picker is first closed without a choice (not when a
---resumed picker is).
---@field on_cancel? fun()

---@alias org.PickerHow "split"|"vsplit"|"tab"|"qflist"

--- The backends, in the order `picker = "auto"` tries them.
M.backends = { "snacks", "fzf-lua", "telescope", "mini", "select" }

-- module of each backend, under org.pickers.backends
local modules = {
  snacks = "snacks",
  ["fzf-lua"] = "fzf_lua",
  telescope = "telescope",
  mini = "mini",
  select = "select",
}

--- The text of an item: its `text`, or its display chunks joined.
---@param item org.PickerItem
---@return string
function M.line(item)
  if item.text then
    return item.text
  end
  local parts = {}
  for i, c in ipairs(item.display or {}) do
    parts[i] = c[1]
  end
  return table.concat(parts)
end

--- The loaded buffer an item's preview shows: the buffer of its file when
--- that is loaded (`lnum` counts its lines, unsaved edits included, and
--- the jump lands there), else its `bufnr`. Nil: preview the file.
---@param item org.PickerItem
---@return integer|nil
function M.buffer(item)
  if item.filename then
    return utils.find_buffer(item.filename)
  end
  if item.bufnr and vim.api.nvim_buf_is_loaded(item.bufnr) then
    return item.bufnr
  end
end

--- The prompt asking for the text of a `create_label` entry: "+ New tags…"
--- asks "New tags: ".
---@param spec org.PickerSpec
---@return string
function M.create_prompt(spec)
  local label = (spec.create_label or "New"):gsub("^%+%s*", ""):gsub("…$", "")
  return label .. ": "
end

-- the order the `picker_keys` are bound in
local HOWS = { "split", "vsplit", "tab", "qflist" }

--- The `picker_keys` of a spec with `split`, in Vim's key notation: a list
--- of `{ how, lhs }` (keys set to false are left out).
---@param spec org.PickerOpts
---@return { [1]: org.PickerHow, [2]: string }[]
function M.split_keys(spec)
  if not spec.split then
    return {}
  end
  local keys = require("org.config").opts.picker_keys or {}
  local out = {}
  for _, how in ipairs(HOWS) do
    local lhs = keys[how]
    if type(lhs) == "string" and lhs ~= "" then
      out[#out + 1] = { how, lhs }
    end
  end
  return out
end

--- The options of `picker_opts[name]` for a backend, with `extra` (the
--- options of `:Telescope org ...`) over them.
---@param name string
---@param extra? table
---@return table
function M.backend_opts(name, extra)
  local all = require("org.config").opts.picker_opts or {}
  local own = type(all[name]) == "table" and all[name] or {}
  return vim.tbl_deep_extend("force", {}, own, extra or {})
end

--- Whether a backend's plugin is loaded (or can be loaded) right now.
---@param name string
---@return boolean
function M.available(name)
  local mod = modules[name]
  if not mod then
    return false
  end
  local ok, backend = pcall(require, "org.pickers.backends." .. mod)
  return ok and backend.available() or false
end

local warned = {}

-- the backends of LazyVim's pickers
local LAZYVIM = { snacks = "snacks", fzf = "fzf-lua", telescope = "telescope" }

--- The backend of LazyVim's picker: `vim.g.lazyvim_picker` ("snacks",
--- "fzf", "telescope"), or with "auto", LazyVim's default, the picker the
--- extra enabled with :LazyExtras registered in `LazyVim.pick`.
---@return string|nil
local function lazyvim_picker()
  local name = vim.g.lazyvim_picker
  local lazyvim = rawget(_G, "LazyVim")
  if (name == nil or name == "auto") and type(lazyvim) == "table" then
    local ok, picker = pcall(function()
      return lazyvim.pick.picker
    end)
    name = ok and type(picker) == "table" and picker.name or nil
  end
  return LAZYVIM[name or ""]
end

--- The backend used for the `picker` option (or `name`): "auto" takes
--- LazyVim's picker when it is installed, else the first installed of
--- snacks.nvim, fzf-lua, telescope.nvim and mini.pick, else
--- vim.ui.select. A backend that isn't installed falls back to
--- vim.ui.select, with a warning.
---@param name? string
---@return string
function M.backend(name)
  name = name or require("org.config").opts.picker or "auto"
  if name == "auto" then
    local lazy = lazyvim_picker()
    if lazy and M.available(lazy) then
      return lazy
    end
    for _, b in ipairs(M.backends) do
      if M.available(b) then
        return b
      end
    end
    return "select"
  end
  if not modules[name] then
    utils.warn("Unknown picker " .. tostring(name) .. ", using vim.ui.select")
    return "select"
  end
  if not M.available(name) then
    if not warned[name] then
      warned[name] = true
      utils.warn("Picker " .. name .. " is not installed, using vim.ui.select")
    end
    return "select"
  end
  return name
end

--- Whether any item has something to preview.
local function has_preview(items)
  for _, it in ipairs(items) do
    if it.filename or it.bufnr then
      return true
    end
  end
  return false
end

--- Open a picker. Returns the backend used, or nil when there is nothing
--- to choose from.
---@param spec org.PickerSpec
---@param backend? string a backend name, over the `picker` option
---@param backend_opts? table options for the picker plugin, over `picker_opts`
---@return string|nil
function M.pick(spec, backend, backend_opts)
  if #spec.items == 0 and not spec.allow_query then
    utils.warn("Nothing to choose from: " .. spec.title)
    return nil
  end
  require("org.highlights").ensure()
  local name = M.backend(backend)
  -- The backend calls this once each time the picker closes. The answer
  -- comes after the picker has closed, in a coroutine (on_choice may
  -- prompt or open a capture). The first close answers either way; a
  -- picker reopened by the plugin's resume answers again with a choice.
  local answered = false
  local function finish(items, query, how)
    local chose = items ~= nil and (#items > 0 or (spec.allow_query and query ~= nil and query ~= "")) or false
    if answered and not chose then
      return
    end
    answered = true
    vim.schedule(function()
      if chose then
        utils.run(spec.on_choice, items, query, how)
      elseif spec.on_cancel then
        utils.run(spec.on_cancel)
      end
    end)
  end
  local opts = vim.tbl_extend("keep", {}, spec)
  if opts.preview == nil then
    opts.preview = has_preview(spec.items)
  end
  require("org.pickers.backends." .. modules[name]).pick(opts, finish, M.backend_opts(name, backend_opts))
  return name
end

--- `pick()` inside a coroutine: wait for the choice. Returns the chosen
--- items, the query and, with `split`, how to open them, or nil when
--- cancelled. It returns once: choosing in the picker reopened by a resume
--- does nothing.
---@param spec org.PickerOpts
---@param backend? string
---@return org.PickerItem[]|nil, string|nil, org.PickerHow|nil
function M.choose(spec, backend)
  return utils.await(function(cb)
    local s = vim.tbl_extend("force", {}, spec, {
      on_choice = function(items, query, how)
        cb(items, query, how)
      end,
      on_cancel = function()
        cb(nil)
      end,
    })
    if not M.pick(s, backend) then
      cb(nil)
    end
  end)
end

-- the command opening the window of each `how`
local OPEN = { split = "split", vsplit = "vsplit", tab = "tab split" }

--- Jump to an item's file (or buffer) and line, opening the folds around
--- it; with `how`, in a new split, vertical split or tab page.
---@param item org.PickerItem
---@param how? org.PickerHow
function M.jump(item, how)
  if how and OPEN[how] then
    vim.cmd(OPEN[how])
  end
  vim.cmd("normal! m'")
  local col = math.max((item.col or 1) - 1, 0)
  if item.filename then
    utils.open_file(item.filename, item.lnum or 1, { col = col })
  elseif item.bufnr and vim.api.nvim_buf_is_valid(item.bufnr) then
    vim.api.nvim_set_current_buf(item.bufnr)
    local last = vim.api.nvim_buf_line_count(item.bufnr)
    vim.api.nvim_win_set_cursor(0, { math.max(1, math.min(item.lnum or 1, last)), col })
    vim.cmd("normal! zv")
  end
end

--- Put items in the quickfix list, titled `title`, and open its window.
---@param items org.PickerItem[]
---@param title? string
function M.qflist(items, title)
  local list = {}
  for _, it in ipairs(items) do
    if it.filename or it.bufnr then
      list[#list + 1] = {
        filename = it.filename,
        bufnr = not it.filename and it.bufnr or nil,
        lnum = it.lnum or 1,
        col = it.col or 1,
        text = M.line(it),
      }
    end
  end
  vim.fn.setqflist({}, " ", { title = title or "org", items = list })
  vim.cmd("botright copen")
end

--- Go to the places chosen in a picker with `split`: one item is jumped
--- to (in a new window with `how`); several open each in a window of
--- their own with split, vsplit or tab, and go to the quickfix list with
--- <CR>; "qflist" puts them all in the quickfix list.
---@param items org.PickerItem[]
---@param how? org.PickerHow
---@param title? string the quickfix list's title
function M.go(items, how, title)
  if how == "qflist" or (#items > 1 and not how) then
    M.qflist(items, title)
    return
  end
  for _, item in ipairs(items) do
    M.jump(item, how)
  end
end

return M
