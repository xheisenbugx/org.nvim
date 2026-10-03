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
---@field filename? string file previewed and jumped to
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

---@class org.PickerSpec: org.PickerOpts
---Called with the chosen items (and the typed query) once the picker has
---closed, inside a coroutine, so it may prompt. The picker plugins' resume
---(snacks.nvim, fzf-lua, telescope, mini.pick) reopens the picker, which
---calls it again for what is chosen then.
---@field on_choice fun(items: org.PickerItem[], query?: string)
---Called when the picker is first closed without a choice (not when a
---resumed picker is).
---@field on_cancel? fun()

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

--- The prompt asking for the text of a `create_label` entry: "+ New tags…"
--- asks "New tags: ".
---@param spec org.PickerSpec
---@return string
function M.create_prompt(spec)
  local label = (spec.create_label or "New"):gsub("^%+%s*", ""):gsub("…$", "")
  return label .. ": "
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

--- The backend used for the `picker` option (or `name`): "auto" takes
--- LazyVim's `vim.g.lazyvim_picker` when set and installed, else the first
--- installed of snacks.nvim, fzf-lua, telescope.nvim and mini.pick, else
--- vim.ui.select. A backend that isn't installed falls back to
--- vim.ui.select, with a warning.
---@param name? string
---@return string
function M.backend(name)
  name = name or require("org.config").opts.picker or "auto"
  if name == "auto" then
    local lazy = ({ snacks = "snacks", fzf = "fzf-lua", telescope = "telescope" })[vim.g.lazyvim_picker or ""]
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
---@return string|nil
function M.pick(spec, backend)
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
  local function finish(items, query)
    local chose = items ~= nil and (#items > 0 or (spec.allow_query and query ~= nil and query ~= "")) or false
    if answered and not chose then
      return
    end
    answered = true
    vim.schedule(function()
      if chose then
        utils.run(spec.on_choice, items, query)
      elseif spec.on_cancel then
        utils.run(spec.on_cancel)
      end
    end)
  end
  local opts = vim.tbl_extend("keep", {}, spec)
  if opts.preview == nil then
    opts.preview = has_preview(spec.items)
  end
  require("org.pickers.backends." .. modules[name]).pick(opts, finish)
  return name
end

--- `pick()` inside a coroutine: wait for the choice. Returns the chosen
--- items and the query, or nil when cancelled. It returns once: choosing
--- in the picker reopened by a resume does nothing.
---@param spec org.PickerOpts
---@param backend? string
---@return org.PickerItem[]|nil, string|nil
function M.choose(spec, backend)
  return utils.await(function(cb)
    local s = vim.tbl_extend("force", {}, spec, {
      on_choice = function(items, query)
        cb(items, query)
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

--- Jump to an item's file (or buffer) and line, opening the folds around
--- it.
---@param item org.PickerItem
function M.jump(item)
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

return M
