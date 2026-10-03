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
