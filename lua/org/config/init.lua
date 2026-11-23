---@mod org.config Configuration
---
--- All options live in `require('org.config').opts`. The table is mutated in
--- place by `setup()`, so modules must read options at call time
--- (`require('org.config').opts.foo`) instead of caching sub-tables.

local M = {}

--- Default options. The user-facing option types and docs live in
--- `lua/org/_meta/` (class `org.Config`, every field optional) so that
--- `require("org").setup({...})` gets completion and hover docs. Internal
--- code reads `M.opts`, typed from this table, where every option is set.
---
--- The table is built from one file per area under lua/org/config/, in
--- this order (the order `:Org customize` lists the options in). A new
--- option goes in the file of its area; a new file goes in this list.
M.parts = {
  "todo",
  "tags",
  "tables",
  "buffer",
  "agenda",
  "capture",
  "clock",
  "misc",
  "links",
  "mobile",
  "babel",
  "export",
  "ui",
  "mappings",
}

---@type org.config.Resolved
M.defaults = {}
do
  -- loaded from this directory rather than through `require`, whose search
  -- of 'runtimepath' for each part would double the time to load the
  -- options; not kept in package.loaded, so requiring org.config again
  -- builds fresh defaults
  local dir = debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]")
  for _, part in ipairs(M.parts) do
    local chunk = assert(loadfile(dir .. "/" .. part .. ".lua"))
    for k, v in pairs(chunk()) do
      M.defaults[k] = v
    end
  end
end

---@type org.config.Resolved
M.opts = vim.deepcopy(M.defaults)

--- Replace `dst` contents with `src` merged on top, in place.
local function merge_into(dst, src)
  for k, v in pairs(src) do
    -- lists replace, dicts merge
    if type(v) == "table" and type(dst[k]) == "table" and not vim.islist(v) and not vim.islist(dst[k]) then
      merge_into(dst[k], v)
    elseif type(v) == "table" and type(dst[k]) == "table" and vim.tbl_isempty(v) and not vim.islist(dst[k]) then
      -- `{}` given for a dict option: keep defaults
    else
      dst[k] = v
    end
  end
end

--- Merge `src` into `dst` with the same rules as `setup()` (dicts merge,
--- lists replace). Used for extension options.
M.merge = merge_into

--- Valid top-level options whose default is `nil` (so they do not appear as
--- keys in `M.defaults`). Kept in sync with `org.Config` in
--- `lua/org/_meta/config.lua` (tested in `config_setup_spec.lua`).
---@type table<string, boolean>
M.NIL_DEFAULTS = {
  columns_dblock_formatter = true,
  columns_modify_value_for_display_function = true,
  cycle_max_level = true,
  edit_fixed_width_region_mode = true,
  inlinetask_default_state = true,
  popup_calendar_for_date_prompt = true,
  priority_get_priority_function = true,
  sparse_tree_default_date_type = true,
  tags_sort_function = true,
  todo_repeat_to_state = true,
}

--- Levenshtein edit distance between two short strings.
---@param a string
---@param b string
---@return integer
local function edit_distance(a, b)
  local m, n = #a, #b
  if m == 0 then
    return n
  elseif n == 0 then
    return m
  end
  local prev = {}
  for j = 0, n do
    prev[j] = j
  end
  for i = 1, m do
    local curr = { [0] = i }
    local ca = a:byte(i)
    for j = 1, n do
      local cost = ca == b:byte(j) and 0 or 1
      curr[j] = math.min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
    end
    prev = curr
  end
  return prev[n]
end

--- Unknown top-level option names passed to `setup()`, sorted.
---@param opts? table
---@return string[]
function M.unknown_top_level(opts)
  if type(opts) ~= "table" then
    return {}
  end
  local unknown = {}
  for k in pairs(opts) do
    if type(k) == "string" and M.defaults[k] == nil and not M.NIL_DEFAULTS[k] then
      unknown[#unknown + 1] = k
    end
  end
  table.sort(unknown)
  return unknown
end

--- Suggest a known top-level option for `name`, plus whether it looks like an
--- nvim-orgmode `org_*` option name.
---@param name string
---@return string|nil suggestion, boolean nvim_orgmode
local function suggest_option(name)
  if name:sub(1, 4) == "org_" then
    local stripped = name:sub(5)
    if M.defaults[stripped] ~= nil or M.NIL_DEFAULTS[stripped] then
      return stripped, true
    end
  end
  local best, best_d = nil, 3
  local function consider(candidate)
    if math.abs(#candidate - #name) < best_d then
      local d = edit_distance(name, candidate)
      if d < best_d or (d == best_d and best and candidate < best) then
        best, best_d = candidate, d
      end
    end
  end
  for k in pairs(M.defaults) do
    consider(k)
  end
  for k in pairs(M.NIL_DEFAULTS) do
    consider(k)
  end
  return best, false
end

--- Human-readable warning for unknown top-level `setup()` options, or nil when
--- `unknown` is empty.
---@param unknown string[]
---@return string|nil
function M.format_unknown_warning(unknown)
  if #unknown == 0 then
    return nil
  end
  local parts = {}
  local has_migrate = false
  for _, name in ipairs(unknown) do
    local suggestion, migrate = suggest_option(name)
    if migrate then
      has_migrate = true
    end
    if suggestion then
      parts[#parts + 1] = string.format("`%s` (did you mean `%s`?)", name, suggestion)
    else
      parts[#parts + 1] = string.format("`%s`", name)
    end
  end
  local hint = has_migrate and "run :Org migrate_config or :checkhealth org" or "see :h org-config or :checkhealth org"
  return string.format(
    "Unknown setup() option%s: %s (%s)",
    #unknown == 1 and "" or "s",
    table.concat(parts, ", "),
    hint
  )
end

--- Options that are tables of sub-options (`clock = { ... }`).
local SECTIONS = {}
for _, k in ipairs({
  "agenda",
  "attach",
  "babel",
  "bibtex",
  "capture",
  "clock",
  "crypt",
  "ctags",
  "export",
  "feed",
  "id",
  "links",
  "lists",
  "mappings",
  "mobile",
  "mouse",
  "notifications",
  "protocol",
  "refile",
  "remote",
  "timer",
  "ui",
  "yank",
}) do
  SECTIONS[k] = true
end

--- Merge user options into `M.opts`. Dict options merge key by key; lists
--- (and `capture.templates`) replace the default; `{}` for a dict option
--- keeps its defaults; `babel.languages = { lang = false }` removes a
--- language.
---@param opts? org.Config
---@return org.config.Resolved
function M.setup(opts)
  opts = opts or {}
  if type(opts) ~= "table" then
    error("org.nvim: setup() takes a table of options, got " .. type(opts), 2)
  end
  -- option sections: a scalar here would fail later with an obscure
  -- "attempt to index" error deep in some module
  for k, v in pairs(opts) do
    if type(v) ~= "table" and type(M.defaults[k]) == "table" and SECTIONS[k] then
      error(string.format("org.nvim: option `%s` must be a table, got %s", k, type(v)), 2)
    end
  end
  -- `capture.templates` and `agenda.custom_commands` are replaced wholesale
  -- when given, so users aren't stuck with the default template.
  local templates = opts.capture and opts.capture.templates
  local fresh = vim.deepcopy(M.defaults)
  for k in pairs(M.opts) do
    M.opts[k] = nil
  end
  merge_into(M.opts, fresh)
  merge_into(M.opts, opts)
  if templates then
    M.opts.capture.templates = templates
  end
  -- what the user passed, for :checkhealth org (unknown options)
  M.user_opts = opts
  if opts.babel and opts.babel.languages then
    -- languages merge per key; allow `false` to remove one
    for k, v in pairs(opts.babel.languages) do
      if v == false then
        M.opts.babel.languages[k] = nil
      end
    end
  end
  return M.opts
end

--- Resolve a mapping value to a list of lhs (with <prefix> expanded).
---@param value string|string[]|false|nil
---@return string[]
function M.lhs_list(value)
  if not value then
    return {}
  end
  ---@type string[]
  local list = type(value) == "table" and value or { value }
  local prefix = M.opts.mappings.prefix or "<leader>o"
  local out = {}
  for _, lhs in ipairs(list) do
    if lhs then
      out[#out + 1] = (lhs:gsub("<prefix>", require("org.utils").gsub_escape(prefix)))
    end
  end
  return out
end

return M
